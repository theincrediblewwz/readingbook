import SwiftUI
import CryptoKit
import ReadingCore

@MainActor extension AppStore {
    var queryReadingContext: ReadingContext {
        var context = currentReadingContext
        if queryScope != .notes {
            context.documentID = nil; context.unitID = selectedSourceAnchor?.unitID ?? selectedUnitID
            context.page = sourceReadingSelection?.page ?? selectedUnit?.page
        }
        if queryScope == .selection, let selection = sourceReadingSelection {
            context.selectedText = selection.text
            context.selectionEndPage = selection.endPage
        }
        return context
    }
    var queryScopePreview: String {
        switch queryScope {
        case .selection: return (sourceReadingSelection?.text ?? selectedSourceAnchor?.quote).map { "所选文字 · \($0.count) 字" } ?? "请先在原文选择文字"
        case .page: return selectedUnit?.page.map { "当前页 · 第 \($0) 页" } ?? "当前阅读位置"
        case .chapter: return selectedUnit?.chapter.isEmpty == false ? selectedUnit!.chapter : "当前章节"
        case .book: return "整本书 · \(book?.title ?? "")"
        case .notes: return queryDocumentIDs.map { "我的笔记 · 已选 \($0.count) 篇" } ?? "我的笔记 · 全部已保存笔记"
        }
    }
    func canUseQueryScope(_ scope: ReadingQueryScope) -> Bool {
        switch scope {
        case .selection: return sourceReadingSelection?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || selectedSourceAnchor != nil
        case .notes: return book?.activeDocuments.isEmpty == false && queryDocumentIDs?.isEmpty != true
        case .page, .chapter: return selectedUnit != nil
        case .book: return book?.units.isEmpty == false
        }
    }
    func setQueryDocument(_ id: String, included: Bool) {
        var selected = queryDocumentIDs ?? Set(book?.activeDocuments.map(\.id) ?? [])
        if included { selected.insert(id) } else { selected.remove(id) }
        queryDocumentIDs = selected
    }
    private func queryMemoryURL(for snapshot: ReadingQuerySnapshot) -> URL {
        let identity = snapshot.bookID + "|" + snapshot.scopeFingerprint
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return libraryRootURL.appendingPathComponent("ConversationMemory", isDirectory: true).appendingPathComponent(name + ".json")
    }
    func loadQueryMemory(for snapshot: ReadingQuerySnapshot) -> ConversationMemory? {
        let url = queryMemoryURL(for: snapshot)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConversationMemory.self, from: data)
    }
    func saveQueryMemory(_ memory: ConversationMemory?, for snapshot: ReadingQuerySnapshot) {
        guard let memory, !storageState.working, memory.bookID == snapshot.bookID, memory.scopeFingerprint == snapshot.scopeFingerprint else { return }
        let root = libraryRootURL
        Task {
            do {
                try await QueryMemoryFiles.shared.write(memory, snapshot: snapshot, root: root)
                if libraryRootURL == root, bookID == snapshot.bookID { queryMemoryRevision += 1 }
            }
            catch { if libraryRootURL == root, bookID == snapshot.bookID { queryDisclosure += "\n本次会话记忆未能缓存，原对话仍完整保留。" } }
        }
    }
    func clearCurrentQueryMemory() {
        guard !isQueryBusy, !storageState.working else { return }
        guard let project = book else { return }
        let key = queryMemoryPreparationKey
        Task {
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try ReadingQuerySnapshot.freeze(scope: key.scope, in: project, context: key.context,
                        documentIDs: key.documents, appendedDocumentIDs: key.scope == .notes ? [] : key.attachments, authorizedNodeIDs: key.nodes)
                        .withContextIdentity(key.mode)
                }.value
                try await QueryMemoryFiles.shared.remove(snapshot: snapshot, root: key.root)
                if bookID == key.bookID, libraryRootURL == key.root { queryMemoryRevision += 1; queryDisclosure = "已清除本范围的派生记忆；原始问答和笔记保留。" }
            } catch { if bookID == key.bookID, libraryRootURL == key.root { errorMessage = "派生记忆未能清除：\(error.localizedDescription)" } }
        }
    }
}

/// The reader chooses a scope. It is frozen again before the request starts.
struct QueryScopeControl: View {
    @EnvironmentObject var store: AppStore
    var compact = false
    var body: some View {
        Menu {
            ForEach(ReadingQueryScope.allCases, id: \.self) { scope in
                Button { store.queryScope = scope } label: {
                    HStack {
                        Label(scope.title, systemImage: icon(scope))
                        Spacer(minLength: 16)
                        if store.queryScope == scope { Image(systemName: "checkmark") }
                    }
                }.disabled(!store.canUseQueryScope(scope))
            }
            if store.queryScope == .notes {
                Divider()
                Button { store.queryDocumentIDs = nil } label: { Label("选择全部笔记", systemImage: "checkmark.circle") }
                ForEach(store.book?.activeDocuments ?? []) { document in
                    Toggle(document.title, isOn: Binding(get: { store.queryDocumentIDs?.contains(document.id) ?? true },
                        set: { store.setQueryDocument(document.id, included: $0) }))
                }
            }
        } label: {
            Label(store.queryScope.title, systemImage: icon(store.queryScope))
                .font(.system(size: compact ? 14 : 15, weight: .medium)).frame(minHeight: 44)
        }.menuStyle(.borderlessButton).fixedSize().disabled(store.isQueryBusy).help("选择这次提问允许读取的内容")
    }
    private func icon(_ scope: ReadingQueryScope) -> String {
        switch scope {
        case .selection: return "text.cursor"
        case .page: return "doc.text"
        case .chapter: return "book.closed"
        case .book: return "books.vertical"
        case .notes: return "square.and.pencil"
        }
    }
}
