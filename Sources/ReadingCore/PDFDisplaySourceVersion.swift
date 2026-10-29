import Foundation
#if os(macOS)
import CryptoKit
import Darwin

/// A value-only receipt for the bytes and file identity admitted to a PDF display.
/// It contains no PDFKit object, password, persistent bookmark or file descriptor.
public struct PDFDisplaySourceVersion: Sendable, Equatable {
    public let canonicalPath: String
    public let actualSourceHash: String
    private let file: FileIdentity

    private static let maximumBytes = 256 * 1_024 * 1_024

    private struct FileIdentity: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ info: stat) throws {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_size > 0, info.st_size <= Int64(PDFDisplaySourceVersion.maximumBytes) else {
                throw PDFDisplaySourceVersion.failure()
            }
            device = Int64(info.st_dev); inode = UInt64(info.st_ino); size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    /// Reads and hashes on a detached worker, never on the caller's actor.
    /// The expected hash is the canonical lowercase SHA-256 stored by BookImporter.
    /// This verifies source bytes, not PDF syntax or permission to reuse a display.
    public static func verify(at url: URL, expectedSourceHash: String) async throws -> Self {
        try Task.checkCancellation()
        guard expectedSourceHash.utf8.count == 64,
              expectedSourceHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw failure()
        }
        let worker = Task.detached(priority: .userInitiated) {
            try readVerifiedVersion(at: url, expectedSourceHash: expectedSourceHash)
        }
        let version = try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
        try Task.checkCancellation()
        return version
    }

    /// A bounded open/fstat/close recheck after an await. It does not hash bytes.
    /// A match is only a freshness check for this existing verified receipt;
    /// callers must also retain their library, book and display ownership checks.
    public func matchesCurrentFileMetadata() throws -> Bool {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: canonicalPath)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let current = try Self.fileIdentity(at: url)
        try Task.checkCancellation()
        return current == file
    }

    private static func failure() -> ReadingError {
        .invalid("原书文件已变化或不是可校验的普通文件，请重新打开原书。")
    }

    private static func openedFile(at url: URL) throws -> (Int32, FileIdentity) {
        guard url.isFileURL else { throw failure() }
        let descriptor = url.standardizedFileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw failure() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw failure() }
            return (descriptor, try FileIdentity(info))
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func fileIdentity(at url: URL) throws -> FileIdentity {
        let (descriptor, identity) = try openedFile(at: url)
        close(descriptor)
        return identity
    }

    private static func readVerifiedVersion(at url: URL, expectedSourceHash: String) throws -> Self {
        try Task.checkCancellation()
        // Do not resolve a final symlink before O_NOFOLLOW gets to reject it.
        let canonical = url.standardizedFileURL
        let accessed = canonical.startAccessingSecurityScopedResource()
        defer { if accessed { canonical.stopAccessingSecurityScopedResource() } }
        let (descriptor, before) = try openedFile(at: canonical)
        defer { close(descriptor) }
        var hash = SHA256(), byteCount = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= maximumBytes - byteCount else { throw failure() }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
            byteCount += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, try FileIdentity(after) == before,
              Int64(byteCount) == before.size, try fileIdentity(at: canonical) == before else {
            throw failure()
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSourceHash else { throw failure() }
        try Task.checkCancellation()
        return Self(canonicalPath: canonical.path, actualSourceHash: actual, file: before)
    }
}
#endif
