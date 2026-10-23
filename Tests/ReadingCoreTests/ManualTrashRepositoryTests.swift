import Foundation
import XCTest
@testable import ReadingCore

final class ManualTrashRepositoryTests: XCTestCase {
    private struct Fixture {
        var directory: URL
        var library: URL
        var source: URL
        var repository: LibraryRepository
        var book: BookProject
        var document: DocumentRecord
        var markdown: String
        var package: URL { library.appendingPathComponent("books/\(book.id)") }
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-ManualTrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("book.txt"), text = "208年，曹操到江陵。其后与刘备交战。\n"
        try Data(text.utf8).write(to: source)
        var book = BookProject(title: "回收测试", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)),
                               units: [SourceUnit(id: "u1", order: 0, chapter: "第一章", text: text)])
        PluginEngine.seed(&book)
        let evidence = [Evidence(unitID: "u1", quote: "208年，曹操到江陵。")]
        book.entities = [KnowledgeEntity(id: "person", typeID: "person", name: "曹操", evidence: evidence),
                         KnowledgeEntity(id: "place", typeID: "place", name: "江陵", evidence: evidence)]
        book.events = [KnowledgeEvent(id: "event", name: "至江陵", dateText: "208年", startYear: 208, placeIDs: ["place"], participantIDs: ["person"], evidence: evidence)]
        book.relations = [KnowledgeRelation(id: "relation", fromID: "person", toID: "event", label: "参与", evidence: evidence)]
        let library = directory.appendingPathComponent("library"), repository = LibraryRepository(rootURL: library)
        try await repository.create(book, sourceURL: source)
        let document = DocumentRecord(id: "note", title: "用户笔记", linkedIDs: ["person", "event", "u1"], evidence: evidence)
        let markdown = "# 用户笔记\n\n正文与 $x^2$ 都不能因回收对象改变。\n"
        book = try await repository.saveDocument(project: book, document: document, markdown: markdown)
        var mixed = CanvasNode(id: "mixed", targetID: "person", x: 10, y: 20)
        mixed.documentIDs = [document.id]; mixed.title = "人物与笔记"
        book.nodes = [mixed, CanvasNode(id: "plain", targetID: "person", x: 30, y: 40), CanvasNode(id: "event-node", targetID: "event", x: 300, y: 80)]
        book.edges = [CanvasEdge(id: "mixed-edge", fromID: "mixed", toID: "event-node", label: "保留布局"),
                      CanvasEdge(id: "plain-edge", fromID: "plain", toID: "event-node", label: "恢复时保留")]
        book.graphGroups = [CanvasGroup(id: "group", title: "分组", nodeIDs: ["mixed", "plain"])]
        book.views = [ViewDefinition(id: "map-view", title: "地图", kind: .map, typeIDs: ["person", "place"]),
                      ViewDefinition(id: "timeline-view", title: "时间轴", kind: .timeline)]
        try await repository.save(book)
        return Fixture(directory: directory, library: library, source: source, repository: repository, book: book, document: document, markdown: markdown)
    }
    private func data(_ book: BookProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(book)
    }
    private func latest(_ repository: LibraryRepository) async throws -> BookProject {
        let books = try await repository.loadAll()
        return try XCTUnwrap(books.first)
    }
    private func restore(_ book: BookProject, itemID: String, repository: LibraryRepository) async throws -> BookProject {
        let plan = try ManualTrashRuntime.restorePlan(in: book, itemID: itemID)
        return try await repository.restoreManualItems(project: book, itemID: itemID, expectedItemIDs: plan.itemIDs)
    }

    func testDeletionPersistsAcrossRestartAndRestoresSharedReferencesAndMarkdown() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let removed = try await f.repository.trashManualItem(project: f.book, kind: .entity, id: "person")
        let item = try XCTUnwrap(removed.manualTrash?.items.last)
        XCTAssertFalse(removed.entities.contains { $0.id == "person" })
        XCTAssertFalse(removed.events[0].participantIDs.contains("person"))
        XCTAssertTrue(removed.relations.isEmpty)
        XCTAssertFalse(removed.nodes.contains { $0.id == "plain" })
        XCTAssertEqual(removed.nodes.first { $0.id == "mixed" }?.targetID, "note")
        XCTAssertFalse(removed.documents[0].linkedIDs.contains("person"))
        let restarted = LibraryRepository(rootURL: f.library)
        let loaded = try await latest(restarted)
        XCTAssertEqual(loaded.manualTrash?.items.last?.id, item.id)
        let recovered = try await restore(loaded, itemID: item.id, repository: restarted)
        XCTAssertEqual(recovered.entities.first { $0.id == "person" }, f.book.entities.first { $0.id == "person" })
        XCTAssertEqual(recovered.events, f.book.events)
        XCTAssertEqual(recovered.relations, f.book.relations)
        XCTAssertEqual(Set(recovered.nodes), Set(f.book.nodes))
        XCTAssertEqual(Set(recovered.edges), Set(f.book.edges))
        XCTAssertEqual(recovered.graphGroups, f.book.graphGroups)
        XCTAssertEqual(recovered.documents[0].linkedIDs, f.book.documents[0].linkedIDs)
        let body = try await restarted.readDocument(bookID: recovered.id, document: recovered.documents[0])
        XCTAssertEqual(body, f.markdown)
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("source/book.txt")), try Data(contentsOf: f.source))
    }

    func testStaleSaveAndEditorCannotReviveDeletedRecordsOrOverwriteBody() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let removed = try await f.repository.trashManualItem(project: f.book, kind: .entity, id: "person")
        let metadata = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        do { try await f.repository.save(f.book); XCTFail("旧窗口不能复活刚删除的对象。") } catch {}
        do {
            _ = try await f.repository.saveDocument(project: f.book, document: f.document, markdown: "不应写入的旧窗口草稿",
                                                     expectedContentHash: try BookImporter.sha256(Data(f.markdown.utf8)))
            XCTFail("旧编辑器必须重新载入最新回收状态。")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("project.json")), metadata)
        let body = try await f.repository.readDocument(bookID: removed.id, document: removed.documents[0])
        XCTAssertEqual(body, f.markdown)
        let item = try XCTUnwrap(removed.manualTrash?.items.last)
        let restored = try await restore(removed, itemID: item.id, repository: f.repository)
        do { try await f.repository.save(removed); XCTFail("恢复后旧回收窗口也不能再次抹掉该对象。") } catch {}
        let loaded = try await latest(f.repository)
        XCTAssertEqual(loaded.entities, restored.entities)
    }

    func testManualAPIsRequireCurrentRevisionBeforeDeletionOrRestoration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var newer = f.book
        newer.entities[0].summary = "用户刚补充的内容"
        try await f.repository.save(newer)
        do { _ = try await f.repository.trashManualItem(project: f.book, kind: .entity, id: "person"); XCTFail("不能把旧窗口对象内容作为回收快照。") } catch {}
        let removed = try await f.repository.trashManualItem(project: newer, kind: .entity, id: "person")
        let item = try XCTUnwrap(removed.manualTrash?.items.last)
        var edited = removed; edited.title = "回收后用户更新的书名"
        try await f.repository.save(edited)
        let metadata = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        let plan = try ManualTrashRuntime.restorePlan(in: removed, itemID: item.id)
        do { _ = try await f.repository.restoreManualItems(project: removed, itemID: item.id, expectedItemIDs: plan.itemIDs); XCTFail("旧预览不能覆盖后来的元数据。") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("project.json")), metadata)
        let restored = try await restore(edited, itemID: item.id, repository: f.repository)
        XCTAssertEqual(restored.title, edited.title)
        XCTAssertEqual(restored.entities.first { $0.id == "person" }?.summary, "用户刚补充的内容")
    }

    func testRestoreConflictIsAtomicAndKeepsLaterNodeAndRecoveryRecord() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var removed = try await f.repository.trashManualItem(project: f.book, kind: .entity, id: "person")
        let item = try XCTUnwrap(removed.manualTrash?.items.last)
        let index = try XCTUnwrap(removed.nodes.firstIndex { $0.id == "mixed" })
        removed.nodes[index].title = "删除后用户自己修改的节点"
        removed.nodes[index].x = 888
        removed.nodes[index].targetID = "event"
        try await f.repository.save(removed)
        let metadata = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        do { _ = try await f.repository.restoreManualItems(project: removed, itemID: item.id, expectedItemIDs: [item.id]); XCTFail("恢复不能覆盖后来修改的依赖记录。") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("project.json")), metadata)
        let loaded = try await latest(f.repository)
        XCTAssertFalse(loaded.entities.contains { $0.id == "person" })
        XCTAssertEqual(loaded.nodes.first { $0.id == "mixed" }?.title, "删除后用户自己修改的节点")
        XCTAssertTrue(loaded.manualTrash?.items.contains { $0.id == item.id } == true)
        let body = try await f.repository.readDocument(bookID: removed.id, document: removed.documents[0])
        XCTAssertEqual(body, f.markdown)
    }

    func testReservedDeletedIDCannotBeRecreatedBySaveDocumentOrControlledWrites() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let removed = try await f.repository.trashManualItem(project: f.book, kind: .entity, id: "person")
        let metadata = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        var recreated = removed; recreated.entities.append(try XCTUnwrap(f.book.entities.first { $0.id == "person" }))
        do { try await f.repository.save(recreated); XCTFail("普通保存不能把保留ID作为新实体重建。") } catch {}
        recreated = removed; recreated.events.append(KnowledgeEvent(id: "person", name: "占用原实体ID的事件"))
        do { try await f.repository.save(recreated); XCTFail("保留知识ID也不能跨实体/事件类型占用。") } catch {}
        do {
            _ = try await f.repository.saveDocument(project: removed, document: DocumentRecord(id: "person", title: "占用原实体ID的笔记"), markdown: "新正文")
            XCTFail("新增笔记不能占用待恢复实体ID。")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.package.appendingPathComponent("docs/person.md").path))
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("project.json")), metadata)
        let grant = try await f.repository.issueChangeGrant(bookID: removed.id, permissions: [.graph], allowedUnitIDs: [], requiresReceipts: false, reason: "回收前审阅的任务")
        let proposal = try await f.repository.prepareChanges(ControlledChangeBatch(graph: ControlledGraphChanges(createNodes: [ControlledNodeCreation(clientID: "new-node", title: "节点")])), grant: grant)
        let item = try XCTUnwrap(removed.manualTrash?.items.last)
        _ = try await restore(removed, itemID: item.id, repository: f.repository)
        do { _ = try await f.repository.commitChanges(proposalID: proposal.id, grant: grant); XCTFail("恢复后旧AI提案的CAS必须失效。") } catch {}
    }

    func testExportImportPreservesRecoveryAndAllowsRestoreInTheCopy() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let removed = try await f.repository.trashManualItem(project: f.book, kind: .entity, id: "person")
        let item = try XCTUnwrap(removed.manualTrash?.items.last)
        let package = f.directory.appendingPathComponent("with-trash.readingbook", isDirectory: true)
        try await f.repository.exportProject(removed, to: package)
        let imported = try await f.repository.importProject(from: package)
        XCTAssertNotEqual(imported.id, removed.id)
        XCTAssertEqual(imported.manualTrash?.items.last?.id, item.id)
        let restored = try await restore(imported, itemID: item.id, repository: f.repository)
        XCTAssertTrue(restored.entities.contains { $0.id == "person" })
        let body = try await f.repository.readDocument(bookID: restored.id, document: restored.documents[0])
        XCTAssertEqual(body, f.markdown)
        let all = try await f.repository.loadAll()
        XCTAssertFalse(try XCTUnwrap(all.first { $0.id == removed.id }).entities.contains { $0.id == "person" }, "恢复副本不会恢复原书。")
    }

    func testViewBatchAndPhysicalNodeTrashKeepUnderlyingKnowledgeAndNotes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let viewsRemoved = try await f.repository.trashManualItem(project: f.book, kind: .view, id: "map-view", viewIDs: ["map-view", "timeline-view"])
        XCTAssertTrue(viewsRemoved.views.isEmpty)
        XCTAssertEqual(viewsRemoved.entities, f.book.entities)
        let viewItem = try XCTUnwrap(viewsRemoved.manualTrash?.items.last)
        let restoredViews = try await restore(viewsRemoved, itemID: viewItem.id, repository: f.repository)
        XCTAssertEqual(Set(restoredViews.views), Set(f.book.views))
        let nodeRemoved = try await f.repository.trashManualItem(project: restoredViews, kind: .node, id: "mixed")
        XCTAssertFalse(nodeRemoved.nodes.contains { $0.id == "mixed" })
        XCTAssertEqual(nodeRemoved.documents, restoredViews.documents)
        XCTAssertEqual(nodeRemoved.entities, restoredViews.entities)
        let body = try await f.repository.readDocument(bookID: nodeRemoved.id, document: nodeRemoved.documents[0])
        XCTAssertEqual(body, f.markdown)
        let nodeItem = try XCTUnwrap(nodeRemoved.manualTrash?.items.last)
        let restoredNode = try await restore(nodeRemoved, itemID: nodeItem.id, repository: f.repository)
        XCTAssertEqual(Set(restoredNode.nodes), Set(restoredViews.nodes))
        XCTAssertEqual(Set(restoredNode.edges), Set(restoredViews.edges))
    }

    func testOldDocumentJournalCannotRollBackNewManualTrashState() async throws {
        struct Journal: Codable {
            var version = 1; var bookID: String; var documentID: String
            var markdownHash: String; var previousMarkdownHash: String?; var project: BookProject
        }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.repository.trashManualItem(project: f.book, kind: .entity, id: "person")
        let metadata = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        let journalFolder = f.package.appendingPathComponent(".journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: true)
        let pending = Data("旧窗口中断的正文写入".utf8)
        try pending.write(to: journalFolder.appendingPathComponent("document.md"))
        let journal = Journal(bookID: f.book.id, documentID: f.document.id, markdownHash: try BookImporter.sha256(pending),
                              previousMarkdownHash: try BookImporter.sha256(Data(f.markdown.utf8)), project: f.book)
        try JSONEncoder().encode(journal).write(to: journalFolder.appendingPathComponent("transaction.json"))
        let restarted = LibraryRepository(rootURL: f.library), report = try await restarted.loadReport()
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("project.json")), metadata)
        XCTAssertEqual(try String(contentsOf: f.package.appendingPathComponent(f.document.relativePath), encoding: .utf8), f.markdown)
        XCTAssertEqual(try Data(contentsOf: journalFolder.appendingPathComponent("document.md")), pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalFolder.appendingPathComponent("transaction.json").path))
    }
}
