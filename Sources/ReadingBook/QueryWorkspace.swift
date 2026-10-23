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
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReadingBook/ConversationMemory", isDirectory: true).appendingPathComponent(name + ".json")
    }
    func loadQueryMemory(for snapshot: ReadingQuerySnapshot) -> ConversationMemory? {
        let url = queryMemoryURL(for: snapshot)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConversationMemory.self, from: data)
    }
    func saveQueryMemory(_ memory: ConversationMemory?, for snapshot: ReadingQuerySnapshot) {
        guard let memory else { return }
        do {
            let url = queryMemoryURL(for: snapshot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(memory)
            guard data.count <= 1_048_576 else { return }
            try data.write(to: url, options: .atomic)
        } catch { queryDisclosure += "\n本次会话记忆未能缓存，原对话仍完整保留。" }
    }
    func clearCurrentQueryMemory() {
        guard let snapshot = try? currentQueryTaskSnapshot() else { return }
        let url = queryMemoryURL(for: snapshot)
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            queryDisclosure = "已清除本范围的派生记忆；原始问答和笔记保留。"
        } catch { errorMessage = "派生记忆未能清除：\(error.localizedDescription)" }
    }
}

/// The reader chooses a scope. It is frozen again before the request starts.
struct QueryScopeControl: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Menu {
            ForEach(ReadingQueryScope.allCases, id: \.self) { scope in
                Button { store.queryScope = scope } label: {
                    Label(scope.title, systemImage: store.queryScope == scope ? "checkmark" : icon(scope))
                }.disabled(!store.canUseQueryScope(scope))
            }
            if store.queryScope == .notes {
                Divider()
                Button("选择全部笔记") { store.queryDocumentIDs = nil }
                ForEach(store.book?.activeDocuments ?? []) { document in
                    Toggle(document.title, isOn: Binding(get: { store.queryDocumentIDs?.contains(document.id) ?? true },
                        set: { store.setQueryDocument(document.id, included: $0) }))
                }
            }
        } label: {
            Label(store.queryScope.title, systemImage: icon(store.queryScope)).frame(minHeight: 44)
        }.menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy).help("选择这次提问允许读取的内容")
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
