import SwiftUI
import ReadingCore

struct WorkspaceDeletion {
    enum Kind: Equatable { case book, bookLocal, document, entity, event }
    var kind: Kind
    var id: String
    var title: String
    var bookID: String?
    var bytes: Int64? = nil
    var libraryRoot: URL? = nil
    var sourceHash: String? = nil
    var confirmationTitle: String { kind == .book ? "从书库移除？" : kind == .bookLocal ? "删除本机项目副本？" : "移入回收站？" }
    var actionTitle: String { kind == .book ? "移出书库，保留文件" : kind == .bookLocal ? "移到系统废纸篓" : "移入回收站" }
    var detail: String {
        switch kind {
        case .book: return "只移除书库入口。原书副本、笔记和分析保留，可重新加入。"
        case .bookLocal: return "包含 App 管理的原书副本、笔记、分析与关联。" + (bytes.map { "本地内容 " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + "。" } ?? "") + "导入前的原文件不动；可从系统废纸篓放回。"
        case .document: return "Markdown 将移入回收站，画布和知识库暂时隐藏它；恢复后保留原内容与节点。聊天记录保留。"
        case .entity, .event: return "对象与受影响的结构化关联将一起移入回收站，暂时从地图、时间轴和导图隐藏。恢复时会核对关联；原书与 Markdown 正文保留。"
        }
    }
}

extension AppStore {
    func requestDeletion(_ kind: WorkspaceDeletion.Kind, id: String, title: String) {
        guard !isBusy else { return }
        guard pendingAIChanges.isEmpty else { errorMessage = "请先处理待审阅修改。"; return }
        guard !editorDirty else { errorMessage = "请先保存正在编辑的 Markdown，再移入回收站。"; return }
        let root = libraryRootURL
        let expectedHash = books.first(where: { $0.id == (kind == .book || kind == .bookLocal ? id : bookID) })?.sourceHash
        if kind == .bookLocal {
            let owner = repository
            isBusy = true; activity = "核对本机项目副本…"
            task = Task {
                defer { isBusy = false }
                do {
                    let info = try await owner.storageBook(id: id)
                    guard libraryRootURL == root else { return }
                    deletionRequest = WorkspaceDeletion(kind: kind, id: id, title: title, bookID: bookID, bytes: info.bytes, libraryRoot: root, sourceHash: expectedHash)
                } catch { errorMessage = error.localizedDescription }
            }
            return
        }
        deletionRequest = WorkspaceDeletion(kind: kind, id: id, title: title, bookID: bookID, libraryRoot: root, sourceHash: expectedHash)
    }
    func confirmDeletion(_ request: WorkspaceDeletion) {
        guard !isBusy else { return }
        deletionRequest = nil
        guard request.libraryRoot == nil || request.libraryRoot == libraryRootURL else { errorMessage = "书库位置已改变，请重新选择要移除的内容。"; return }
        guard !editorDirty else { errorMessage = "请先保存正在编辑的 Markdown，再移入回收站。"; return }
        guard pendingAIChanges.isEmpty else { errorMessage = "请先处理待审阅修改。"; return }
        isBusy = true
        task = Task {
            defer { isBusy = false }
            do {
                if request.kind == .book || request.kind == .bookLocal {
                    guard let project = books.first(where: { $0.id == request.id }) else { return }
                    guard request.sourceHash == nil || request.sourceHash == project.sourceHash else { throw ReadingError.invalid("原书已变化，请重新确认。") }
                    if request.kind == .book {
                        try await repository.removeBookFromLibrary(project: project)
                    } else {
                        lastTrashedProjectURL = try await repository.moveLocalBook(id: project.id) { url in
                            var result: NSURL?
                            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                            return result as URL?
                        }
                    }
                    books.removeAll { $0.id == project.id }
                    _ = try? await repository.refreshReadableLibraryIndex()
                    storageState.overview = nil
                    pdfSessionPasswords.removeValue(forKey: project.id); pdfUnlockedBookIDs.remove(project.id)
                    if bookID == project.id { bookID = nil; selectedUnitID = nil; selectedObjectID = nil; selectedDocumentID = nil; sourceFileURL = nil; editorMarkdown = ""; editorTitle = ""; draftEvidence = []; route = "library" }
                    activity = request.kind == .book ? "已移出书库，文件保留。" : "本机项目已移到系统废纸篓；导入前原文件未动。"
                } else if let project = books.first(where: { $0.id == request.bookID }) {
                    let updated: BookProject
                    switch request.kind {
                    case .document: updated = try await repository.setDocumentTrashed(project: project, documentID: request.id, trashed: true)
                    case .entity: updated = try await repository.trashManualItem(project: project, kind: .entity, id: request.id)
                    case .event: updated = try await repository.trashManualItem(project: project, kind: .event, id: request.id)
                    case .book, .bookLocal: return
                    }
                    publish(updated)
                    reconcileSelectionAfterTrash(in: updated)
                    activity = request.kind == .document ? "文档已移入回收站，可以恢复。" : "对象与关联已移入回收站，可以恢复。"
                }
                await reloadTrash()
            } catch {
                let message = error.localizedDescription
                if request.kind != .book && request.kind != .bookLocal, let targetBookID = request.bookID { await refreshBookAfterManualTrashFailure(targetBookID) }
                errorMessage = message
            }
        }
    }
    func reloadTrash() async {
        do {
            let report = try await repository.trashReport(); archivedBooks = report.projects
            let removed = try await repository.removedBooksReport(); removedBooks = removed.projects
            if !report.issues.isEmpty || !removed.issues.isEmpty { errorMessage = libraryLoadIssueSummary(report.issues + removed.issues) }
        } catch { errorMessage = error.localizedDescription }
    }
    func restoreBook(_ id: String) async {
        guard !isBusy else { return }
        guard !editorDirty else { errorMessage = "请先保存正在编辑的 Markdown，再恢复内容。"; return }
        isBusy = true; defer { isBusy = false }
        do { let restored = try await repository.restoreBook(id: id); publish(restored); await reloadTrash(); activity = "书籍已恢复到书库。" }
        catch { errorMessage = error.localizedDescription }
    }
    func restoreDocument(bookID: String, documentID: String) async {
        guard !isBusy, let project = books.first(where: { $0.id == bookID }) else { return }
        guard !editorDirty else { errorMessage = "请先保存正在编辑的 Markdown，再恢复内容。"; return }
        isBusy = true; defer { isBusy = false }
        do { let updated = try await repository.setDocumentTrashed(project: project, documentID: documentID, trashed: false); publish(updated); activity = "Markdown 与原节点已恢复。" }
        catch { errorMessage = error.localizedDescription }
    }
    func removeCanvasNode(_ id: String) async {
        _ = await trashManualItem(.node, id: id)
    }
    func addDocumentToGraph(_ document: DocumentRecord) async {
        guard var project = book, !isBusy, document.trashedAt == nil else { return }
        isBusy = true; defer { isBusy = false }
        let index = project.nodes.count
        project.nodes.append(CanvasNode(targetID: document.id, x: Double(index % 3) * 270 + 60, y: Double(index / 3) * 150 + 60))
        do { publish(try await repository.save(project)); activity = "文档节点已加入导图。" }
        catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    func removeConnection(_ id: String, relation: Bool = false, onError: ((String) -> Void)? = nil) async -> Bool {
        await trashManualItem(relation ? .relation : .edge, id: id, onError: onError)
    }
    func removeView(_ id: String) async {
        guard let project = book, !isBusy, let view = project.views.first(where: { $0.id == id }) else { return }
        let removedIDs = WorkspaceComponentRegistry.shared.removalIDs(for: view, in: project.views)
        if await trashManualItem(.view, id: id, viewIDs: removedIDs.sorted()), bookID == project.id, removedIDs.contains(route) { route = "reader" }
    }
    @discardableResult
    private func trashManualItem(_ kind: ManualTrashKind, id: String, viewIDs: [String] = [], onError: ((String) -> Void)? = nil) async -> Bool {
        func report(_ message: String) { if let onError { onError(message) } else { errorMessage = message } }
        guard let project = book, !isBusy else { return false }
        guard !editorDirty else { report("请先保存正在编辑的 Markdown，再移入回收站。"); return false }
        isBusy = true; defer { isBusy = false }
        do {
            let updated = try await repository.trashManualItem(project: project, kind: kind, id: id, viewIDs: viewIDs)
            publish(updated); reconcileSelectionAfterTrash(in: updated)
            activity = kind == .view ? "组件与原配置已移入回收站；书中知识保留。" : "内容与受影响的关联已移入回收站，可以恢复。"
            return true
        } catch {
            let message = error.localizedDescription
            await refreshBookAfterManualTrashFailure(project.id)
            report(message); return false
        }
    }
    @discardableResult
    func restoreManualItems(bookID: String, itemID: String, expectedItemIDs: [String], onError: ((String) -> Void)? = nil) async -> Bool {
        func report(_ message: String) { if let onError { onError(message) } else { errorMessage = message } }
        guard !isBusy, let project = books.first(where: { $0.id == bookID }) else { return false }
        guard !editorDirty else { report("请先保存正在编辑的 Markdown，再恢复内容。"); return false }
        isBusy = true; defer { isBusy = false }
        do {
            let updated = try await repository.restoreManualItems(project: project, itemID: itemID, expectedItemIDs: expectedItemIDs)
            publish(updated); activity = "内容与已确认的关联已恢复；另行回收的笔记请单独恢复。"; return true
        } catch {
            let message = error.localizedDescription
            await refreshBookAfterManualTrashFailure(project.id)
            report(message); return false
        }
    }
    private func refreshBookAfterManualTrashFailure(_ targetBookID: String) async {
        guard !editorDirty,
              let report = try? await repository.loadReport(),
              let refreshed = report.projects.first(where: { $0.id == targetBookID }), !editorDirty else { return }
        let wasCurrentView = bookID == targetBookID && book?.views.contains(where: { $0.id == route }) == true
        publish(refreshed); reconcileSelectionAfterTrash(in: refreshed)
        if wasCurrentView, !refreshed.views.contains(where: { $0.id == route }) { route = "reader" }
    }
    private func reconcileSelectionAfterTrash(in project: BookProject) {
        guard bookID == project.id else { return }
        let objects = Set(project.entities.map(\.id) + project.events.map(\.id) + project.activeDocuments.map(\.id) + project.units.map(\.id))
        if let id = selectedObjectID, !objects.contains(id) { selectedObjectID = nil }
        if let id = selectedTemporalEntityID, !project.entities.contains(where: { $0.id == id }) { selectedTemporalEntityID = nil }
        if let id = selectedDocumentID, !project.activeDocuments.contains(where: { $0.id == id }) {
            selectedDocumentID = nil; editorMarkdown = ""; editorTitle = ""; draftEvidence = []
            UserDefaults.standard.removeObject(forKey: "draft-\(project.id)")
        }
    }
}
