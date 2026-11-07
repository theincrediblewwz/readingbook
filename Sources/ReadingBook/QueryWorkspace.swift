import SwiftUI
import CryptoKit
import ReadingCore

@MainActor extension AppStore {
    var queryReadingContext: ReadingContext {
        readingQueryContext(for: queryScope)
    }
    private func readingQueryContext(for scope: ReadingQueryScope) -> ReadingContext {
        var context = currentReadingContext
        context.queryRange = scope == .range ? querySourceRange : nil
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
        case .page, .readSoFar, .chapter, .range, .book:
            // These controls and their preview refer to the current reading
            // cursor, never the beginning of a native drag on another page.
            context.documentID = nil; context.unitID = selectedUnitID; context.page = selectedUnit?.page
            if scope == .chapter, let book, let anchor = chapterReadingAnchor(in: book, unitID: selectedUnitID),
               anchor.unitID == selectedUnitID, anchor.sourceHash == book.sourceHash {
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
        case .readSoFar: return selectedUnit?.page.map { "从开头至第 \($0) 页（含本页）" } ?? "从开头至当前原文"
        case .chapter: return "当前章节"
        case .range:
            if let range = querySourceRange, range.kind == .pages, let start = range.pageStart, let end = range.pageEnd { return "第 \(start)–\(end) 页" }
            return "指定章节范围"
        case .book: return "整本书 · \(book?.title ?? "")"
        case .notes: return queryDocumentIDs.map { "我的笔记 · 已选 \($0.count) 篇" } ?? "我的笔记 · 全部已保存笔记"
        }
    }
    func canUseQueryScope(_ scope: ReadingQueryScope) -> Bool {
        switch scope {
        case .selection: return querySelectionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .notes: return book?.activeDocuments.isEmpty == false && queryDocumentIDs?.isEmpty != true
        case .page, .readSoFar, .chapter: return selectedUnit != nil
        case .range: return book?.units.isEmpty == false
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
    func saveQueryMemory(_ memory: ConversationMemory?, for snapshot: ReadingQuerySnapshot, preferences: ReadingAnswerPreferences, root: URL) async {
        guard let memory, !storageState.working, libraryRootURL == root, bookID == snapshot.bookID,
              memory.bookID == snapshot.bookID, memory.scopeFingerprint == snapshot.scopeFingerprint else { return }
        // Keep the question lane occupied until its derived write finishes, so
        // an immediate library transfer cannot race this separate file actor.
        do {
            guard let latest = book else { return }
            let history = try await Task.detached(priority: .utility) {
                _ = try snapshot.sourceRanges(in: latest)
                return ReadingChatHistory.automaticHistory(in: latest, preferences: preferences, snapshot: snapshot)
            }.value
            try await QueryMemoryFiles.shared.write(memory, snapshot: snapshot, history: history, root: root)
            if libraryRootURL == root, bookID == snapshot.bookID { queryMemoryRevision += 1 }
        }
        catch { if libraryRootURL == root, bookID == snapshot.bookID { queryDisclosure += "\n本次会话记忆未能缓存，原对话仍完整保留。" } }
    }
    func clearCurrentQueryMemory() {
        guard !isQueryBusy, !isManagingQueryMemory, !storageState.working else { return }
        guard let project = book else { return }
        let key = queryMemoryPreparationKey, preferences = currentQueryPreferences
        isManagingQueryMemory = true
        Task {
            defer { isManagingQueryMemory = false }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try ReadingQuerySnapshot.freeze(scope: key.scope, in: project, context: key.context,
                        documentIDs: key.documents, appendedDocumentIDs: key.scope == .notes ? [] : key.attachments, authorizedNodeIDs: key.nodes)
                        .withContextIdentity(try ReaderCollectionRuntime.contextIdentity(preferences: preferences,
                            references: ReaderCollectionRuntime.explicitReferences(key.references, in: project)))
                }.value
                try await QueryMemoryFiles.shared.remove(snapshot: snapshot, root: key.root)
                if bookID == key.bookID, libraryRootURL == key.root { queryMemoryRevision += 1; queryMemoryStatusKey = queryMemoryPreparationKey; queryMemoryStatus = "摘要已清除，完整问答和笔记保留。"; queryDisclosure = queryMemoryStatus }
            } catch { if bookID == key.bookID, libraryRootURL == key.root { errorMessage = "派生记忆未能清除：\(error.localizedDescription)" } }
        }
    }

    func summarizeCurrentConversation() {
        guard !isManagingQueryMemory, !storageState.working, let original = book else { return }
        let key = queryMemoryPreparationKey, preferences = currentQueryPreferences
        let memoryOwner = WorkspacePickerOwner(store: self)
        var frozenSettings = settings; frozenSettings.transportSessionID = "readingbook-" + original.id + "-summary"
        let frozenKey = apiKey
        isManagingQueryMemory = true; queryMemoryStatus = "正在整理当前范围的问答…"
        queryMemoryStatusKey = key
        queryMemoryTask = Task {
            var progressID: UUID?
            defer {
                if let progressID { finishAIProgress(progressID) }
                isManagingQueryMemory = false; isSummaryRequestRunning = false; queryMemoryTask = nil
            }
            do {
                let project = key.scope == .chapter || (key.scope == .range && key.context.queryRange?.kind == .chapters)
                    ? try await ensureBookChapterOutline(project: original) : original
                let worker = Task.detached(priority: .userInitiated) {
                    try ReadingPreparedAnswer.freeze(project: project, scope: key.scope, context: key.context,
                        documentIDs: key.documents, appendedDocumentIDs: key.attachments, authorizedNodeIDs: key.nodes,
                        preferences: preferences, referencedAnswerIDs: key.references)
                }
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard memoryOwner.matches(self) else { throw CancellationError() }
                let previous = await QueryMemoryFiles.shared.read(snapshot: prepared.snapshot, history: prepared.history, root: key.root)
                let reader = AIReader(coordinator: sharedAIRequests, lane: .background)
                progressID = await beginSummaryProgress(title: "整理摘要 · " + prepared.snapshot.displayTitle, worker: reader, settings: frozenSettings)
                try Task.checkCancellation()
                guard memoryOwner.matches(self) else { throw CancellationError() }
                isSummaryRequestRunning = true
                let memory = try await reader.summarizeConversation(prepared: prepared, previous: previous, settings: frozenSettings, apiKey: frozenKey)
                try Task.checkCancellation()
                guard memoryOwner.matches(self), let latest = book else { throw CancellationError() }
                let checker = Task.detached(priority: .utility) {
                    _ = try prepared.snapshot.sourceRanges(in: latest)
                    return ReadingChatHistory.automaticHistory(in: latest, preferences: preferences, snapshot: prepared.snapshot)
                }
                let currentHistory = try await withTaskCancellationHandler(operation: { try await checker.value }, onCancel: { checker.cancel() })
                try Task.checkCancellation()
                guard memoryOwner.matches(self) else { throw CancellationError() }
                let stored = try await QueryMemoryFiles.shared.write(memory, snapshot: prepared.snapshot, history: currentHistory, root: key.root)
                guard libraryRootURL == key.root, bookID == key.bookID else { return }
                queryMemoryRevision += 1
                var statusKey = key; statusKey.revision = projectRevision; statusKey.memoryRevision = queryMemoryRevision
                queryMemoryStatusKey = statusKey
                queryMemoryStatus = stored.cursor.index >= currentHistory.count ? "摘要已更新，原始问答完整保留。" : "已整理前\(stored.cursor.index)条消息\(stored.cursor.offset > 0 ? "及下一条的部分内容" : "")，点击继续整理可补齐。"
            } catch {
                if let progressID { finishAIProgress(progressID, error: error) }
                guard libraryRootURL == key.root, bookID == key.bookID else { return }
                queryMemoryStatus = error is CancellationError ? "已停止整理，已有摘要与原问答保留。" : "整理未完成：" + error.localizedDescription
            }
        }
    }
}

/// The reader chooses a scope. It is frozen again before the request starts.
struct QueryScopeControl: View {
    @EnvironmentObject var store: AppStore
    var compact = false
    @State private var presented = false
    @State private var owner: WorkspacePickerOwner?
    @State private var choosingRange = false
    var body: some View {
        Button { owner = WorkspacePickerOwner(store: store); presented = true } label: {
            HStack(spacing: 5) { Label(store.queryScope.title, systemImage: icon(store.queryScope)); Image(systemName: "chevron.down").font(.system(size: 9)) }
                .font(.system(size: compact ? 14 : 15, weight: .medium)).frame(minHeight: 44)
        }.buttonStyle(ReadingQuietButtonStyle()).fixedSize().disabled(store.isQueryBusy).help("选择这次提问允许读取的内容")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("本次阅读范围").font(.system(size: 16, weight: .semibold)); Spacer()
                        Button { presented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭阅读范围")
                    }.padding(.horizontal, 12)
                    if choosingRange {
                        QuerySourceRangePicker { choice in
                            guard owner?.matches(store) == true else { return }
                            store.querySourceRange = choice; store.queryScope = .range; presented = false
                        } cancel: { choosingRange = false }
                    } else { ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(ReadingQueryScope.allCases, id: \.self) { scope in
                                Button {
                                    guard owner?.matches(store) == true else { return }
                                    if scope == .range { choosingRange = true; return }
                                    store.queryScope = scope
                                    if scope != .notes { presented = false }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: icon(scope)).foregroundStyle(Palette.accent).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 4) { Text(scope.title).font(.system(size: 14, weight: .medium)); Text(detail(scope)).font(.system(size: 12)).foregroundStyle(.secondary) }
                                        Spacer(); if store.queryScope == scope { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                                    }.padding(12).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                }.buttonStyle(ReadingQuietButtonStyle()).disabled(!store.canUseQueryScope(scope)).help(detail(scope))
                            }
                            if store.queryScope == .notes {
                                Divider().padding(.vertical, 6)
                                Button("选择全部已保存笔记") { guard owner?.matches(store) == true else { return }; store.queryDocumentIDs = nil }
                                    .buttonStyle(ReadingToolbarButtonStyle())
                                ForEach(store.book?.activeDocuments ?? []) { document in
                                    Toggle(document.title, isOn: Binding(get: { store.queryDocumentIDs?.contains(document.id) ?? true },
                                        set: { if owner?.matches(store) == true { store.setQueryDocument(document.id, included: $0) } }))
                                        .toggleStyle(.checkbox).font(.system(size: 14)).frame(minHeight: 40).padding(.horizontal, 12)
                                }
                            }
                        }.padding(.horizontal, 8)
                    }.frame(maxHeight: 480) }
                }.padding(10).frame(width: choosingRange ? 410 : 370)
            }.onChange(of: presented) { _, value in if !value { choosingRange = false } }
            .onChange(of: store.collectionOwnerKey) { _, _ in presented = false }
    }
    private func detail(_ scope: ReadingQueryScope) -> String {
        switch scope {
        case .selection: return "只读你选中的原文片段"
        case .page: return "围绕当前页，不自动扩大到后文"
        case .readSoFar: return "允许从开头检索至当前页，包含当前整页"
        case .chapter: return "读取当前章节的完整范围"
        case .range: return "自己选择起止页码或章节"
        case .book: return "允许检索本书的全部原文"
        case .notes: return "选择本次允许读取的已保存笔记"
        }
    }
    private func icon(_ scope: ReadingQueryScope) -> String {
        switch scope {
        case .selection: return "text.cursor"
        case .page: return "doc.text"
        case .readSoFar: return "book.pages"
        case .chapter: return "book.closed"
        case .range: return "text.page.badge.magnifyingglass"
        case .book: return "books.vertical"
        case .notes: return "square.and.pencil"
        }
    }
}
