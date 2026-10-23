import SwiftUI
import ReadingCore

struct WorkspaceDeletion {
    enum Kind: Equatable { case book, document, entity, event }
    var kind: Kind
    var id: String
    var title: String
    var bookID: String?
    var detail: String {
        switch kind {
        case .book: return "整本书及本机副本中的文档将移入回收站，可以恢复。导入前的原始文件保持原样。"
        case .document: return "Markdown 将移入回收站，画布和知识库暂时隐藏它；恢复后保留原内容与节点。聊天记录保留。"
        case .entity, .event: return "对象与受影响的结构化关联将一起移入回收站，暂时从地图、时间轴和导图隐藏。恢复时会核对关联；原书与 Markdown 正文保留。"
        }
    }
}

extension AppStore {
    func requestDeletion(_ kind: WorkspaceDeletion.Kind, id: String, title: String) {
        guard !isBusy else { return }
        guard !editorDirty else { errorMessage = "请先保存正在编辑的 Markdown，再移入回收站。"; return }
        deletionRequest = WorkspaceDeletion(kind: kind, id: id, title: title, bookID: bookID)
    }
    func confirmDeletion(_ request: WorkspaceDeletion) {
        guard !isBusy else { return }
        deletionRequest = nil
        guard !editorDirty else { errorMessage = "请先保存正在编辑的 Markdown，再移入回收站。"; return }
        isBusy = true
        task = Task {
            defer { isBusy = false }
            do {
                if request.kind == .book {
                    guard let project = books.first(where: { $0.id == request.id }) else { return }
                    try await repository.archiveBook(project: project)
                    books.removeAll { $0.id == project.id }
                    pdfSessionPasswords.removeValue(forKey: project.id); pdfUnlockedBookIDs.remove(project.id)
                    if bookID == project.id { bookID = nil; selectedUnitID = nil; selectedObjectID = nil; selectedDocumentID = nil; sourceFileURL = nil; editorMarkdown = ""; editorTitle = ""; draftEvidence = [] }
                    activity = "书籍已移入回收站。"
                } else if let project = books.first(where: { $0.id == request.bookID }) {
                    let updated: BookProject
                    switch request.kind {
                    case .document: updated = try await repository.setDocumentTrashed(project: project, documentID: request.id, trashed: true)
                    case .entity: updated = try await repository.trashManualItem(project: project, kind: .entity, id: request.id)
                    case .event: updated = try await repository.trashManualItem(project: project, kind: .event, id: request.id)
                    case .book: return
                    }
                    publish(updated)
                    reconcileSelectionAfterTrash(in: updated)
                    activity = request.kind == .document ? "文档已移入回收站，可以恢复。" : "对象与关联已移入回收站，可以恢复。"
                }
                await reloadTrash()
            } catch {
                let message = error.localizedDescription
                if request.kind != .book, let targetBookID = request.bookID { await refreshBookAfterManualTrashFailure(targetBookID) }
                errorMessage = message
            }
        }
    }
    func reloadTrash() async {
        do { let report = try await repository.trashReport(); archivedBooks = report.projects; if !report.issues.isEmpty { errorMessage = libraryLoadIssueSummary(report.issues) } } catch { errorMessage = error.localizedDescription }
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
        do { try await repository.save(project); publish(project); activity = "文档节点已加入导图。" }
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
