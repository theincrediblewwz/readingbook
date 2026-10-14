import Foundation
import XCTest
@testable import ReadingCore

final class RecoveryTests: XCTestCase {
    private func makeFixture() async throws -> (directory: URL, root: URL, repository: LibraryRepository, project: BookProject) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("original.txt")
        try Data("原文始终保留。人物参与事件。\n".utf8).write(to: source, options: .atomic)
        let project = try await BookImporter.importFile(at: source)
        let root = directory.appendingPathComponent("library", isDirectory: true)
        let repository = LibraryRepository(rootURL: root)
        try await repository.create(project, sourceURL: source)
        return (directory, root, repository, project)
    }

    func testDocumentTrashKeepsCanonicalMarkdownAssociationsAndPortableStatus() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let document = DocumentRecord(id: "user-note", title: "用户理解", linkedIDs: [fixture.project.units[0].id])
        let body = "# 用户理解\n\n保留真实 Markdown 与 $x^2$。\n"
        var saved = try await fixture.repository.saveDocument(project: fixture.project, document: document, markdown: body)
        saved.title = "磁盘上的最新标题"
        saved.nodes = [CanvasNode(id: "note-node", targetID: document.id, x: 10, y: 20)]
        try await fixture.repository.save(saved)
        // A legacy document has no trash field at all.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        legacy.removeValue(forKey: "trashedAt")
        let decoded = try JSONDecoder().decode(DocumentRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.trashedAt)
        let trashed = try await fixture.repository.setDocumentTrashed(project: fixture.project, documentID: document.id, trashed: true)
        XCTAssertEqual(trashed.title, "磁盘上的最新标题", "回收操作不得用旧窗口状态覆盖 canonical 元数据。")
        XCTAssertTrue(trashed.activeDocuments.isEmpty)
        XCTAssertEqual(trashed.trashedDocuments.map(\.id), [document.id])
        XCTAssertEqual(trashed.nodes, saved.nodes)
        let retainedBody = try await fixture.repository.readDocument(bookID: saved.id, document: document)
        XCTAssertEqual(retainedBody, body)
        do {
            _ = try await fixture.repository.saveDocument(project: saved, document: document, markdown: "旧编辑器不应覆盖回收内容")
            XCTFail("A stale editor must not overwrite a trashed document.")
        } catch { }
        try await fixture.repository.save(saved)
        let loaded = try await fixture.repository.loadAll()
        XCTAssertEqual(loaded.first?.trashedDocuments.count, 1, "普通保存不得暗中恢复已回收文档。")
        let package = fixture.directory.appendingPathComponent("trashed-note.readingbook", isDirectory: true)
        try await fixture.repository.exportProject(saved, to: package)
        let imported = try await fixture.repository.importProject(from: package)
        XCTAssertEqual(imported.trashedDocuments.count, 1)
        let importedBody = try await fixture.repository.readDocument(bookID: imported.id, document: imported.documents[0])
        XCTAssertEqual(importedBody, body)
        let restored = try await fixture.repository.setDocumentTrashed(project: saved, documentID: document.id, trashed: false)
        XCTAssertEqual(restored.activeDocuments.count, 1)
        XCTAssertEqual(restored.nodes, saved.nodes)
        let restoredBody = try await fixture.repository.readDocument(bookID: restored.id, document: restored.documents[0])
        XCTAssertEqual(restoredBody, body)
    }

    func testWholeBookArchiveAndRestoreKeepOriginalAndNeverOverwriteCollision() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let document = DocumentRecord(id: "note", title: "保留的笔记")
        let saved = try await fixture.repository.saveDocument(project: fixture.project, document: document, markdown: "# 原笔记\n")
        try await fixture.repository.archiveBook(project: saved)
        let active = try await fixture.repository.loadAll()
        let archived = try await fixture.repository.archivedBooks()
        XCTAssertTrue(active.isEmpty)
        XCTAssertEqual(archived.map(\.id), [saved.id])
        let archivedSource = fixture.root.appendingPathComponent("trash/\(saved.id)/source/\(saved.originalName)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedSource.path))
        let occupied = fixture.root.appendingPathComponent("books/\(saved.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let sentinel = occupied.appendingPathComponent("existing.txt")
        try Data("existing data".utf8).write(to: sentinel)
        do { _ = try await fixture.repository.restoreBook(id: saved.id); XCTFail("Restoring must not overwrite an occupied UUID.") } catch { }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "existing data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedSource.path))
        try FileManager.default.removeItem(at: occupied)
        do { _ = try await fixture.repository.restoreBook(id: "../outside"); XCTFail("Traversal must be rejected.") } catch { }
        let restored = try await fixture.repository.restoreBook(id: saved.id)
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(restored.sourceHash, saved.sourceHash)
        let restoredBody = try await fixture.repository.readDocument(bookID: restored.id, document: restored.documents[0])
        XCTAssertEqual(restoredBody, "# 原笔记\n")
        let remaining = try await fixture.repository.archivedBooks()
        let restoredActive = try await fixture.repository.loadAll()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(restoredActive.map(\.id), [saved.id])
    }

    func testKnowledgeDeletionCleansSharedReferencesAndKeepsSourceAndDocuments() throws {
        let unit = SourceUnit(id: "unit", order: 0, chapter: "原文", text: "人物在地点参与事件。")
        var project = BookProject(title: "关联测试", originalName: "book.txt", sourceHash: String(repeating: "0", count: 64), units: [unit])
        project.entities = [KnowledgeEntity(id: "person", typeID: "person", name: "人物"), KnowledgeEntity(id: "place", typeID: "place", name: "地点")]
        project.events = [KnowledgeEvent(id: "event", name: "事件", placeIDs: ["place"], participantIDs: ["person"])]
        project.relations = [KnowledgeRelation(id: "r1", fromID: "person", toID: "event", label: "参与"), KnowledgeRelation(id: "r2", fromID: "event", toID: "place", label: "发生于")]
        project.documents = [DocumentRecord(id: "doc", title: "用户文档", linkedIDs: ["person", "event", "place", "unit"])]
        project.nodes = [CanvasNode(id: "n-person", targetID: "person"), CanvasNode(id: "n-event", targetID: "event"), CanvasNode(id: "n-doc", targetID: "doc")]
        project.edges = [CanvasEdge(id: "e1", fromID: "n-person", toID: "n-event"), CanvasEdge(id: "e2", fromID: "n-event", toID: "n-doc")]
        let withoutPerson = try KnowledgeDeletion.removingEntity(id: "person", from: project)
        XCTAssertTrue(withoutPerson.events[0].participantIDs.isEmpty)
        XCTAssertEqual(withoutPerson.events[0].placeIDs, ["place"])
        XCTAssertEqual(withoutPerson.relations.map(\.id), ["r2"])
        XCTAssertEqual(withoutPerson.edges.map(\.id), ["e2"])
        let withoutEvent = try KnowledgeDeletion.removingEvent(id: "event", from: withoutPerson)
        XCTAssertTrue(withoutEvent.events.isEmpty)
        XCTAssertTrue(withoutEvent.relations.isEmpty)
        XCTAssertTrue(withoutEvent.edges.isEmpty)
        XCTAssertEqual(withoutEvent.nodes.map(\.id), ["n-doc"])
        XCTAssertEqual(withoutEvent.documents[0].linkedIDs, ["place", "unit"])
        XCTAssertEqual(withoutEvent.documents[0].relativePath, project.documents[0].relativePath)
        XCTAssertEqual(withoutEvent.documents[0].title, "用户文档")
        XCTAssertEqual(withoutEvent.units, project.units)
        XCTAssertEqual(project.entities.count, 2, "传入的值类型项目不得被半写。")
        XCTAssertThrowsError(try KnowledgeDeletion.removingEntity(id: "unknown", from: project))
    }
}
