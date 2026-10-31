import SwiftUI
import ReadingCore

/// Original-first discovery. Optional AI supplies words, never source results.
struct LibrarySearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    /// Full-window hosts own the top island clearance. Sheets retain their
    /// suggested size; embedding must not add another 520-point minimum.
    var embedded = false
    var onClose: (() -> Void)? = nil
    var onPrepareResultNavigation: ((@escaping () -> Void) -> Void)? = nil
    var onNavigateToResult: (() -> Void)? = nil
    @State private var query = ""
    @State private var scope = "current"
    @State private var snapshots: [LibrarySourceSnapshot] = []
    @StateObject private var session = LibrarySearchSession()
    @State private var navigationTask: Task<Void, Never>?
    @State private var opening = false
    @State private var showingInfo = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("书库检索", systemImage: "magnifyingglass").font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 12)
                ManagementSegmentedControl(selection: $scope, options: [
                    ManagementSegmentOption(id: "current", title: "本书", detail: "只在当前打开书籍的原文和对象名称中检索"),
                    ManagementSegmentOption(id: "library", title: "整个书库", detail: "在当前书库所有已载入书籍中检索")
                ]).frame(width: 180)
                Button { showingInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("检索说明").help("简繁互搜、语言识别与 AI 扩展检索说明")
                    .popover(isPresented: $showingInfo) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("沿真实原文查找").font(.headline)
                            Text("输入后离线检索，支持简繁、大小写和全半角互搜。原书、笔记和分析不会被改写。")
                            Text("AI 扩展会把检索词与抽样识别的语言发送给当前 AI 服务，请它纠错、翻译或建议相关词，再在所选书籍中查证。不会发送原书或笔记正文，也不会把模型猜测当成原文结果。")
                            Text("语言识别是抽样提示；未识别的扫描页需先完成 OCR。结果数量有上限，可增加关键词缩小范围。")
                                .foregroundStyle(.secondary)
                        }.font(.system(size: 14)).padding(20).frame(width: 340).fixedSize(horizontal: false, vertical: true)
                    }
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("关闭书库检索").help("关闭检索，返回原来的界面").keyboardShortcut(.cancelAction)
            }.frame(minHeight: 48)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass").readingSearchIcon(pointSize: 16)
                TextField("搜索原文、人物、概念或别名", text: $query).readingSearchInput(pointSize: 16)
                    .focused($queryFocused).onSubmit { scheduleSearch(debounce: false) }
                if !query.isEmpty {
                    Button { query = ""; queryFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("清空检索词")
                }
            }.padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 52)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.opacity(0.7), lineWidth: 1))
            HStack(spacing: 8) {
                if session.searching { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(status).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    if let language = session.languageProfile { Text("原文语言 · \(language.summary)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if session.expanding {
                    ProgressView().controlSize(.small)
                    Button("停止扩展") { session.stopExpansion() }.buttonStyle(ReadingToolbarButtonStyle()).help("停止本次 AI 扩展，继续本地查找并保留已经查到的结果")
                } else {
                    Button { expandSearch() } label: { Label("AI 扩展", systemImage: "sparkles") }
                        .buttonStyle(ReadingToolbarButtonStyle()).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || opening)
                        .help("用当前 AI 服务纠错、翻译与扩展检索词，再查询真实原文；不会自动生成分析")
                }
            }.frame(minHeight: 44)
            if !session.expandedKeywords.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("扩展词").font(.caption).foregroundStyle(.secondary)
                        ForEach(session.expandedKeywords, id: \.self) { word in
                            Button { query = word } label: { Text(word).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Palette.accent.opacity(0.08), in: Capsule()).overlay(Capsule().strokeBorder(Palette.accent.opacity(0.16))) }
                                .buttonStyle(ReadingQuietButtonStyle()).help("只搜索“\(word)”")
                        }
                    }
                }.frame(height: 32)
            }
            if !session.errorMessage.isEmpty {
                Label(session.errorMessage, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            results.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20).background(embedded ? Color.clear : Palette.canvas).controlSize(.large)
        .frame(minWidth: embedded ? nil : 620, idealWidth: embedded ? nil : 820,
               minHeight: embedded ? nil : 520, idealHeight: embedded ? nil : 660)
        .onReceive(store.$books) { books in
            let next = books.map { LibrarySourceSnapshot(project: $0) }
            guard next != snapshots else { return }
            snapshots = next
            scheduleSearch()
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: scope) { _, _ in scheduleSearch() }
        .onChange(of: store.bookID) { _, _ in if scope == "current" { scheduleSearch() } }
        .onChange(of: store.libraryRootURL) { _, _ in scheduleSearch() }
        .onAppear { if store.bookID == nil { scope = "library" }; queryFocused = true; scheduleSearch() }
        .onDisappear { session.cancel(); navigationTask?.cancel() }
    }

    private var status: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "输入后查找 · 简繁互搜" }
        if session.expanding { return "正在扩展关键词，已有原文结果仍可查看…" }
        if session.searching { return "正在原文中查找…" }
        guard let response = session.response else { return "输入后自动查找。" }
        let bound = response.bounded ? " · 已达显示上限，可增加检索词缩小范围" : ""
        return "原文 \(response.matches.count) 处 · 对象 \(response.entityMatches.count) 项 · 范围 \(response.searchedBookCount) 本\(bound)"
    }

    @ViewBuilder private var results: some View {
        if let response = session.response, !response.matches.isEmpty || !response.entityMatches.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !response.matches.isEmpty {
                        Text("原文出现处").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(response.matches) { match in sourceRow(match) }
                    }
                    if !response.entityMatches.isEmpty {
                        Text("相关对象 · 同名结果按书籍分别保留").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(response.entityMatches) { match in entityRow(match) }
                    }
                }.padding(.vertical, 4)
            }
        } else if !session.searching, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, session.response != nil {
            ContentUnavailableView("没有找到匹配原文", systemImage: "text.magnifyingglass", description: Text("试试更短的词语或别名，也可以用 AI 扩展来纠错或翻译关键词。"))
        } else {
            ContentUnavailableView("沿原文寻找线索", systemImage: "books.vertical", description: Text("在一本书里追踪称谓，也可以把同一个词在不同书中的记载放在一起查阅。"))
        }
    }

    private func sourceRow(_ match: LibraryTextMatch) -> some View {
        Button { open(match) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "book.closed").foregroundStyle(Palette.accent)
                    Text(match.bookTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(match.locator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
                let before = (match.hasEarlierText ? "…" : "") + match.snippetBefore
                let after = match.snippetAfter + (match.hasLaterText ? "…" : "")
                Text("\(before)\(Text(match.quote).bold().foregroundStyle(Palette.accent))\(after)")
                    .font(.system(size: 16)).lineSpacing(6).lineLimit(5).multilineTextAlignment(.leading)
                if !session.expandedKeywords.isEmpty, match.matchedQuery != session.response?.query {
                    Text("扩展词 · \(match.matchedQuery)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line.opacity(0.5), lineWidth: 1)).contentShape(Rectangle())
        }.buttonStyle(ReadingQuietButtonStyle()).disabled(opening || (store.isBusy && match.bookID != store.bookID))
    }

    private func entityRow(_ match: LibraryEntityMatch) -> some View {
        Button { open(match) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.stack").font(.system(size: 18)).foregroundStyle(Palette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(match.entity.name).font(.system(size: 16, weight: .semibold))
                    Text("\(match.bookTitle) · 匹配名称：\(match.matchedName)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if !match.entity.summary.isEmpty { Text(match.entity.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line.opacity(0.5), lineWidth: 1)).contentShape(Rectangle())
        }.buttonStyle(ReadingQuietButtonStyle()).disabled(opening || (store.isBusy && match.bookID != store.bookID))
    }

    private func scheduleSearch(debounce: Bool = true) {
        let bookID = scope == "current" ? store.bookID : nil
        session.schedule(query: query, snapshots: snapshots, bookID: bookID, root: store.libraryRootURL.path, debounce: debounce)
        if scope == "current", bookID == nil { session.cancel(); session.errorMessage = "请先打开一本书，或选择整个书库。" }
    }

    private func expandSearch() {
        guard scope != "current" || store.bookID != nil else { return }
        var settings = store.settings
        settings.transportSessionID = "readingbook-search-" + UUID().uuidString
        let frozenSettings = settings, key = store.apiKey, coordinator = store.sharedAIRequests, limit = store.aiConcurrencyLimit
        session.expand { text, language in
            let run = try await coordinator.beginManagedRun(settings: frozenSettings, maximumConcurrency: limit)
            do {
                let reader = AIReader(coordinator: coordinator, lane: .foreground)
                let plan = try await reader.expandLibrarySearch(query: text, languageProfile: language, settings: frozenSettings, apiKey: key)
                run.finish(); await coordinator.endRun(run)
                return plan
            } catch {
                run.finish(); await coordinator.endRun(run)
                throw error
            }
        }
    }

    private func prepareBook(_ id: String) async -> Bool {
        guard store.bookID == id || !store.isBusy else { session.errorMessage = "请先等待当前任务结束，再切换书籍。"; return false }
        guard !store.editorDirty else { session.errorMessage = "请先保存当前文档，再从检索结果切换阅读位置。"; return false }
        if store.bookID != id { await store.selectBook(id) }
        guard !Task.isCancelled else { return false }
        guard store.bookID == id else { session.errorMessage = "无法切换书籍，请先处理当前草稿或任务。"; return false }
        guard !store.editorDirty else { session.errorMessage = "这本书恢复了上次未保存的文档草稿，请先保存草稿，再从检索结果定位。"; return false }
        return true
    }

    private func open(_ match: LibraryTextMatch) {
        if let onPrepareResultNavigation { onPrepareResultNavigation { startOpen(match) } }
        else { startOpen(match) }
    }

    private func startOpen(_ match: LibraryTextMatch) {
        guard !opening else { return }
        let root = store.libraryRootURL, owner = store.auxiliaryPresentation?.id
        let originalQuery = query, originalScope = scope
        let navigationGeneration = store.navigationGeneration + (store.bookID == match.bookID ? 0 : 1)
        opening = true
        navigationTask = Task {
            defer { opening = false }
            guard navigationIsCurrent(root: root, owner: owner, query: originalQuery, scope: originalScope),
                  await prepareBook(match.bookID),
                  store.navigationGeneration == navigationGeneration,
                  navigationIsCurrent(root: root, owner: owner, query: originalQuery, scope: originalScope), let book = store.book else { return }
            do {
                try match.validate(in: book)
                let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: match.sourceHash, unitID: match.unitID, quote: match.quote,
                                                                       prefix: match.prefix, suffix: match.suffix, in: book)
                let resolved = try ReadingExperienceRuntime.resolve(anchor, in: book)
                guard resolved.range == match.range else { throw ReadingError.invalid("原文定位不一致，请重新检索。") }
                store.navigateToUnit(match.unitID)
                if !store.readingExperienceIndex.anchors.contains(where: { $0.id == anchor.id }) { store.readingExperienceIndex.anchors.append(anchor) }
                store.focusedReadingAnchorID = anchor.id
                completeResultNavigation()
            } catch { session.errorMessage = error.localizedDescription }
        }
    }

    private func open(_ match: LibraryEntityMatch) {
        if let onPrepareResultNavigation { onPrepareResultNavigation { startOpen(match) } }
        else { startOpen(match) }
    }

    private func startOpen(_ match: LibraryEntityMatch) {
        guard !opening else { return }
        let root = store.libraryRootURL, owner = store.auxiliaryPresentation?.id
        let originalQuery = query, originalScope = scope
        let navigationGeneration = store.navigationGeneration + (store.bookID == match.bookID ? 0 : 1)
        opening = true
        navigationTask = Task {
            defer { opening = false }
            guard navigationIsCurrent(root: root, owner: owner, query: originalQuery, scope: originalScope),
                  await prepareBook(match.bookID),
                  store.navigationGeneration == navigationGeneration,
                  navigationIsCurrent(root: root, owner: owner, query: originalQuery, scope: originalScope), let book = store.book else { return }
            guard book.sourceHash == match.sourceHash, book.entities.contains(where: { $0.id == match.entity.id }) else {
                session.errorMessage = "该对象的原书版本已变化，请重新检索。"; return
            }
            store.showReadingObject(match.entity.id)
            completeResultNavigation()
        }
    }

    private func completeResultNavigation() {
        session.cancel()
        if let onNavigateToResult { onNavigateToResult() }
        else { store.route = "reader"; dismiss() }
    }
    private func navigationIsCurrent(root: URL, owner: UUID?, query originalQuery: String, scope originalScope: String) -> Bool {
        guard !Task.isCancelled, store.libraryRootURL == root, scope == originalScope,
              query.utf8.elementsEqual(originalQuery.utf8) else { return false }
        if let owner { return store.auxiliaryPresentation?.id == owner && store.auxiliaryPresentation?.kind == .search }
        return !embedded
    }
    private func close() { session.cancel(); navigationTask?.cancel(); if let onClose { onClose() } else { dismiss() } }
}
