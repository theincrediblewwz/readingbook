import Foundation
import XCTest
@testable import ReadingCore
#if os(macOS)
import CoreGraphics
import CoreText
import PDFKit

final class NativePDFPreparationWorkerTests: XCTestCase {
    private struct Fixture: Sendable {
        let directory: URL
        let url: URL
        let hash: String
        let text: String
        let nativeCount: Int
        let crop: CGRect
        let rotation: Int
        let ranges: [String: NSRange]
        let geometry: [String: [CGRect]]
        let glyphGap: CGPoint?
        func session(_ generation: Int = 1, password: String? = nil) -> NativePDFPreparationWorker.Session {
            .init(url: url, sourceHash: hash, generation: generation, password: password)
        }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ReadingPreparationProgress] = []
        func append(_ value: ReadingPreparationProgress) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
        var values: [ReadingPreparationProgress] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @MainActor private func attributed(_ text: String, size: CGFloat = 24, kerning: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil),
            NSAttributedString.Key(kCTKernAttributeName as String): kerning
        ])
    }

    @MainActor private func fixture(_ quotes: [String], mixedLine: Int? = nil, rotation: Int = 0,
                                   password: String? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-NativeWorker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("fixture.pdf")
        let data = NSMutableData()
        let output = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 600)
        let renderer = try XCTUnwrap(CGContext(consumer: output, mediaBox: &media, nil))
        renderer.beginPDFPage(nil); renderer.textMatrix = .identity
        for (index, quote) in quotes.enumerated() {
            let value: NSAttributedString
            if index == mixedLine {
                let mixed = NSMutableAttributedString(attributedString: attributed(String(quote.prefix(1)), size: 64))
                mixed.append(attributed(String(quote.dropFirst()), size: 18, kerning: 8)); value = mixed
            } else { value = attributed(quote) }
            renderer.textPosition = CGPoint(x: 32, y: 510 - CGFloat(index) * 120)
            CTLineDraw(CTLineCreateWithAttributedString(value as CFAttributedString), renderer)
        }
        renderer.endPDFPage(); renderer.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data)), page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 10, y: 15, width: 580, height: 570), for: .cropBox); page.rotation = rotation
        if let password {
            XCTAssertTrue(document.write(to: url, withOptions: [.ownerPasswordOption: "fixture-owner-only", .userPasswordOption: password]))
        } else { XCTAssertTrue(document.write(to: url)) }
        // This is a separate document from the worker's future file-backed copy.
        let reference = try XCTUnwrap(PDFDocument(url: url))
        if let password { XCTAssertTrue(reference.unlock(withPassword: password)) }
        let nativePage = try XCTUnwrap(reference.page(at: 0)), text = try XCTUnwrap(nativePage.string)
        var ranges: [String: NSRange] = [:], geometry: [String: [CGRect]] = [:]
        for (index, quote) in quotes.enumerated() {
            let scalars = text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            let expectedScalars = quote.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            let diagnostic = "Synthetic fixture quote=\(String(reflecting: quote)) scalars=\(expectedScalars); " +
                "written PDF text=\(String(reflecting: text)) scalars=\(scalars); " +
                "crop=\(nativePage.bounds(for: .cropBox)) rotation=\(nativePage.rotation) nativeCount=\(nativePage.numberOfCharacters) UTF16=\((text as NSString).length)"
            let range = NSRange(try XCTUnwrap(text.range(of: quote, options: .literal), diagnostic), in: text)
            ranges[String(index)] = range
            geometry[String(index)] = NativePDFTextLine.rectangles(for: range, on: nativePage)
            XCTAssertFalse(geometry[String(index), default: []].isEmpty)
        }
        var gap: CGPoint?
        if let mixedLine, let rectangle = geometry[String(mixedLine)]?.first,
           let range = ranges[String(mixedLine)] {
            let smallBounds = nativePage.characterBounds(at: range.location + 1)
            for step in 1..<128 {
                let point = CGPoint(x: rectangle.minX + rectangle.width * CGFloat(step) / 128, y: smallBounds.midY)
                let index = nativePage.characterIndex(at: point)
                if index < 0 || index == NSNotFound { gap = point; break }
            }
            if gap == nil, rectangle.maxY > smallBounds.maxY + 1 {
                let point = CGPoint(x: smallBounds.midX, y: (smallBounds.maxY + rectangle.maxY) / 2)
                let index = nativePage.characterIndex(at: point)
                if index < 0 || index == NSNotFound { gap = point }
            }
        }
        return Fixture(directory: directory, url: url, hash: try BookImporter.sha256(Data(contentsOf: url)), text: text,
                       nativeCount: nativePage.numberOfCharacters, crop: nativePage.bounds(for: .cropBox), rotation: nativePage.rotation,
                       ranges: ranges, geometry: geometry, glyphGap: gap)
    }

    @MainActor func testOwnedPreparationPreservesEmojiLastLineGlyphGapAndNativeGeometry() async throws {
        let source = try fixture(["首行😀正文。", "高小字间距句。", "页末最后一句。"], mixedLine: 1, rotation: 90)
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let worker = NativePDFPreparationWorker(), progress = ProgressLog()
        let prepared = try await worker.preparePage(session: source.session(), page: 1, onProgress: { progress.append($0) })
        XCTAssertTrue(prepared.text.utf8.elementsEqual(source.text.utf8))
        XCTAssertTrue(prepared.text.contains("😀"))
        XCTAssertEqual(prepared.byteCount, source.text.utf8.count)
        XCTAssertEqual(prepared.nativeCharacterCount, source.nativeCount)
        XCTAssertEqual(prepared.crop, source.crop); XCTAssertEqual(prepared.rotation, source.rotation)
        for (id, range) in source.ranges {
            for rectangle in source.geometry[id, default: []] {
                let point = CGPoint(x: rectangle.midX, y: rectangle.midY)
                XCTAssertTrue(prepared.directory.lines(at: point).contains { $0.intersects(range) }, id)
            }
        }
        let gap = try XCTUnwrap(source.glyphGap, "Fixture must exercise a genuine glyph gap.")
        XCTAssertTrue(prepared.directory.lines(at: gap).contains { $0.intersects(source.ranges["1"]!) })
        let requests = source.ranges.map { NativePDFPreparationWorker.GeometryRequest(id: $0.key, range: $0.value) }
            + [.init(id: "invalid", range: NSRange(location: NSNotFound, length: 2))]
        let geometry = try await worker.prepareGeometry(session: source.session(), page: 1, requests: requests)
        for (id, expected) in source.geometry { XCTAssertEqual(geometry[id], expected) }
        XCTAssertEqual(geometry["invalid"], [])

        let canonical = prepared.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: prepared.text, source: PDFPageSourceText(page: 1, text: canonical)))
        let lastQuote = "页末最后一句。", last = (canonical as NSString).range(of: lastQuote)
        XCTAssertEqual(proof.range(of: lastQuote, location: last.location, length: last.length), source.ranges["2"])
        let values = progress.values
        XCTAssertEqual(values.first, .init(phase: .pageText, page: 1))
        XCTAssertTrue(values.contains(.init(phase: .pageText, page: 1, completed: 1, total: 1)))
        let final = try XCTUnwrap(values.last)
        XCTAssertEqual(final.phase, .nativeLines); XCTAssertEqual(final.completed, final.total)
        XCTAssertGreaterThan(final.total ?? 0, 1)
    }

    @MainActor func testIndependentWorkersAndSequentialSessionsNeverExchangePages() async throws {
        let first = try fixture(["第一本文字😀。"]), second = try fixture(["第二本不同正文。"], rotation: 180)
        defer { try? FileManager.default.removeItem(at: first.directory); try? FileManager.default.removeItem(at: second.directory) }
        let left = NativePDFPreparationWorker(), right = NativePDFPreparationWorker()
        async let leftPage = left.preparePage(session: first.session(), page: 1)
        async let rightPage = right.preparePage(session: second.session(), page: 1)
        let (a, b) = try await (leftPage, rightPage)
        XCTAssertTrue(a.text.utf8.elementsEqual(first.text.utf8)); XCTAssertTrue(b.text.utf8.elementsEqual(second.text.utf8))
        let switched = try await left.preparePage(session: second.session(), page: 1)
        XCTAssertTrue(switched.text.utf8.elementsEqual(second.text.utf8)); XCTAssertEqual(switched.rotation, 180)
        let returned = try await left.preparePage(session: first.session(2), page: 1)
        XCTAssertTrue(returned.text.utf8.elementsEqual(first.text.utf8))
        let wrongHash = NativePDFPreparationWorker.Session(url: first.url, sourceHash: second.hash, generation: 2)
        do { _ = try await left.preparePage(session: wrongHash, page: 1); XCTFail("A cached PDF cannot authorize a different source hash.") }
        catch { XCTAssertFalse(error is PDFPasswordError) }
    }

    @MainActor func testChangedMetadataPoisonsOldSessionEvenWhenBytesAndHashAreUnchanged() async throws {
        let source = try fixture(["元数据变化正文。"])
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let worker = NativePDFPreparationWorker(), session = source.session()
        _ = try await worker.preparePage(session: session, page: 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123_456)], ofItemAtPath: source.url.path)
        for _ in 0..<2 {
            do { _ = try await worker.prepareGeometry(session: session, page: 1, requests: []); XCTFail("Changed metadata must reject this existing session.") }
            catch { }
        }
        XCTAssertEqual(try BookImporter.sha256(Data(contentsOf: source.url)), source.hash)
        let reopened = try await worker.preparePage(session: source.session(2), page: 1)
        XCTAssertTrue(reopened.text.utf8.elementsEqual(source.text.utf8))
    }

    @MainActor func testPasswordIdentityIsNotReusedOrWrittenToSidecars() async throws {
        let password = "native-worker-fixture-only-7c91", source = try fixture(["加密正文。"], password: password)
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let before = try Data(contentsOf: source.url), worker = NativePDFPreparationWorker()
        let opened = try await worker.preparePage(session: source.session(password: password), page: 1)
        XCTAssertTrue(opened.text.contains("加密正文"))
        do { _ = try await worker.preparePage(session: source.session(password: "wrong"), page: 1); XCTFail("A changed password cannot reuse an unlocked document.") }
        catch { XCTAssertEqual(error as? PDFPasswordError, .wrongPassword); XCTAssertFalse(error.localizedDescription.contains(password)) }
        do { _ = try await worker.preparePage(session: source.session(), page: 1); XCTFail("A missing password cannot reuse an unlocked document.") }
        catch { XCTAssertEqual(error as? PDFPasswordError, .needsPassword) }
        XCTAssertEqual(try Data(contentsOf: source.url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.directory.path), ["fixture.pdf"])
    }

    @MainActor func testCancellationNeverReturnsPartialDirectoryOrGeometry() async throws {
        let source = try fixture(["首行😀。", "第二行。", "最后一行。"])
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let worker = NativePDFPreparationWorker()
        let pageTask = Task {
            try await worker.preparePage(session: source.session(), page: 1, onProgress: { value in
                if value.phase == .nativeLines, value.total != nil { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await pageTask.value; XCTFail("Cancelled preparation must not return a partial directory.") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await worker.preparePage(session: source.session(), page: 1)
        let requests = source.ranges.map { NativePDFPreparationWorker.GeometryRequest(id: $0.key, range: $0.value) }
        let geometryTask = Task {
            try await worker.prepareGeometry(session: source.session(), page: 1, requests: requests, onProgress: { value in
                if (value.completed ?? 0) > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await geometryTask.value; XCTFail("Cancelled preparation must not return geometry.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testThousandPageFixtureRequestsOnlyMiddleAndLastPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-NativeWorker-1001-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("thousand-pages.pdf"), data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 240)
        let renderer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        ]
        func quote(_ page: Int) -> String { "Synthetic native page \(page)." }
        for page in 1...1001 {
            renderer.beginPDFPage(nil); renderer.textMatrix = .identity
            renderer.textPosition = CGPoint(x: 32, y: 160)
            let value = NSAttributedString(string: quote(page), attributes: attributes)
            CTLineDraw(CTLineCreateWithAttributedString(value as CFAttributedString), renderer)
            renderer.endPDFPage()
        }
        renderer.closePDF()
        let generated = try XCTUnwrap(PDFDocument(data: data as Data))
        XCTAssertTrue(generated.write(to: url))
        let reference = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reference.pageCount, 1001)
        let original = try Data(contentsOf: url)
        let session = NativePDFPreparationWorker.Session(url: url, sourceHash: try BookImporter.sha256(original), generation: 1)
        let worker = NativePDFPreparationWorker(), progress = ProgressLog()
        let requestedPages = [501, 1001]
        for number in requestedPages {
            let page = try XCTUnwrap(reference.page(at: number - 1)), text = try XCTUnwrap(page.string)
            let range = NSRange(try XCTUnwrap(text.range(of: quote(number), options: .literal)), in: text)
            let expectedGeometry = NativePDFTextLine.rectangles(for: range, on: page)
            XCTAssertFalse(expectedGeometry.isEmpty)
            let prepared = try await worker.preparePage(session: session, page: number, onProgress: { progress.append($0) })
            XCTAssertEqual(prepared.page, number)
            XCTAssertTrue(prepared.text.utf8.elementsEqual(text.utf8))
            XCTAssertEqual(prepared.byteCount, text.utf8.count)
            XCTAssertEqual(prepared.nativeCharacterCount, page.numberOfCharacters)
            XCTAssertEqual(prepared.crop, page.bounds(for: .cropBox)); XCTAssertEqual(prepared.rotation, page.rotation)
            for rectangle in expectedGeometry {
                let point = CGPoint(x: rectangle.midX, y: rectangle.midY)
                XCTAssertTrue(prepared.directory.lines(at: point).contains { $0.intersects(range) })
            }
            let geometry = try await worker.prepareGeometry(session: session, page: number,
                requests: [.init(id: "requested-page", range: range)], onProgress: { progress.append($0) })
            XCTAssertEqual(geometry["requested-page"], expectedGeometry)
        }
        // This observes requested preparation pages, not PDFKit's internal file
        // parsing or elapsed time. The source hash necessarily reads all bytes.
        let values = progress.values
        XCTAssertEqual(Set(values.compactMap(\.page)), Set(requestedPages))
        XCTAssertEqual(values.filter { $0.phase == .pageText && $0.completed == nil }.compactMap(\.page), requestedPages)
        XCTAssertEqual(values.filter { $0.phase == .geometry && $0.completed == 1 }.compactMap(\.page), requestedPages)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testUnverifiedSymlinkNonregularAndOversizedFilesAreRejected() async throws {
        let source = try fixture(["文件门禁。"])
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let worker = NativePDFPreparationWorker()
        let link = source.directory.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.url)
        let oversized = source.directory.appendingPathComponent("oversized.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 256 * 1_024 * 1_024 + 1); try handle.close()
        for (url, hash) in [(source.url, ""), (source.url, "wrong"), (link, source.hash), (source.directory, source.hash), (oversized, source.hash)] {
            let session = NativePDFPreparationWorker.Session(url: url, sourceHash: hash, generation: 1)
            do { _ = try await worker.preparePage(session: session, page: 1); XCTFail("Unverified source must be rejected.") }
            catch { }
        }
    }
}
#endif
