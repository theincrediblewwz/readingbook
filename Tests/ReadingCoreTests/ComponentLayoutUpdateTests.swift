import Foundation
import XCTest
@testable import ReadingCore

final class ComponentLayoutUpdateTests: XCTestCase {
    private func fixture() -> (BookProject, ViewDefinition) {
        var book = BookProject(id: "layout-book", title: "赤壁", originalName: "book.txt", sourceHash: "hash", units: [
            .init(id: "u1", order: 0, chapter: "赤壁", text: "黄盖火攻。")])
        PluginEngine.seed(&book)
        let composition = ReadingWorkbench.definition(for: ReadingWorkbench.timeMapTemplateID)!
        let view = ViewDefinition(id: "canvas", title: "已有画布", kind: .cards, rendererID: "reading.composition", composition: composition)
        book.views = [view]; return (book, view)
    }
    private func adjusted(_ original: CompositionDefinition) -> [CompositionLayoutNode] {
        var layout = original.layout
        layout[0].fraction = 0.4
        return layout
    }
    func testSmallChangeAndOneStepRestoreKeepBindingsAndIdentity() throws {
        let (book, view) = fixture(), old = view.composition!
        let changed = try ReadingComponentLayout.changed(view, expectedRevision: ReadingComponentLayout.revision(old), layout: adjusted(old), rootID: nil, restore: false, in: book)
        XCTAssertEqual(changed.id, view.id); XCTAssertEqual(changed.title, view.title)
        XCTAssertEqual(changed.composition?.sources, old.sources); XCTAssertEqual(changed.composition?.parts, old.parts)
        XCTAssertEqual(changed.previousLayout?.layout, old.layout)
        let restored = try ReadingComponentLayout.changed(changed, expectedRevision: ReadingComponentLayout.revision(changed.composition!), layout: nil, rootID: nil, restore: true, in: book)
        XCTAssertEqual(restored.composition, old); XCTAssertEqual(restored.previousLayout?.layout, changed.composition?.layout)
        XCTAssertLessThan(try JSONEncoder().encode(restored.previousLayout).count, 32_768)
    }
    func testRevisionAndValidationRejectStaleOrInvalidUpdateWithoutMutation() throws {
        let (book, view) = fixture(), old = view.composition!
        XCTAssertThrowsError(try ReadingComponentLayout.changed(view, expectedRevision: String(repeating: "0", count: 64), layout: adjusted(old), rootID: nil, restore: false, in: book))
        XCTAssertThrowsError(try ReadingComponentLayout.changed(view, expectedRevision: ReadingComponentLayout.revision(old), layout: [], rootID: nil, restore: false, in: book))
        var invalid = old.layout; invalid[0].children = ["missing"]
        XCTAssertThrowsError(try ReadingComponentLayout.changed(view, expectedRevision: ReadingComponentLayout.revision(old), layout: invalid, rootID: nil, restore: false, in: book))
        XCTAssertNil(view.previousLayout); XCTAssertEqual(book.views, [view])
    }
    func testRestoreCannotReintroduceBindingsChangedByAnotherWriter() throws {
        let (book, view) = fixture(), old = view.composition!
        var changed = try ReadingComponentLayout.changed(view, expectedRevision: ReadingComponentLayout.revision(old), layout: adjusted(old), rootID: nil, restore: false, in: book)
        changed.composition?.parts[0].title = "另一次编辑的新绑定"
        XCTAssertThrowsError(try ReadingComponentLayout.changed(changed, expectedRevision: ReadingComponentLayout.revision(changed.composition!), layout: nil, rootID: nil, restore: true, in: book))
    }
    func testNoOpDoesNotCreateHistoryAndOldViewDecodesWithoutBackup() throws {
        let (book, view) = fixture(), old = view.composition!
        XCTAssertEqual(try ReadingComponentLayout.changed(view, expectedRevision: ReadingComponentLayout.revision(old), layout: old.layout, rootID: nil, restore: false, in: book), view)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as? [String: Any]); raw.removeValue(forKey: "previousLayout")
        let decoded = try JSONDecoder().decode(ViewDefinition.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(decoded, view); XCTAssertNil(decoded.previousLayout)
        var inline = view; inline.configuration = ["presentation":"inline"]
        XCTAssertThrowsError(try ReadingComponentLayout.changed(inline, expectedRevision: ReadingComponentLayout.revision(old), layout: old.layout, rootID: nil, restore: false, in: book))
    }
    func testClosedRequestRequiresExistingViewAndMatchingRevision() throws {
        let (_, view) = fixture(), old = view.composition!
        let request = ReadingComponentRequest(viewID: view.id, layout: adjusted(old), layoutRevision: try ReadingComponentLayout.revision(old))
        XCTAssertEqual(try ReadingComponentRequest.decode(JSONEncoder().encode(request)).layout, request.layout)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        for field in ["viewID", "layoutRevision"] {
            var invalid = raw; invalid[field] = nil
            XCTAssertThrowsError(try ReadingComponentRequest.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
        raw["composition"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
        XCTAssertThrowsError(try ReadingComponentRequest.decode(JSONSerialization.data(withJSONObject: raw)))
        XCTAssertThrowsError(try ReadingComponentRequest.decode(Data(#"{"viewID":"canvas","restoreLayout":true,"layoutRevision":"bad"}"#.utf8)))
    }
    func testCanonicalAdjustmentKeepsFreshNotesFactsAndViewCount() async throws {
        let pair = fixture(); var book = pair.0; let view = pair.1
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.txt"); try Data(book.units[0].text.utf8).write(to: source)
        book.id = UUID().uuidString
        book.sourceHash = try BookImporter.sha256(Data(contentsOf: source))
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        var latest = try await repository.create(book, sourceURL: source)
        latest.entities.append(.init(id: "h", typeID: "person", name: "黄盖", evidence: [.init(unitID: "u1", quote: "黄盖火攻。")]))
        let note = DocumentRecord(id: "note", title: "读者的新笔记")
        latest = try await repository.saveDocument(project: latest, document: note, markdown: "不能覆盖的原话。")
        let result = try await repository.updateReadingComponentLayout(bookID: book.id, sourceHash: book.sourceHash, viewID: view.id,
            expectedRevision: ReadingComponentLayout.revision(view.composition!), layout: adjusted(view.composition!))
        XCTAssertFalse(result.created); XCTAssertEqual(result.project.views.count, 1)
        XCTAssertEqual(result.project.entities, latest.entities); XCTAssertEqual(result.project.documents, latest.documents)
        let body = try await repository.readDocument(bookID: book.id, document: note); XCTAssertEqual(body, "不能覆盖的原话。")
        let restored = try await repository.updateReadingComponentLayout(bookID: book.id, sourceHash: book.sourceHash, viewID: view.id,
            expectedRevision: ReadingComponentLayout.revision(result.view.composition!), layout: nil, restore: true)
        XCTAssertEqual(restored.view.composition, view.composition); XCTAssertEqual(restored.project.entities, latest.entities)
        let file = root.appendingPathComponent("library/books/\(book.id)/project.json"), bytes = try Data(contentsOf: file)
        do { _ = try await repository.updateReadingComponentLayout(bookID: book.id, sourceHash: "wrong", viewID: view.id,
            expectedRevision: ReadingComponentLayout.revision(view.composition!), layout: adjusted(view.composition!)); XCTFail("source changed") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
