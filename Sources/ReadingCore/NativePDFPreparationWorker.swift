import Foundation
#if os(macOS)
import CoreGraphics
import CryptoKit
import Darwin
import PDFKit
import os

/// Owns a separate PDF document. No displayed PDFKit object crosses this actor.
/// The document, its password and its verified file identity exist in memory only.
public actor NativePDFPreparationWorker {
    public enum Failure: Error, Sendable {
        case pageTextTooLarge
    }

    public struct Session: Sendable, Equatable {
        public let url: URL
        public let sourceHash: String
        public let generation: Int
        public let password: String?

        public init(url: URL, sourceHash: String, generation: Int, password: String? = nil) {
            self.url = url; self.sourceHash = sourceHash; self.generation = generation; self.password = password
        }
    }

    public struct PreparedPage: Sendable {
        public let page: Int
        public let text: String
        public let byteCount: Int
        public let nativeCharacterCount: Int
        public let crop: CGRect
        public let rotation: Int
        public let directory: NativePDFTextLine.Directory
    }

    public struct GeometryRequest: Sendable {
        public let id: String
        public let range: NSRange
        public init(id: String, range: NSRange) { self.id = id; self.range = range }
    }

    public typealias Progress = @Sendable (ReadingPreparationProgress) -> Void

    private struct FileIdentity: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ info: stat) throws {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_size >= 0, info.st_size <= 256 * 1_024 * 1_024 else { throw Self.failure() }
            device = Int64(info.st_dev); inode = UInt64(info.st_ino); size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }

        static func failure() -> ReadingError { .invalid("原书文件已变化或不是可校验的普通文件，请重新打开原书。") }
    }

    private struct Context {
        let session: Session
        let token: UUID
        let file: FileIdentity
        // A metadata mismatch poisons this exact session until its identity changes.
        var document: PDFDocument?
    }

    private var context: Context?
    private let signposter = OSSignposter(subsystem: "org.readingbook.app", category: "NativePDFPreparation")

    public init() {}

    public func preparePage(session: Session, page number: Int, onProgress: Progress? = nil) async throws -> PreparedPage {
        try Task.checkCancellation()
        onProgress?(.init(phase: .pageText, page: number))
        let token = try openSession(session)
        let page = try ownedPage(number, session: session, token: token)
        // PDFKit calls are synchronous, but operate only on this actor's document.
        let textInterval = signposter.beginInterval("PageText")
        let text = page.string ?? ""
        signposter.endInterval("PageText", textInterval)
        try checkSession(session, token: token)
        let byteCount = text.utf8.count
        guard byteCount <= 8_000_000 else { throw Failure.pageTextTooLarge }
        let nativeText = text as NSString
        let nativeCharacterCount = page.numberOfCharacters
        let crop = page.bounds(for: .cropBox), rotation = page.rotation
        try checkSession(session, token: token)
        onProgress?(.init(phase: .pageText, page: number, completed: 1, total: 1))
        try await checkpoint(session, token: token)

        onProgress?(.init(phase: .nativeLines, page: number))
        try checkSession(session, token: token)
        var directory = NativePDFTextLine.Directory()
        let length = nativeText.length
        // Preserve the native range guard: glyph and UTF16 counts may differ.
        let selectionInterval = signposter.beginInterval("FullSelection")
        let full = length > 0 && length <= nativeCharacterCount
            ? page.selection(for: NSRange(location: 0, length: length)) : nil
        signposter.endInterval("FullSelection", selectionInterval)
        try checkSession(session, token: token)
        let linesInterval = signposter.beginInterval("SelectionsByLine")
        let lines = full?.selectionsByLine() ?? []
        signposter.endInterval("SelectionsByLine", linesInterval)
        try checkSession(session, token: token)
        onProgress?(.init(phase: .nativeLines, page: number, completed: 0, total: lines.count))
        try await checkpoint(session, token: token)
        var lastProgress = ProcessInfo.processInfo.systemUptime
        for (index, selection) in lines.enumerated() {
            try checkSession(session, token: token)
            if let line = NativePDFTextLine.ownedPhysicalLine(selection, on: page, pageText: nativeText) {
                directory.append(line)
            }
            let completed = index + 1, now = ProcessInfo.processInfo.systemUptime
            if completed == lines.count || now - lastProgress >= 0.1 {
                onProgress?(.init(phase: .nativeLines, page: number, completed: completed, total: lines.count))
                lastProgress = now
            }
            if completed.isMultiple(of: 12) || completed == lines.count {
                try await checkpoint(session, token: token)
            }
        }
        try validateCurrentFile(session, token: token)
        return PreparedPage(page: number, text: text, byteCount: byteCount, nativeCharacterCount: nativeCharacterCount,
                            crop: crop, rotation: rotation, directory: directory)
    }

    public func prepareGeometry(session: Session, page number: Int, requests: [GeometryRequest],
                                onProgress: Progress? = nil) async throws -> [String: [CGRect]] {
        try Task.checkCancellation()
        onProgress?(.init(phase: .geometry, page: number, completed: 0, total: requests.count))
        let token = try openSession(session)
        let page = try ownedPage(number, session: session, token: token)
        var result: [String: [CGRect]] = [:]
        var lastProgress = ProcessInfo.processInfo.systemUptime
        for (index, request) in requests.enumerated() {
            try checkSession(session, token: token)
            // The helper rejects NSNotFound, negative, empty and overflowing ranges
            // before PDFKit can raise an Objective-C invalid-range exception.
            result[request.id] = NativePDFTextLine.ownedRectangles(for: request.range, on: page)
            let completed = index + 1, now = ProcessInfo.processInfo.systemUptime
            if completed == requests.count || now - lastProgress >= 0.1 {
                onProgress?(.init(phase: .geometry, page: number, completed: completed, total: requests.count))
                lastProgress = now
            }
            if completed.isMultiple(of: 12) || completed == requests.count {
                try await checkpoint(session, token: token)
            }
        }
        try validateCurrentFile(session, token: token)
        return result
    }

    private func checkpoint(_ session: Session, token: UUID) async throws {
        await Task.yield()
        try checkSession(session, token: token)
    }

    private func checkSession(_ session: Session, token: UUID) throws {
        try Task.checkCancellation()
        guard context?.token == token, context?.session == session else { throw CancellationError() }
        guard context?.document != nil else { throw FileIdentity.failure() }
    }

    private func ownedPage(_ number: Int, session: Session, token: UUID) throws -> PDFPage {
        try checkSession(session, token: token)
        guard let document = context?.document, number > 0, number <= document.pageCount,
              let page = document.page(at: number - 1) else { throw ReadingError.invalid("原书页码无效。") }
        return page
    }

    private func openSession(_ session: Session) throws -> UUID {
        try Task.checkCancellation()
        if let saved = context, saved.session == session {
            try validateCurrentFile(session, token: saved.token)
            return saved.token
        }
        // A new identity invalidates suspended work even if opening it fails.
        context = nil
        guard !session.sourceHash.isEmpty else { throw FileIdentity.failure() }
        let (data, file) = try Self.readVerifiedFile(session)
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data) else {
            throw ReadingError.invalid("原书 PDF 无法读取。")
        }
        try BookImporter.unlockPDF(document, password: session.password)
        guard document.pageCount > 0 else { throw ReadingError.invalid("原书 PDF 没有可读取页面。") }
        try Task.checkCancellation()
        let token = UUID()
        context = Context(session: session, token: token, file: file, document: document)
        try validateCurrentFile(session, token: token)
        return token
    }

    private func validateCurrentFile(_ session: Session, token: UUID) throws {
        try checkSession(session, token: token)
        do {
            guard let saved = context, try Self.fileIdentity(at: session.url) == saved.file else { throw FileIdentity.failure() }
        } catch {
            // Keep the failed session identity; its original hash must not silently
            // authorize reopening a replacement or metadata-changed file.
            if context?.token == token { context?.document = nil }
            throw error
        }
        try checkSession(session, token: token)
    }

    private static func openedFile(at url: URL) throws -> (Int32, FileIdentity) {
        guard url.isFileURL else { throw FileIdentity.failure() }
        let descriptor = url.standardizedFileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw FileIdentity.failure() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw FileIdentity.failure() }
            return (descriptor, try FileIdentity(info))
        } catch { close(descriptor); throw error }
    }

    private static func fileIdentity(at url: URL) throws -> FileIdentity {
        let (descriptor, identity) = try openedFile(at: url)
        close(descriptor)
        return identity
    }

    private static func readVerifiedFile(_ session: Session) throws -> (Data, FileIdentity) {
        let (descriptor, before) = try openedFile(at: session.url)
        defer { close(descriptor) }
        var data = Data(), hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
        data.reserveCapacity(Int(before.size))
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= 256 * 1_024 * 1_024 - data.count else { throw FileIdentity.failure() }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            data.append(chunk); hash.update(data: chunk)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, try FileIdentity(info) == before,
              Int64(data.count) == before.size, try fileIdentity(at: session.url) == before else { throw FileIdentity.failure() }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == session.sourceHash else { throw FileIdentity.failure() }
        try Task.checkCancellation()
        return (data, before)
    }
}
#endif
