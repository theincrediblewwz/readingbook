import Foundation
import XCTest
@testable import ReadingCore

final class ReadingSurfaceRefinementTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let source: URL
        let repository: LibraryRepository
        var book: BookProject
        let note: DocumentRecord
        var package: URL { root.appendingPathComponent("library/books/" + book.id) }
        var body: URL { package.appendingPathComponent("docs/" + note.id + ".md") }
    }
    private func fixture() async throws -> Fixture {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".build/reading-surface-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.txt")
        try Data("原书只保留。王允问，吕布答。".utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        let imported = try await BookImporter.importFile(at: source)
        var book = try await repository.create(imported, sourceURL: source)
        let note = DocumentRecord(id: "note", title: "同名标题")
        book = try await repository.saveDocument(project: book, document: note, markdown: "实际便签正文 e\u{301} 👩🏽‍💻", notePlacement: .init(sourceHash: book.sourceHash, unitID: book.units[0].id, page: book.units[0].page, x: 0.6, y: 0.4))
        return Fixture(root: root, source: source, repository: repository, book: book, note: note)
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(value)
    }
    private func fails(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected a refusal without a write", file: file, line: line) } catch { }
    }

    func testFoldedPreviewShowsBodyWithoutRepeatingTitleOrInternalMarkup() {
        let source = "# 这句话的意思\n\n<!-- conversation-message: private-marker -->\n\n王允是在试探。 [回到原文](readingbook://book/id?quote=%E4%B8%AD) e\u{301} 👩🏽‍💻"
        let preview = FoldedReadingPreview.make(source, title: "这句话的意思")
        XCTAssertTrue(preview.hasPrefix("王允是在试探。"))
        XCTAssertTrue(preview.contains("回到原文")); XCTAssertTrue(preview.contains("e\u{301} 👩🏽‍💻"))
        XCTAssertFalse(preview.contains("private-marker")); XCTAssertFalse(preview.contains("readingbook://"))
        XCTAssertEqual(source, "# 这句话的意思\n\n<!-- conversation-message: private-marker -->\n\n王允是在试探。 [回到原文](readingbook://book/id?quote=%E4%B8%AD) e\u{301} 👩🏽‍💻")
    }

    func testFoldedPreviewBoundsLongBodiesAndPreservesWholeGraphemes() {
        let source = String(repeating: "👩🏽‍💻", count: 50_000)
        let preview = FoldedReadingPreview.make(source, limit: 12)
        XCTAssertEqual(preview, String(repeating: "👩🏽‍💻", count: 12) + "…")
        XCTAssertEqual(FoldedReadingPreview.make("<!-- unclosed internal data"), "")
        XCTAssertEqual(FoldedReadingPreview.make("abc", limit: 0), "")
    }

    func testCollapsedNotePreviewReadsOnlyPrefixAndChecksCurrentOwner() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let body = "可见开头 " + String(repeating: "中", count: 6000) + "独有末尾"
        let before = try await f.repository.readDocumentSnapshot(bookID: f.book.id, document: f.note)
        let book = try await f.repository.saveDocument(project: f.book, document: f.note, markdown: body, expectedContentHash: before.contentHash)
        let note = try XCTUnwrap(book.activeDocuments.first)
        let hint = try await f.repository.readFoldedNotePreview(bookID: book.id, sourceHash: book.sourceHash, document: note)
        XCTAssertTrue(hint.hasPrefix("可见开头")); XCTAssertFalse(hint.contains("独有末尾")); XCTAssertLessThanOrEqual(hint.count, 91)
        await fails { _ = try await f.repository.readFoldedNotePreview(bookID: book.id, sourceHash: "wrong-source", document: note) }
        XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), body)
    }

    func testPermanentNoteDeletionRetainsOriginalOtherNotesAndValidGraph() async throws {
        var f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let other = DocumentRecord(id: "other", title: "保留")
        f.book = try await f.repository.saveDocument(project: f.book, document: other, markdown: "不能删除")
        f.book.nodes = [CanvasNode(id: "note-node", targetID: f.note.id, x: 10, y: 20), CanvasNode(id: "other-node", targetID: other.id, x: 50, y: 60)]
        f.book.edges = [CanvasEdge(id: "edge", fromID: "note-node", toID: "other-node", label: "旧关联")]
        f.book = try await f.repository.save(f.book)
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: f.note.id, trashed: true)
        let original = try Data(contentsOf: f.source)
        let plan = try await f.repository.previewTrashPurge([.document(bookID: f.book.id, id: f.note.id)])
        let committed = try await f.repository.commitTrashPurge(plan)
        let saved = try XCTUnwrap(committed.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.body.path))
        XCTAssertEqual(saved.documents.map(\.id), [other.id]); XCTAssertEqual(saved.nodes.map(\.id), ["other-node"]); XCTAssertTrue(saved.edges.isEmpty)
        XCTAssertNil(saved.readerCollections?.notePlacements?[f.note.id])
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("source/original.txt")), original)
        let otherBody = try await f.repository.readDocument(bookID: f.book.id, document: saved.documents[0]); XCTAssertEqual(otherBody, "不能删除")
        await fails { _ = try await f.repository.save(f.book) }
        let reloaded = try await f.repository.loadAll()
        XCTAssertEqual(reloaded.first?.documents.map(\.id), [other.id])
    }

    func testRestorationAfterPurgePreviewInvalidatesConfirmationWithoutDeletion() async throws {
        var f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: f.note.id, trashed: true)
        let plan = try await f.repository.previewTrashPurge([.document(bookID: f.book.id, id: f.note.id)])
        _ = try await f.repository.setDocumentTrashed(project: f.book, documentID: f.note.id, trashed: false)
        let before = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        await fails { _ = try await f.repository.commitTrashPurge(plan) }
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("project.json")), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.body.path))
    }

    func testDeletePlanIsBoundToRepositoryAndRejectsActiveBooksAndNotes() async throws {
        var f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await fails { _ = try await f.repository.previewTrashPurge([.document(bookID: f.book.id, id: f.note.id)]) }
        await fails { _ = try await f.repository.previewTrashPurge([.book(f.book.id)]) }
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: f.note.id, trashed: true)
        let plan = try await f.repository.previewTrashPurge([.document(bookID: f.book.id, id: f.note.id)])
        let foreign = LibraryRepository(rootURL: f.root.appendingPathComponent("library"))
        await fails { _ = try await foreign.commitTrashPurge(plan) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.body.path))
    }

    func testPurgeListsDependentRecoveryDeltasAndDoesNotChangeActiveObjects() async throws {
        var f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if f.book.types.isEmpty { f.book.types = [.init(id: "person-type", name: "人物")] }
        f.book.entities = [KnowledgeEntity(id: "person", typeID: f.book.types[0].id, name: "人物"), KnowledgeEntity(id: "keep", typeID: f.book.types[0].id, name: "保留人物")]
        f.book.documents[0].linkedIDs = ["person"]
        f.book = try await f.repository.save(f.book)
        f.book = try await f.repository.trashManualItem(project: f.book, kind: .entity, id: "person")
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: f.note.id, trashed: true)
        let plan = try await f.repository.previewTrashPurge([.document(bookID: f.book.id, id: f.note.id)])
        XCTAssertEqual(plan.titles.count, 2); XCTAssertTrue(plan.titles.contains { $0.hasPrefix("关联恢复快照：") })
        let committed = try await f.repository.commitTrashPurge(plan)
        let saved = try XCTUnwrap(committed.first)
        XCTAssertTrue(saved.manualTrash?.items.isEmpty == true); XCTAssertEqual(saved.entities.map(\.id), ["keep"])
    }

    func testPurgeNeverFollowsNoteSymlink() async throws {
        var f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: f.note.id, trashed: true)
        let outside = f.root.appendingPathComponent("outside.md"); try Data("必须保留".utf8).write(to: outside)
        try FileManager.default.removeItem(at: f.body); try FileManager.default.createSymbolicLink(at: f.body, withDestinationURL: outside)
        await fails { _ = try await f.repository.previewTrashPurge([.document(bookID: f.book.id, id: f.note.id)]) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "必须保留")
    }

    func testInterruptedConfirmedNotePurgeRecoversWithoutTouchingSource() async throws {
        var f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: f.note.id, trashed: true)
        let before = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        let updated = try LibraryTrashPurgeRuntime.removing(documents: [f.note.id], manualIDs: [], in: f.book)
        struct Journal: Encodable { var version = 1; let beforeHash: String; let afterHash: String; let project: BookProject; let documentHashes: [String: String] }
        let journal = Journal(beforeHash: try BookImporter.sha256(before), afterHash: try BookImporter.sha256(encoded(updated)), project: updated,
            documentHashes: [f.note.id: try BookImporter.sha256(Data(contentsOf: f.body))])
        try encoded(journal).write(to: f.package.appendingPathComponent(".trash-purge-pending.json"))
        let restarted = LibraryRepository(rootURL: f.root.appendingPathComponent("library"))
        let loaded = try await restarted.loadAll()
        XCTAssertEqual(loaded.count, 1); XCTAssertTrue(loaded[0].documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.body.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: f.package.appendingPathComponent(".trash-purge-pending.json").path))
        XCTAssertEqual(try Data(contentsOf: f.source), try Data(contentsOf: f.package.appendingPathComponent("source/original.txt")))
    }

    func testPaperBookPreferenceIsOptionalAndRoundTripsWithoutChangingSourceFields() throws {
        let old = WorkspacePDFMemory(page: 104, scale: 2.5, fitMode: "width", continuous: true, direction: .vertical)
        let oldData = try encoded(old)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("paperBook"))
        XCTAssertNil(try JSONDecoder().decode(WorkspacePDFMemory.self, from: oldData).paperBook)
        var bookMode = old; bookMode.paperBook = true
        let decoded = try JSONDecoder().decode(WorkspacePDFMemory.self, from: encoded(bookMode))
        XCTAssertEqual(decoded.paperBook, true); XCTAssertEqual(decoded.page, old.page); XCTAssertEqual(decoded.location, old.location)
    }

    func testArchivedBookPurgeChecksWholeTreeAndKeepsImportOriginal() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try Data(contentsOf: f.source)
        try await f.repository.archiveBook(project: f.book)
        let first = try await f.repository.previewTrashPurge([.book(f.book.id)])
        let archived = f.root.appendingPathComponent("library/trash/" + f.book.id)
        let extra = archived.appendingPathComponent("docs/just-added.md")
        try Data("确认之后才新加的资料".utf8).write(to: extra)
        await fails { _ = try await f.repository.commitTrashPurge(first) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
        let fresh = try await f.repository.previewTrashPurge([.book(f.book.id)])
        _ = try await f.repository.commitTrashPurge(fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archived.path))
        XCTAssertEqual(try Data(contentsOf: f.source), original)
    }

    func testPurgePreflightsAllBooksBeforeDeletingAnyNote() async throws {
        var f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: f.note.id, trashed: true)
        let secondSource = f.root.appendingPathComponent("second.txt"); try Data("另一本原书".utf8).write(to: secondSource)
        let imported = try await BookImporter.importFile(at: secondSource)
        var second = try await f.repository.create(imported, sourceURL: secondSource)
        let note = DocumentRecord(id: "second-note", title: "另一篇笔记")
        second = try await f.repository.saveDocument(project: second, document: note, markdown: "第二篇正文")
        second = try await f.repository.setDocumentTrashed(project: second, documentID: note.id, trashed: true)
        let plan = try await f.repository.previewTrashPurge([.document(bookID: f.book.id, id: f.note.id), .document(bookID: second.id, id: note.id)])
        _ = try await f.repository.setDocumentTrashed(project: second, documentID: note.id, trashed: false)
        await fails { _ = try await f.repository.commitTrashPurge(plan) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.body.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("library/books/" + second.id + "/docs/second-note.md").path))
    }
}
