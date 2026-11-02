import AppKit
import Foundation
import Darwin
@testable import ReadingBook
@testable import ReadingCore

/// Executes the product's captured folder intents and real repository writes.
/// Native popover input/selection races are verified separately through CUA.
@main struct FolderIdentityProbe {
    @MainActor static func main() async {
        var result: [String: Any] = ["status": "failed", "realNetworkRequests": 0]
        var output: URL?
        do {
            guard CommandLine.arguments.count == 3 else { throw ReadingError.invalid("Expected workspace and fresh output directory") }
            let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
            let out = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
                  out.pathComponents.starts(with: root.appendingPathComponent("logs").pathComponents),
                  Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("Workspace-only isolated probe required") }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            output = out
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1": out.appendingPathComponent("library").path,
                "service-profiles": Data("[]".utf8)], forName: UserDefaults.argumentDomain)
            result.merge(try await run(in: out)) { _, value in value }
            result["status"] = "passed"
        } catch { result["error"] = String(describing: error) }
        if let output { try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json")) }
        print(String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
        exit(result["status"] as? String == "passed" ? 0 : 1)
    }

    @MainActor private static func run(in out: URL) async throws -> [String: Any] {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) throws {
            checks[name] = value
            guard value else { throw ReadingError.invalid("Folder identity check failed: " + name) }
        }
        func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let source = out.appendingPathComponent("fixture.txt"), sourceBytes = Data("仅合成原文，笔记与问答不能被分类操作改写。".utf8)
        try sourceBytes.write(to: source)
        let store = AppStore(), repository = store.repository
        var project = BookProject(title: "文件夹身份合成书", originalName: "fixture.txt", sourceHash: try BookImporter.sha256(sourceBytes),
            units: [.init(id: "u1", order: 0, chapter: "合成章节", text: "仅合成原文")])
        project.chats = [.init(id: "q1", role: "user", content: "完整问题"), .init(id: "a1", role: "assistant", content: "完整回答")]
        var collections = ReaderCollectionState()
        collections.folders = [.init(id: "f0", kind: .notes, title: "原目标"), .init(id: "f1", kind: .notes, title: "后来选中的分类"),
            .init(id: "child", kind: .notes, title: "原子分类", parentID: "f0"), .init(id: "history", kind: .history, title: "历史对话")]
        project.readerCollections = collections
        project = try await repository.create(project, sourceURL: source)
        project = try await repository.saveDocument(project: project, document: .init(id: "n1", title: "用户笔记"), markdown: "完整笔记正文，**格式与链接**保留。")
        project = try await repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: .move(.notes, ["note:n1"], "f0"))
        var second = BookProject(title: "另一本合成书", originalName: "fixture.txt", sourceHash: project.sourceHash, units: project.units)
        second.readerCollections = collections
        second = try await repository.create(second, sourceURL: source)
        store.books = [project, second]; store.bookID = project.id
        let originalDocuments = try encoder.encode(project.documents), originalChats = try encoder.encode(project.chats)
        let originalBody = try await repository.readDocument(bookID: project.id, document: project.documents[0])

        let rename = ReaderFolderNamingIntent.rename(id: "f0")
        let renamed = try ReaderCollectionRuntime.apply(rename.command(title: "保存原目标", kind: .notes, folders: collections.folders), in: project)
        try check("renameKeepsOriginalTarget", renamed.folders.first(where: { $0.id == "f0" })?.title == "保存原目标")
        try check("renameDoesNotFollowChangedSelection", renamed.folders.first(where: { $0.id == "f1" })?.title == "后来选中的分类")
        var deleted = project; deleted.readerCollections = try ReaderCollectionRuntime.apply(.removeFolder("f0"), in: project)
        let deletedBytes = try encoder.encode(deleted)
        try check("deletedRenameTargetRejected", rejects { _ = try rename.command(title: "不能意外新建", kind: .notes, folders: deleted.readerCollections!.folders) })
        try check("rejectedRenameLeavesProjectBytes", try encoder.encode(deleted) == deletedBytes)
        try check("renameWrongKindRejected", rejects { _ = try ReaderFolderNamingIntent.rename(id: "history").command(title: "错误类型", kind: .notes, folders: collections.folders) })
        let create = ReaderFolderNamingIntent.create(parentID: "f0")
        let child = try ReaderCollectionRuntime.apply(create.command(title: "固定上级", kind: .notes, folders: collections.folders), in: project)
        try check("newChildKeepsCapturedParent", child.folders.first(where: { $0.title == "固定上级" })?.parentID == "f0")
        let root = try ReaderCollectionRuntime.apply(ReaderFolderNamingIntent.create(parentID: nil).command(title: "根分类", kind: .notes, folders: collections.folders), in: project)
        let rootFolder = root.folders.first(where: { $0.title == "根分类" })
        try check("newRootDoesNotFollowLaterSelection", rootFolder != nil && rootFolder?.parentID == nil)
        try check("deletedCreateParentRejected", rejects { _ = try create.command(title: "不能退回根分类", kind: .notes, folders: deleted.readerCollections!.folders) })
        try check("wrongKindCreateParentRejected", rejects { _ = try ReaderFolderNamingIntent.create(parentID: "history").command(title: "错误上级", kind: .notes, folders: collections.folders) })

        let removal = ReaderFolderRemovalIntent(folderID: "f0")
        let removalState = try ReaderCollectionRuntime.apply(removal.command(kind: .notes, folders: collections.folders), in: project)
        try check("removalKeepsOriginalTarget", !removalState.folders.contains(where: { $0.id == "f0" }))
        try check("removalDoesNotFollowChangedSelection", removalState.folders.first(where: { $0.id == "f1" })?.title == "后来选中的分类")
        try check("deletedRemovalTargetRejected", rejects { _ = try removal.command(kind: .notes, folders: deleted.readerCollections!.folders) })
        try check("wrongKindRemovalTargetRejected", rejects { _ = try ReaderFolderRemovalIntent(folderID: "history").command(kind: .notes, folders: collections.folders) })

        let preparedRename = try rename.command(title: "过期重命名", kind: .notes, folders: collections.folders)
        let preparedCreate = try create.command(title: "过期新建", kind: .notes, folders: collections.folders)
        let preparedRemoval = try removal.command(kind: .notes, folders: collections.folders)
        let saved = try await repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: rename.command(title: "持久保存原目标", kind: .notes, folders: collections.folders))
        try check("repositoryRenamesCapturedIdentity", saved.readerCollections?.folders.first(where: { $0.id == "f0" })?.title == "持久保存原目标")
        let removed = try await repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: .removeFolder("f0"))
        var rejectedRename = false, rejectedCreate = false, rejectedRemoval = false
        do { _ = try await repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: preparedRename) } catch { rejectedRename = true }
        do { _ = try await repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: preparedCreate) } catch { rejectedCreate = true }
        do { _ = try await repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: preparedRemoval) } catch { rejectedRemoval = true }
        try check("canonicalWriterRejectsRenameDeletedAfterPreparation", rejectedRename)
        try check("canonicalWriterRejectsParentDeletedAfterPreparation", rejectedCreate)
        try check("canonicalWriterRejectsRemovalDeletedAfterPreparation", rejectedRemoval)
        let current = try await repository.loadAll().first(where: { $0.id == project.id })!
        try check("lateCommandsDoNotCreateOrRetargetFolders", current.readerCollections == removed.readerCollections)
        let promotedChild = current.readerCollections?.folders.first(where: { $0.id == "child" })
        try check("folderRemovalPromotesChildAndUnfilesOnly", promotedChild != nil && promotedChild?.parentID == nil && current.readerCollections?.assignments["note:n1"] == nil)
        try check("originalDocumentMetadataUnchanged", try encoder.encode(current.documents) == originalDocuments)
        try check("originalNoteBodyUnchanged", try await repository.readDocument(bookID: current.id, document: current.documents[0]) == originalBody)
        try check("originalChatsUnchanged", try encoder.encode(current.chats) == originalChats)
        try check("originalSourceBytesUnchanged", try Data(contentsOf: await repository.sourceURL(for: current)) == sourceBytes)

        store.publish(current)
        let oldOwner = WorkspacePickerOwner(store: store)
        store.bookID = second.id
        await store.organizeReaderCollections(.renameFolder("f1", "不能修改另一书"), owner: oldOwner)
        let afterBookSwitch = try await repository.loadAll().first(where: { $0.id == second.id })!
        try check("lateBookOwnerDoesNotWrite", afterBookSwitch.readerCollections == second.readerCollections && !oldOwner.matches(store))
        store.bookID = current.id
        let sourceOwner = WorkspacePickerOwner(store: store), index = store.books.firstIndex(where: { $0.id == current.id })!
        store.books[index].sourceHash = String(repeating: "b", count: 64)
        await store.organizeReaderCollections(.renameFolder("f1", "不能修改另一版本"), owner: sourceOwner)
        let afterSourceSwitch = try await repository.loadAll().first(where: { $0.id == current.id })!
        try check("lateSourceOwnerDoesNotWrite", afterSourceSwitch.readerCollections == current.readerCollections && !sourceOwner.matches(store))
        store.books[index] = current
        let libraryOwner = WorkspacePickerOwner(store: store)
        let alternateRepository = LibraryRepository(rootURL: out.appendingPathComponent("other-library"))
        var alternate = second; alternate = try await alternateRepository.create(alternate, sourceURL: source)
        store.repository = alternateRepository; store.libraryRootURL = out.appendingPathComponent("other-library"); store.books = [alternate]; store.bookID = alternate.id
        await store.organizeReaderCollections(.renameFolder("f1", "不能修改另一库"), owner: libraryOwner)
        let afterLibrarySwitch = try await alternateRepository.loadAll().first!
        try check("lateLibraryOwnerDoesNotWrite", afterLibrarySwitch.readerCollections == alternate.readerCollections && !libraryOwner.matches(store))
        return ["checkCount": checks.count, "checks": checks, "originalNotesChatsAndSourcePreserved": true,
                "scope": "Actual product naming-intent code and isolated canonical repositories; native popover races are separate CUA evidence."]
    }
}
