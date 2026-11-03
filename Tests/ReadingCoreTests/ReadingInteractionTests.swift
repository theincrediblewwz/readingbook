import Foundation
import XCTest
import PDFKit
import CoreText
@testable import ReadingCore

final class ReadingInteractionTests: XCTestCase {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/reading-interaction-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func pdfData() throws -> Data {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 420, height: 540)
        let context = CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &box, nil)!
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            for (index, value) in ["Same sentence. Same sentence.", "A third sentence to discuss."].enumerated() {
                context.textMatrix = .identity; context.textPosition = .init(x: 30, y: 440 - index * 40)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)]) as CFAttributedString), context)
            }
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    private func fixture(_ root: URL) async throws -> (LibraryRepository, BookProject, Data) {
        let data = try pdfData(), source = root.appendingPathComponent("source.pdf"); try data.write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        let book = try await repository.create(BookImporter.importFile(at: source), sourceURL: source)
        return (repository, book, data)
    }
    private func placement(_ book: BookProject, style: String? = nil) -> ReadingNotePlacement {
        .init(sourceHash: book.sourceHash, unitID: book.units[0].id, page: 1, x: 0.7, y: 0.8, paperStyle: style)
    }
    private func record(_ book: BookProject) -> ReaderAnnotation {
        .init(sourceHash: book.sourceHash, page: 1, text: "Same sentence.", rangeLocation: 0, rangeLength: 14, quads: [.init(x: 30, y: 435, width: 100, height: 18)], lineStyle: .wavy)
    }
    func testLegacyPlacementInheritsColorWithoutChangingCoordinates() throws {
        let raw = Data(#"{"sourceHash":"hash","unitID":"p1","page":1,"x":0.2,"y":0.3,"fontFamily":"serif","fontSize":15}"#.utf8)
        let value = try JSONDecoder().decode(ReadingNotePlacement.self, from: raw)
        XCTAssertNil(value.paperStyle); XCTAssertNil(value.quote); XCTAssertEqual(value.x, 0.2); try value.validate()
    }
    func testEachExplicitPaperColorAndQuoteRoundTrips() throws {
        for style in ["plain", "warm-cotton", "mist-white", "sage-paper"] {
            let quote = ReadingNoteSourceQuote(text: "原句 e\u{301} 👩🏽‍💻", ranges: [.init(page: 1, location: 12, length: 14)])
            let value = ReadingNotePlacement(sourceHash: "hash", unitID: "p1", page: 1, x: 0.2, y: 0.3, paperStyle: style, quote: quote)
            try value.validate(); XCTAssertEqual(try JSONDecoder().decode(ReadingNotePlacement.self, from: JSONEncoder().encode(value)), value)
        }
    }
    func testInvalidColorAndQuoteAreRejected() throws {
        var value = ReadingNotePlacement(sourceHash: "hash", unitID: "p1", page: 1, x: 0.2, y: 0.3, paperStyle: "arbitrary-file.png")
        XCTAssertThrowsError(try value.validate()); value.paperStyle = nil
        for range in [ReadingNoteQuoteRange(page: 0, location: 0, length: 1), .init(page: 1, location: Int.max, length: 1), .init(page: 1, location: 0, length: 0)] {
            value.quote = .init(text: "原句", ranges: [range]); XCTAssertThrowsError(try value.validate())
        }
    }
    func testIndependentHighlighterRejectsInvalidDataAndLineCoupling() throws {
        var appearance = ReaderHighlightAppearance(); XCTAssertTrue(appearance.isValid)
        appearance.saturation = .nan; XCTAssertFalse(appearance.isValid)
        appearance = .init(); appearance.opacity = 0.9; XCTAssertFalse(appearance.isValid)
        let book = BookProject(title: "PDF", originalName: "source.pdf", sourceHash: "hash", units: [.init(id: "p1", order: 0, chapter: "章", page: 1, text: "Same sentence.")])
        var mark = record(book); mark.highlightAppearance = .init()
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(mark, in: book))
        mark.lineStyle = nil; try ReaderAnnotationValidator.validate(mark, in: book)
        XCTAssertNil(mark.lineAppearance)
        let native = try XCTUnwrap(ReaderAnnotationAppearance.make(mark, quad: mark.quads[0], crop: .init(x: 0, y: 0, width: 420, height: 540)))
        XCTAssertEqual(native.type, "Highlight")
        XCTAssertEqual(native.color.alphaComponent, 0.32, accuracy: 0.001)
    }
    func testUnpreparedContextClickUsesTheSecondEqualSentence() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: pdfData())), page = try XCTUnwrap(pdf.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString, range = source.range(of: "Same sentence.", options: .backwards)
        let glyph = page.characterBounds(at: range.location + 3), point = CGPoint(x: glyph.midX, y: glyph.midY)
        let mark = try XCTUnwrap(ReaderAnnotationCapture.sentence(at: point, page: page, document: pdf, sourceHash: "hash"))
        XCTAssertEqual(mark.rangeLocation, range.location); XCTAssertEqual(mark.text, "Same sentence.")
        let selected = try XCTUnwrap(page.selection(for: range))
        let captured = try XCTUnwrap(ReaderAnnotationCapture.capture(selection: selected, document: pdf, sourceHash: "hash").first)
        XCTAssertEqual(captured.rangeLocation, mark.rangeLocation); XCTAssertEqual(captured.rangeLength, mark.rangeLength)
        XCTAssertNil(try ReaderAnnotationCapture.sentence(at: .init(x: 410, y: 20), page: page, document: pdf, sourceHash: "hash"))
        page.rotation = 90
        let rotated = try XCTUnwrap(ReaderAnnotationCapture.sentence(at: point, page: page, document: pdf, sourceHash: "hash"))
        XCTAssertEqual(rotated.rangeLocation, range.location)
    }
    func testPhysicalSecondLineHitUsesNativeRangeInsteadOfGlyphIndex() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: pdfData())), page = try XCTUnwrap(pdf.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString, expected = source.range(of: "A third sentence to discuss.")
        // Independent oracle: the fixture draws this line at (30,400), in
        // 16-point Helvetica. Do not derive the point from characterBounds.
        let point = CGPoint(x: 34, y: 405), hit = try XCTUnwrap(PDFNativeTextGeometry.character(at: point, on: page))
        XCTAssertEqual(hit.range.location, expected.location)
        XCTAssertTrue(hit.bounds.contains(point))
        let mark = try XCTUnwrap(ReaderAnnotationCapture.sentence(at: point, page: page, document: pdf, sourceHash: "hash"))
        XCTAssertEqual(mark.text, "A third sentence to discuss.")
        XCTAssertEqual(mark.rangeLocation, expected.location)
        XCTAssertNil(PDFNativeTextGeometry.character(at: .init(x: 410, y: 20), on: page))
    }
    func testQuotedMidpointUsesItsOwnPhysicalLineAfterNewlines() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: pdfData())), page = try XCTUnwrap(pdf.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString, range = source.range(of: "A third sentence to discuss.")
        let rect = try XCTUnwrap(PDFNativeTextGeometry.midpoint(in: range, on: page))
        XCTAssertTrue(rect.midY > 395 && rect.midY < 420)
        let hit = try XCTUnwrap(PDFNativeTextGeometry.character(at: .init(x: rect.midX, y: rect.midY), on: page))
        XCTAssertTrue(NSLocationInRange(hit.range.location, range))
        XCTAssertEqual(page.selection(for: hit.range)?.string, source.substring(with: hit.range))
        XCTAssertNil(PDFNativeTextGeometry.midpoint(in: .init(location: source.length + 1, length: 1), on: page))
    }
    func testMarkUndoRedoRetainsConcurrentAnalysisAndOriginalPDF() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (repository, book, data) = try await fixture(root)
        let line = record(book); let saved = try await repository.saveAnnotations(project: book, annotations: [line])
        let active = try XCTUnwrap(saved.readerAnnotations?.first); var removed = active; removed.trashedAt = .now
        var later = saved; later.chats.append(.init(role: "assistant", content: "另一个任务的新回答")); later = try await repository.save(later)
        let undo = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .annotations(expected: [active], desired: [removed]))
        XCTAssertEqual(undo.chats.count, later.chats.count); XCTAssertNotEqual(undo.readerAnnotations?.first?.trashedAt, nil)
        let redo = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .annotations(expected: [removed], desired: [active]))
        XCTAssertNil(redo.readerAnnotations?.first?.trashedAt)
        let source = await repository.sourceURL(for: redo); XCTAssertEqual(try Data(contentsOf: source), data)
    }
    func testStaleMarkUndoBatchIsAtomic() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (repository, book, _) = try await fixture(root)
        let first = record(book); var second = record(book); second.id = UUID().uuidString; second.page = 2
        let saved = try await repository.saveAnnotations(project: book, annotations: [first, second])
        let old = saved.readerAnnotations!; var changes = old; changes[0].trashedAt = .now; changes[1].trashedAt = .now
        var newer = old[1]; newer.comment = "后续手动修改"
        let current = try await repository.saveAnnotations(project: saved, annotations: [newer])
        do { _ = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .annotations(expected: old, desired: changes)); XCTFail("stale batch") } catch { }
        let loaded = try await repository.loadAll(); XCTAssertEqual(loaded[0].readerAnnotations, current.readerAnnotations)
    }
    func testMultiPageSoftRemovalAndExpectedMarkGuard() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (repository, book, _) = try await fixture(root)
        let saved = try await repository.saveAnnotations(project: book, annotations: [record(book)], expectedAnnotations: [])
        var remove = saved.readerAnnotations![0]; remove.trashedAt = .now
        let deleted = try await repository.saveAnnotations(project: saved, annotations: [remove], expectedAnnotations: saved.readerAnnotations)
        XCTAssertNotEqual(deleted.readerAnnotations?.first?.trashedAt, nil)
        do { _ = try await repository.saveAnnotations(project: saved, annotations: saved.readerAnnotations!, expectedAnnotations: saved.readerAnnotations); XCTFail("stale expected active mark") } catch { }
    }
    func testNoteCreationUndoAndRedoKeepOrdinaryMarkdownAndBinding() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (repository, book, data) = try await fixture(root)
        let document = DocumentRecord(id: "note", title: "我的想法"), body = "完全由用户输入。 e\u{301} 👩🏽‍💻"
        var placed = placement(book, style: "warm-cotton"); placed.quote = .init(text: "Same sentence.", ranges: [.init(page: 1, location: 0, length: 14)])
        let saved = try await repository.saveLatestNote(bookID: book.id, sourceHash: book.sourceHash, document: document, markdown: body, notePlacement: placed)
        let original = ReadingNoteUndoSnapshot(document: saved.documents[0], markdown: body, placement: placed)
        var removed = original; removed.document.trashedAt = .now
        let undo = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .note(expected: original, desired: removed))
        XCTAssertTrue(undo.activeDocuments.isEmpty)
        let redo = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .note(expected: removed, desired: original))
        XCTAssertEqual(redo.activeDocuments[0].id, document.id); XCTAssertEqual(redo.readerCollections?.notePlacements?[document.id], placed)
        let actual = try await repository.readDocument(bookID: book.id, document: redo.activeDocuments[0]); XCTAssertEqual(Data(actual.utf8), Data(body.utf8))
        let source = await repository.sourceURL(for: redo); XCTAssertEqual(try Data(contentsOf: source), data)
    }
    func testNoteTextAndColorUndoThenRedoUsesLatestActorTransaction() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (repository, book, _) = try await fixture(root)
        let oldText = "旧文字", newText = "新文字 e\u{301}", document = DocumentRecord(id: "note", title: "原笔记")
        let initial = try await repository.saveDocument(project: book, document: document, markdown: oldText, notePlacement: placement(book))
        let before = ReadingNoteUndoSnapshot(document: initial.documents[0], markdown: oldText, placement: placement(book))
        let updated = try await repository.saveLatestNote(bookID: book.id, sourceHash: book.sourceHash, document: before.document, markdown: newText, expectedDocument: before.document, expectedContentHash: BookImporter.sha256(Data(oldText.utf8)), notePlacement: placement(book, style: "sage-paper"))
        let after = ReadingNoteUndoSnapshot(document: updated.documents[0], markdown: newText, placement: placement(book, style: "sage-paper"))
        let undone = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .note(expected: after, desired: before))
        let undoneText = try await repository.readDocument(bookID: book.id, document: undone.documents[0]); XCTAssertEqual(undoneText, oldText)
        XCTAssertNil(undone.readerCollections?.notePlacements?[document.id]?.paperStyle)
        let redoExpected = ReadingNoteUndoSnapshot(document: undone.documents[0], markdown: oldText, placement: before.placement)
        let redone = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .note(expected: redoExpected, desired: after))
        XCTAssertEqual(redone.readerCollections?.notePlacements?[document.id]?.paperStyle, "sage-paper")
        let redoneText = try await repository.readDocument(bookID: book.id, document: redone.documents[0]); XCTAssertEqual(Data(redoneText.utf8), Data(newText.utf8))
    }
    func testRebindingDuringEditingRejectsSaveAndUndo() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (repository, book, _) = try await fixture(root)
        let document = DocumentRecord(id: "note", title: "原笔记"), body = "原始正文"
        let saved = try await repository.saveDocument(project: book, document: document, markdown: body, notePlacement: placement(book))
        let record = saved.documents[0]; var moved = placement(book); moved.x = 0.3
        let current = try await repository.organizeReaderCollections(bookID: book.id, sourceHash: book.sourceHash, command: .setNotePlacement(record.id, moved))
        do { _ = try await repository.saveLatestNote(bookID: book.id, sourceHash: book.sourceHash, document: record, markdown: "不得覆盖", expectedDocument: record, expectedContentHash: BookImporter.sha256(Data(body.utf8)), notePlacement: placement(book), expectedPlacement: .unchanged(placement(book))); XCTFail("stale placement") } catch { }
        do { _ = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .placement(documentID: record.id, expected: placement(book), desired: nil)); XCTFail("stale undo") } catch { }
        let loaded = try await repository.loadAll(); XCTAssertEqual(loaded[0].readerCollections, current.readerCollections)
        let text = try await repository.readDocument(bookID: book.id, document: record); XCTAssertEqual(text, body)
    }
    func testBookmarkUndoAndWrongSourceCannotTouchNewBook() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (repository, book, _) = try await fixture(root), unit = book.units[0].id
        let changed = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .bookmark(unitID: unit, expected: false, desired: true)); XCTAssertTrue(changed.bookmarks.contains(unit))
        do { _ = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: "wrong", change: .bookmark(unitID: unit, expected: true, desired: false)); XCTFail("source changed") } catch { }
        let undone = try await repository.applyReadingEditUndo(bookID: book.id, sourceHash: book.sourceHash, change: .bookmark(unitID: unit, expected: true, desired: false)); XCTAssertFalse(undone.bookmarks.contains(unit))
    }
}
