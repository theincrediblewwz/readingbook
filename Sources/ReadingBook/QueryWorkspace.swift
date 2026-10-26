import SwiftUI
import CryptoKit
import ReadingCore

@MainActor extension AppStore {
    var queryReadingContext: ReadingContext {
        readingQueryContext(for: queryScope)
    }
    private func readingQueryContext(for scope: ReadingQueryScope) -> ReadingContext {
        var context = currentReadingContext
        if scope != .selection {
            // Changing the chosen query scope must not mix a neighboring
            // page's focused sentence with the cursor page/notes scope.
            context.selectedSourceAnchor = nil; context.selectedAnchorID = nil
            context.selectedText = nil; context.selectedPrefix = nil; context.selectedSuffix = nil
            context.selectionEndPage = nil
        }
        switch scope {
        case .notes:
            // Notes do not inherit an unrelated source cursor or selection.
            context.unitID = nil; context.page = nil
        case .page, .chapter, .book:
            // These controls and their preview refer to the current reading
            // cursor, never the beginning of a native drag on another page.
            context.documentID = nil; context.unitID = selectedUnitID; context.page = selectedUnit?.page
            if scope == .chapter, let book, let anchor = chapterReadingAnchor(in: book, unitID: selectedUnitID),
               anchor.unitID == selectedUnitID, anchor.sourceHash == book?.sourceHash {
                context.selectedSourceAnchor = anchor
            }
        case .selection:
            context.documentID = nil
            // A pinned sentence may belong to a simultaneously visible page.
            // Keep its complete context unless an explicit native drag wins.
            if let selection = sourceReadingSelection {
                let anchor = selectedSourceAnchor
                context.unitID = anchor?.unitID ?? selection.page.flatMap { page in book?.units.first(where: { $0.page == page })?.id } ?? selectedUnitID
                context.page = selection.page ?? selectedUnit?.page
                context.selectedAnchorID = nil; context.selectedSourceAnchor = nil
                context.selectedText = selection.text
                context.selectedPrefix = anchor?.prefix; context.selectedSuffix = anchor?.suffix
                context.selectionEndPage = selection.endPage
            } else if context.selectedText != nil {
                // The complete proof belongs only to a sentence question;
                // general reading/map/graph contexts keep their prior cost.
                context.selectedSourceAnchor = focusedReadingSourceAnchor
            }
        }
        return context
    }
    var queryScopePreview: String {
        switch queryScope {
        case .selection: return querySelectionText.map { "所选文字 · \($0.count) 字" } ?? "请先在原文选择文字"
        case .page: return selectedUnit?.page.map { "当前页 · 第 \($0) 页" } ?? "当前阅读位置"
        case .chapter: return "当前章节"
        case .book: return "整本书 · \(book?.title ?? "")"
        case .notes: return queryDocumentIDs.map { "我的笔记 · 已选 \($0.count) 篇" } ?? "我的笔记 · 全部已保存笔记"
        }
    }
    func canUseQueryScope(_ scope: ReadingQueryScope) -> Bool {
        switch scope {
        case .selection: return querySelectionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .notes: return book?.activeDocuments.isEmpty == false && queryDocumentIDs?.isEmpty != true
        case .page, .chapter: return selectedUnit != nil
        case .book: return book?.units.isEmpty == false
        }
    }
    /// Native selections and a sentence explicitly opened from its inline card
    /// are the same query capability. Keep the composer gate and preview on the
    /// exact context the request will freeze, rather than requiring an AppKit
    /// drag selection that an inline-card click deliberately does not create.
    private var querySelectionText: String? {
        // The scope menu can ask about selection while the active scope is
        // still page/notes. Use the would-be selection context here so native
        // multi-unit/cross-page selections remain selectable from that menu.
        let context = readingQueryContext(for: .selection)
        guard context.sourceHash == book?.sourceHash,
              context.unitID != nil || context.page != nil else { return nil }
        return context.selectedText
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
    func saveQueryMemory(_ memory: ConversationMemory?, for snapshot: ReadingQuerySnapshot, root: URL) async {
        guard let memory, !storageState.working, libraryRootURL == root, bookID == snapshot.bookID,
              memory.bookID == snapshot.bookID, memory.scopeFingerprint == snapshot.scopeFingerprint else { return }
        // Keep the question lane occupied until its derived write finishes, so
        // an immediate library transfer cannot race this separate file actor.
        do {
            try await QueryMemoryFiles.shared.write(memory, snapshot: snapshot, root: root)
            if libraryRootURL == root, bookID == snapshot.bookID { queryMemoryRevision += 1 }
        }
        catch { if libraryRootURL == root, bookID == snapshot.bookID { queryDisclosure += "\n本次会话记忆未能缓存，原对话仍完整保留。" } }
    }
    func clearCurrentQueryMemory() {
        guard !isQueryBusy, !isManagingQueryMemory, !storageState.working else { return }
        guard let project = book else { return }
        let key = queryMemoryPreparationKey
        isManagingQueryMemory = true
        Task {
            defer { isManagingQueryMemory = false }
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
