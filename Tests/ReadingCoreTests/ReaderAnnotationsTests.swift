import Foundation
import XCTest
@testable import ReadingCore
#if os(macOS)
import PDFKit
import CoreGraphics
import CoreText
#endif

final class ReaderAnnotationsTests: XCTestCase {
    private func project() -> BookProject {
        BookProject(title: "批注", originalName: "source.pdf", sourceHash: String(repeating: "a", count: 64), units: [SourceUnit(id: "p1", order: 0, chapter: "PDF", page: 1, text: "Original text"), SourceUnit(id: "p2", order: 1, chapter: "PDF", page: 2, text: "Second page")])
    }
    private func annotation(_ project: BookProject, page: Int = 1) -> ReaderAnnotation {
        ReaderAnnotation(sourceHash: project.sourceHash, page: page, text: "Original text", rangeLocation: 0, rangeLength: 13, quads: [ReaderQuadRect(x: 20, y: 40, width: 100, height: 12)])
    }
    func testMetadataValidationAndOldJSONCompatibility() throws {
        let project = project()
        let valid = annotation(project)
        XCTAssertNoThrow(try ReaderAnnotationValidator.validate(valid, in: project))
        var bad = valid; bad.rangeLocation = -1
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(bad, in: project))
        bad = valid; bad.rangeLength = Int.max
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(bad, in: project))
        bad = valid; bad.quads[0].width = .nan
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(bad, in: project))
        bad = valid; bad.page = 3
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(bad, in: project))
        bad = valid; bad.sourceHash = "another-source"
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(bad, in: project))
        let region = ReaderAnnotation(sourceHash: project.sourceHash, page: 1, text: "", rangeLocation: 0, rangeLength: 0, quads: [ReaderQuadRect(x: 30, y: 40, width: 100, height: 50)], comment: "图中箭头方向需核对", kind: .region)
        XCTAssertNoThrow(try ReaderAnnotationValidator.validate(region, in: project))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "readerAnnotations")
        let old = try JSONDecoder().decode(BookProject.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.readerAnnotations)
        var annotationJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        annotationJSON.removeValue(forKey: "kind")
        XCTAssertEqual(try JSONDecoder().decode(ReaderAnnotation.self, from: JSONSerialization.data(withJSONObject: annotationJSON)).effectiveKind, .text)
    }

    #if os(macOS)
    private func sourceData() throws -> Data {
        let data = NSMutableData(), box = CGRect(x: 0, y: 0, width: 400, height: 320)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var media = box
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        for text in ["Original first page alpha.", "Second page beta."] {
            context.beginPDFPage(nil)
            context.textMatrix = .identity; context.textPosition = CGPoint(x: 30, y: 200)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            CTLineDraw(line, context); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }

    func testCrossPageCaptureUsesPageLocalRangesAndLineRects() throws {
        let document = try XCTUnwrap(PDFDocument(data: sourceData()))
        document.page(at: 0)?.rotation = 90
        let selection = try XCTUnwrap(document.selectionForEntireDocument)
        let records = try ReaderAnnotationCapture.capture(selection: selection, document: document, sourceHash: String(repeating: "b", count: 64))
        XCTAssertEqual(Set(records.map(\.page)), [1, 2])
        for record in records {
            let page = try XCTUnwrap(document.page(at: record.page - 1))
            XCTAssertEqual(page.selection(for: NSRange(location: record.rangeLocation, length: record.rangeLength))?.string, record.text)
            XCTAssertFalse(record.quads.isEmpty)
            XCTAssertTrue(record.quads.allSatisfy { $0.width > 0 && $0.height > 0 })
        }
    }

    func testAtomicBatchSaveTrashRestoreAndStaleRoutineSavePreserveOriginal() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Annotations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source.pdf"), original = try sourceData()
        try original.write(to: source)
        let project = try await BookImporter.importFile(at: source)
        let repository = LibraryRepository(rootURL: temporary.appendingPathComponent("library"))
        try await repository.create(project, sourceURL: source)
        let first = annotation(project), second = annotation(project, page: 2)
        var saved = try await repository.saveAnnotations(project: project, annotations: [first, second])
        XCTAssertEqual(saved.readerAnnotations?.count, 2)
        saved.title = "最新磁盘标题"
        try await repository.save(saved)
        var invalid = first; invalid.page = 99
        do { _ = try await repository.saveAnnotations(project: project, annotations: [annotation(project), invalid]); XCTFail("Invalid batch must not partially commit.") } catch { }
        saved = try await repository.setAnnotationTrashed(project: project, annotationID: first.id, trashed: true)
        XCTAssertEqual(saved.title, "最新磁盘标题")
        XCTAssertNotNil(saved.readerAnnotations?.first(where: { $0.id == first.id })?.trashedAt)
        try await repository.save(project)
        let staleSafe = try await repository.loadAll()
        XCTAssertEqual(staleSafe[0].readerAnnotations?.count, 2)
        XCTAssertNotNil(staleSafe[0].readerAnnotations?.first(where: { $0.id == first.id })?.trashedAt)
        saved = try await repository.setAnnotationTrashed(project: project, annotationID: first.id, trashed: false)
        XCTAssertNil(saved.readerAnnotations?.first(where: { $0.id == first.id })?.trashedAt)
        let storedSource = await repository.sourceURL(for: saved)
        XCTAssertEqual(try Data(contentsOf: storedSource), original)
    }
    #endif
}
