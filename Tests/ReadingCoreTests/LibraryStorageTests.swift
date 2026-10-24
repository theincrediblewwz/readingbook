import Foundation
import XCTest
@testable import ReadingCore

final class LibraryStorageTests: XCTestCase {
    private struct Fixture {
        let temporary: URL
        let root: URL
        let original: URL
        let repository: LibraryRepository
        var book: BookProject
        let note: DocumentRecord
        var directory: URL { root.appendingPathComponent("books/" + book.id) }
    }
    private func fixture() async throws -> Fixture {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Storage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let original = temporary.appendingPathComponent("原书.txt"), text = "208年，曹操到江陵。其后与刘备交战。\n"
        try Data(text.utf8).write(to: original)
        var book = BookProject(title: "三国阅读", originalName: original.lastPathComponent,
                               sourceHash: try BookImporter.sha256(Data(text.utf8)),
                               units: [SourceUnit(id: "unit", order: 0, chapter: "第一章", page: 1, text: text)])
        PluginEngine.seed(&book)
        let evidence = [Evidence(unitID: "unit", quote: "208年，曹操到江陵。")]
        book.entities = [KnowledgeEntity(id: "person", typeID: "person", name: "曹操", evidence: evidence)]
        book.events = [KnowledgeEvent(id: "event", name: "至江陵", startYear: 208, participantIDs: ["person"], evidence: evidence)]
        book.relations = [KnowledgeRelation(id: "relation", fromID: "person", toID: "event", label: "参与", evidence: evidence)]
        book.chats = [ChatMessage(role: "assistant", content: "先核对事件的原文证据。", evidence: evidence)]
        let root = temporary.appendingPathComponent("library"), repository = LibraryRepository(rootURL: root)
        try await repository.create(book, sourceURL: original)
        let note = DocumentRecord(id: "note", title: "我的笔记", linkedIDs: ["person", "event"], evidence: evidence)
        book = try await repository.saveDocument(project: book, document: note, markdown: "# 我的笔记\n\n用户写下的 $x^2$。\n")
        var node = CanvasNode(id: "node", targetID: "person", x: 20, y: 40)
        node.documentIDs = [note.id]; book.nodes = [node]
        try await repository.save(book)
        _ = try await repository.refreshReadableViews(id: book.id)
        return Fixture(temporary: temporary, root: root, original: original, repository: repository, book: book, note: note)
    }

    func testLibraryOnlyRemovalRetainsFilesAndAllAssociations() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        let metadata = f.directory.appendingPathComponent("project.json"), note = f.directory.appendingPathComponent(f.note.relativePath)
        let before = try Data(contentsOf: metadata), noteBefore = try Data(contentsOf: note), original = try Data(contentsOf: f.original)
        try await f.repository.removeBookFromLibrary(project: f.book)
        let visible = try await f.repository.loadAll(), removed = try await f.repository.removedBooksReport()
        XCTAssertTrue(visible.isEmpty); XCTAssertEqual(removed.projects.map(\.id), [f.book.id])
        XCTAssertEqual(try Data(contentsOf: metadata), before); XCTAssertEqual(try Data(contentsOf: note), noteBefore)
        XCTAssertEqual(try Data(contentsOf: f.original), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.path))
        let restored = try await f.repository.rejoinBook(id: f.book.id), reloaded = try await f.repository.loadAll()
        XCTAssertEqual(reloaded.map(\.id), [f.book.id]); XCTAssertEqual(restored.nodes, f.book.nodes)
        XCTAssertEqual(restored.relations, f.book.relations); XCTAssertEqual(restored.documents, f.book.documents)
        XCTAssertEqual(restored.events, f.book.events)
        try await f.repository.removeBookFromLibrary(project: restored)
        try await f.repository.archiveBook(project: restored)
        let moved = try await f.repository.removedBooksReport()
        XCTAssertTrue(moved.projects.isEmpty); XCTAssertTrue(moved.issues.isEmpty)
        _ = try await f.repository.exportLibraryBackup(to: f.temporary.appendingPathComponent("hidden-archived.readingbookbackup"))
        _ = try await f.repository.restoreBook(id: f.book.id)
        let restoredAgain = try await f.repository.loadAll()
        XCTAssertEqual(restoredAgain.map(\.id), [f.book.id])
    }

    func testPreparedLocalRemovalRejectsTamperingAndLinks() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        let prepared = try await f.repository.prepareLocalBookRemoval(id: f.book.id)
        XCTAssertEqual(prepared.directoryURL.path, f.directory.resolvingSymlinksInPath().path); XCTAssertGreaterThan(prepared.bytes, 0)
        XCTAssertEqual(prepared.sourceURL.path, f.directory.appendingPathComponent("source/" + f.book.originalName).resolvingSymlinksInPath().path)
        do { _ = try await f.repository.prepareLocalBookRemoval(id: "../original"); XCTFail("应拒绝非UUID") } catch { }
        let source = f.directory.appendingPathComponent("source/" + f.book.originalName)
        let sourceData = try Data(contentsOf: source)
        try Data("被改过的副本".utf8).write(to: source, options: .atomic)
        do { _ = try await f.repository.prepareLocalBookRemoval(id: f.book.id); XCTFail("应拒绝被改原书") } catch { }
        try sourceData.write(to: source, options: .atomic)
        let link = f.directory.appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.original)
        do { _ = try await f.repository.prepareLocalBookRemoval(id: f.book.id); XCTFail("应拒绝目录内符号链接") } catch { }
        XCTAssertEqual(try Data(contentsOf: f.original), sourceData)
    }

    private final class ScheduledReadableRefresh: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var task: Task<Bool, Never>?
        func schedule(repository: LibraryRepository, id: String) {
            let pending = Task.detached { [started] in
                started.signal()
                do { _ = try await repository.refreshReadableViews(id: id); return true }
                catch { return false }
            }
            lock.lock(); task = pending; lock.unlock()
        }
        func pending() -> Task<Bool, Never>? {
            lock.lock(); defer { lock.unlock() }
            return task
        }
    }

    func testLocalMoveSerializesReadableRefreshAndKeepsRestorableAssociations() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        let repository = f.repository, id = f.book.id, refresh = ScheduledReadableRefresh()
        let destination = f.temporary.appendingPathComponent("recoverable-local-copy")
        let original = try Data(contentsOf: f.original)
        let metadata = try Data(contentsOf: f.directory.appendingPathComponent("project.json"))
        let note = try Data(contentsOf: f.directory.appendingPathComponent(f.note.relativePath))
        try await repository.removeBookFromLibrary(project: f.book)
        let moved = try await repository.moveLocalBook(id: id) { source in
            refresh.schedule(repository: repository, id: id)
            guard refresh.started.wait(timeout: .now() + 5) == .success else {
                throw ReadingError.invalid("后台刷新测试任务未启动。")
            }
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        XCTAssertEqual(moved, destination)
        let pending = try XCTUnwrap(refresh.pending())
        let refreshed = await pending.value
        XCTAssertFalse(refreshed, "排队的导览刷新应在项目移走后停止")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path), "不能重建缺少项目真源的残目录")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("project.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(f.note.relativePath)), note)
        XCTAssertEqual(try Data(contentsOf: f.original), original)
        let removed = try await repository.removedBooksReport()
        XCTAssertTrue(removed.projects.isEmpty); XCTAssertTrue(removed.issues.isEmpty)
        try FileManager.default.moveItem(at: destination, to: f.directory)
        let restoredBooks = try await repository.loadAll()
        let restored = try XCTUnwrap(restoredBooks.first)
        XCTAssertEqual(restored.documents, f.book.documents); XCTAssertEqual(restored.nodes, f.book.nodes)
        XCTAssertEqual(restored.entities, f.book.entities); XCTAssertEqual(restored.events, f.book.events)
        XCTAssertEqual(restored.relations, f.book.relations)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent(f.note.relativePath)), note)
    }

    func testWholeBackupAndMigrationPreserveHiddenTrashSidecarsAndIDs() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        var archived = f.book; archived.id = UUID().uuidString; archived.documents = []; archived.nodes = []
        try await f.repository.create(archived, sourceURL: f.original)
        try await f.repository.archiveBook(project: archived)
        try await f.repository.removeBookFromLibrary(project: f.book)
        for folder in ["ConversationMemory", "Workspace", "ModelCatalog"] {
            let path = f.root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("{\"value\":\"\(folder)\"}".utf8).write(to: path.appendingPathComponent("sample.json"))
        }
        let outsideSecret = f.temporary.appendingPathComponent("not-a-library-key.txt")
        try Data("outside-secret".utf8).write(to: outsideSecret)
        let backup = f.temporary.appendingPathComponent("全库.readingbookbackup")
        let result = try await f.repository.exportLibraryBackup(to: backup)
        XCTAssertEqual(result.rootURL, backup); XCTAssertGreaterThan(result.files, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("library/not-a-library-key.txt").path))
        let restoredRoot = f.temporary.appendingPathComponent("restored")
        _ = try await f.repository.restoreLibraryBackup(from: backup, to: restoredRoot)
        let restored = LibraryRepository(rootURL: restoredRoot)
        let visible = try await restored.loadAll(), removed = try await restored.removedBooksReport(), trash = try await restored.archivedBooks()
        XCTAssertTrue(visible.isEmpty); XCTAssertEqual(removed.projects.map(\.id), [f.book.id]); XCTAssertEqual(trash.map(\.id), [archived.id])
        let rejoined = try await restored.rejoinBook(id: f.book.id)
        XCTAssertEqual(rejoined.nodes, f.book.nodes); XCTAssertEqual(rejoined.relations, f.book.relations)
        let actualNote = try await restored.readDocument(bookID: f.book.id, document: f.note)
        XCTAssertEqual(actualNote, "# 我的笔记\n\n用户写下的 $x^2$。\n")
        for folder in ["ConversationMemory", "Workspace", "ModelCatalog"] {
            XCTAssertEqual(try Data(contentsOf: restoredRoot.appendingPathComponent(folder + "/sample.json")),
                           try Data(contentsOf: f.root.appendingPathComponent(folder + "/sample.json")))
        }
        let copyRoot = f.temporary.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: false)
        let copied = try await f.repository.copyLibrary(to: copyRoot)
        XCTAssertGreaterThan(copied.bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.path), "迁移复制不能删除旧库")
        XCTAssertEqual(try Data(contentsOf: copyRoot.appendingPathComponent("books/" + f.book.id + "/project.json")), try Data(contentsOf: f.directory.appendingPathComponent("project.json")))
    }

    func testBackupTamperAndTargetConflictNeverReplaceExistingFiles() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        let backup = f.temporary.appendingPathComponent("original.readingbookbackup")
        _ = try await f.repository.exportLibraryBackup(to: backup)
        let existing = f.temporary.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let keep = existing.appendingPathComponent("keep.md"); try Data("keep".utf8).write(to: keep)
        do { _ = try await f.repository.copyLibrary(to: existing); XCTFail("应拒绝非空目录") } catch { }
        do { _ = try await f.repository.copyLibrary(to: f.root.appendingPathComponent("nested")); XCTFail("应拒绝源内目标") } catch { }
        let manifest = backup.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var entries = try XCTUnwrap(object["files"] as? [[String: Any]])
        entries[0]["path"] = "../../escape"; object["files"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: manifest, options: .atomic)
        let target = f.temporary.appendingPathComponent("refused")
        do { _ = try await f.repository.restoreLibraryBackup(from: backup, to: target); XCTFail("应拒绝伪造清单") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "keep")
    }

    func testReadableViewsPreserveHandEditsAndDoNotCopyCanonicalBodies() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        let guide = f.directory.appendingPathComponent("阅读导航.md"), analysis = f.directory.appendingPathComponent("AI分析/问答.md")
        let metadata = try Data(contentsOf: f.directory.appendingPathComponent("project.json"))
        let note = try Data(contentsOf: f.directory.appendingPathComponent(f.note.relativePath))
        let firstAnalysis = try String(contentsOf: analysis, encoding: .utf8)
        XCTAssertTrue(firstAnalysis.contains("先核对事件"))
        let manual = "# 用户在这里的补充，不能覆盖\n"
        try Data(manual.utf8).write(to: guide, options: .atomic)
        let generated = try await f.repository.refreshReadableViews(id: f.book.id)
        XCTAssertNotEqual(generated.lastPathComponent, guide.lastPathComponent); XCTAssertEqual(try String(contentsOf: guide, encoding: .utf8), manual)
        var changed = f.book; changed.chats.append(ChatMessage(role: "user", content: "后来提出的新问题"))
        try await f.repository.save(changed)
        _ = try await f.repository.refreshReadableViews(id: changed.id)
        XCTAssertTrue(try String(contentsOf: analysis, encoding: .utf8).contains("后来提出的新问题"))
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent(f.note.relativePath)), note)
        XCTAssertNotEqual(try Data(contentsOf: f.directory.appendingPathComponent("project.json")), metadata)
        let readable = f.temporary.appendingPathComponent("readable")
        _ = try await f.repository.exportReadableLibrary(to: readable)
        let contents = try FileManager.default.subpathsOfDirectory(atPath: readable.path)
        XCTAssertFalse(contents.contains { $0.contains("/source/") || $0.contains("/docs/") })
        XCTAssertTrue(contents.contains("书库目录.md"))
        let single = f.temporary.appendingPathComponent("单书.readingbook")
        try await f.repository.exportProject(changed, to: single)
        let imported = try await f.repository.importProject(from: single)
        XCTAssertNotEqual(imported.id, f.book.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("books/" + imported.id + "/阅读导航.md").path))
    }

    func testUnknownRootFileAndSymlinkCopyFailWithoutLosingSource() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        let unknown = f.root.appendingPathComponent("手动放进来的材料.txt")
        try Data("需要用户核对".utf8).write(to: unknown)
        let target = f.temporary.appendingPathComponent("unknown-copy")
        do { _ = try await f.repository.copyLibrary(to: target); XCTFail("不能静默遗漏未知文件") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.removeItem(at: unknown)
        let link = f.root.appendingPathComponent("Workspace")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.temporary)
        do { _ = try await f.repository.copyLibrary(to: target); XCTFail("不能跟随符号链接") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: f.original.path))
    }

    private final class ProgressMutation: @unchecked Sendable {
        let lock = NSLock(); var done = false
        let file: URL
        init(file: URL) { self.file = file }
        func update(_ progress: LibraryTransferProgress) {
            lock.lock(); defer { lock.unlock() }
            if !done, progress.stage == "复制" { done = true; try? Data("{\"v\":2}".utf8).write(to: file, options: .atomic) }
        }
    }

    func testConcurrentSourceChangePreventsMigrationCommit() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        let memory = f.root.appendingPathComponent("ConversationMemory")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: false)
        let file = memory.appendingPathComponent("memory.json"); try Data("{\"v\":1}".utf8).write(to: file)
        let mutation = ProgressMutation(file: file), target = f.temporary.appendingPathComponent("changing-copy")
        do { _ = try await f.repository.copyLibrary(to: target, progress: { mutation.update($0) }); XCTFail("复制期间发生更改必须停止提交") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("project.json").path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"v\":2}")
    }
}
