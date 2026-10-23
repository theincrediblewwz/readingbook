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
        case .entity, .event: return "移除此派生对象，并清理地图、时间轴、关系和画布中的结构化关联。原书和 Markdown 正文保留；此对象没有一键恢复。"
        }
    }
}

extension AppStore {
    func requestDeletion(_ kind: WorkspaceDeletion.Kind, id: String, title: String) {
        guard !isBusy else { return }
        deletionRequest = WorkspaceDeletion(kind: kind, id: id, title: title, bookID: bookID)
    }
    func confirmDeletion(_ request: WorkspaceDeletion) {
        guard !isBusy else { return }
        deletionRequest = nil
        guard !editorDirty else { errorMessage = "请先保存正在编辑的 Markdown，再删除内容。"; return }
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
                    case .entity: updated = try KnowledgeDeletion.removingEntity(id: request.id, from: project); try await repository.save(updated)
                    case .event: updated = try KnowledgeDeletion.removingEvent(id: request.id, from: project); try await repository.save(updated)
                    case .book: return
                    }
                    publish(updated)
                    if bookID == project.id && selectedObjectID == request.id { selectedObjectID = nil }
                    if bookID == project.id && selectedTemporalEntityID == request.id { selectedTemporalEntityID = nil }
                    if bookID == project.id && selectedDocumentID == request.id { selectedDocumentID = nil; editorMarkdown = ""; editorTitle = ""; draftEvidence = []; UserDefaults.standard.removeObject(forKey: "draft-\(project.id)") }
                    activity = request.kind == .document ? "文档已移入回收站，可以恢复。" : "派生对象及结构化关联已移除。"
                }
                await reloadTrash()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func reloadTrash() async {
        do { let report = try await repository.trashReport(); archivedBooks = report.projects; if !report.issues.isEmpty { errorMessage = libraryLoadIssueSummary(report.issues) } } catch { errorMessage = error.localizedDescription }
    }
    func restoreBook(_ id: String) async {
        guard !isBusy else { return }; isBusy = true; defer { isBusy = false }
        do { let restored = try await repository.restoreBook(id: id); publish(restored); await reloadTrash(); activity = "书籍已恢复到书库。" }
        catch { errorMessage = error.localizedDescription }
    }
    func restoreDocument(bookID: String, documentID: String) async {
        guard !isBusy, let project = books.first(where: { $0.id == bookID }) else { return }
        isBusy = true; defer { isBusy = false }
        do { let updated = try await repository.setDocumentTrashed(project: project, documentID: documentID, trashed: false); publish(updated); activity = "Markdown 与原节点已恢复。" }
        catch { errorMessage = error.localizedDescription }
    }
    func removeCanvasNode(_ id: String) async {
        guard let project = book, !isBusy else { return }; isBusy = true; defer { isBusy = false }
        do { let updated = try KnowledgeDeletion.removingCanvasNode(id: id, from: project); try await repository.save(updated); publish(updated); activity = "已移除画布节点，文档仍在知识库中。" }
        catch { errorMessage = error.localizedDescription }
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
        guard let project = book, !isBusy else { return false }; isBusy = true; defer { isBusy = false }
        do {
            let updated: BookProject
            if relation { updated = try KnowledgeDeletion.removingRelation(id: id, from: project) }
            else { updated = try KnowledgeDeletion.removingCanvasEdge(id: id, from: project) }
            try await repository.save(updated); publish(updated); activity = "连线已移除，节点内容保留。"; return true
        }
        catch { if let onError { onError(error.localizedDescription) } else { errorMessage = error.localizedDescription }; return false }
    }
    func removeView(_ id: String) async {
        guard var project = book, !isBusy, let view = project.views.first(where: { $0.id == id }) else { return }
        isBusy = true; defer { isBusy = false }
        let removedIDs = WorkspaceComponentRegistry.shared.removalIDs(for: view, in: project.views)
        project.views.removeAll { removedIDs.contains($0.id) }
        do { try await repository.save(project); publish(project); if removedIDs.contains(route) { route = "reader" }; activity = "组件入口已移除，原有知识数据保留；可从添加组件重新打开。" }
        catch { errorMessage = error.localizedDescription }
    }
}

struct LibraryTrashView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil
    @State private var query = ""
    private func matches(_ title: String) -> Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("回收站").font(.system(size: 25, weight: .semibold)); Spacer()
                Button { if let onClose { onClose() } else { dismiss() } } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction).accessibilityLabel("关闭回收站")
            }
            Text("恢复后，书籍回到书库，Markdown 和原来的导图节点重新显示。内容仍保留在本机。").font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索回收的书籍与笔记…", text: $query).textFieldStyle(.plain).font(.system(size: 15))
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("清空回收站搜索") }
            }.padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 48).readingGlass(radius: 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !store.archivedBooks.filter({ matches($0.title) }).isEmpty {
                        Text("书籍").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(store.archivedBooks.filter { matches($0.title) }) { book in
                            trashRow(title: book.title, detail: "书籍 · \(book.documents.count) 篇 Markdown", icon: "book.closed") { Task { await store.restoreBook(book.id) } }
                        }
                    }
                    ForEach(store.books.filter { $0.trashedDocuments.contains(where: { matches($0.title) }) }) { book in
                        Text("\(book.title) · Markdown").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).padding(.top, 16)
                        ForEach(book.trashedDocuments.filter { matches($0.title) }) { document in
                            trashRow(title: document.title, detail: "Markdown · 恢复正文与原节点", icon: "doc.text") { Task { await store.restoreDocument(bookID: book.id, documentID: document.id) } }
                        }
                    }
                    if store.archivedBooks.filter({ matches($0.title) }).isEmpty && !store.books.contains(where: { $0.trashedDocuments.contains(where: { matches($0.title) }) }) {
                        EmptyState(title: query.isEmpty ? "回收站是空的" : "没有匹配的内容", detail: query.isEmpty ? "移入回收站的书籍与笔记会显示在这里。" : "试试另一个书名或笔记标题。", icon: "trash").frame(minHeight: 210)
                    }
                }
            }
            Label("此版本保留恢复入口，不提供永久清空。", systemImage: "arrow.uturn.backward.circle").font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(24).background(Palette.canvas).controlSize(.large).task { await store.reloadTrash() }
    }
    private func trashRow(title: String, detail: String, icon: String, restore: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 16, weight: .medium)).lineLimit(2); Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: restore) { Label("恢复", systemImage: "arrow.uturn.backward") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy)
        }.padding(18).frame(maxWidth: .infinity, minHeight: 86).background(Palette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line.opacity(0.75), lineWidth: 0.8))
    }
}
