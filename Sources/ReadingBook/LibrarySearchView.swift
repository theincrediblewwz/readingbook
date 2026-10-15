import SwiftUI
import ReadingCore

/// Searches already loaded originals. It never asks AI or opens Markdown bodies.
struct LibrarySearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    /// Full-window hosts own the top island clearance. Sheets retain their
    /// suggested size; embedding must not add another 520-point minimum.
    var embedded = false
    var onClose: (() -> Void)? = nil
    @State private var query = ""
    @State private var scope = "current"
    @State private var snapshots: [LibrarySourceSnapshot] = []
    @State private var response: LibrarySearchResponse?
    @State private var searchTask: Task<Void, Never>?
    @State private var navigationTask: Task<Void, Never>?
    @State private var searchGeneration = UUID()
    @State private var searching = false
    @State private var opening = false
    @State private var errorMessage = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("书库检索").font(.system(size: 23, weight: .semibold))
                    Text("原文优先 · 离线查询已导入书籍").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("检索范围", selection: $scope) {
                    Text("本书").tag("current")
                    Text("整个书库").tag("library")
                }.labelsHidden().accessibilityLabel("检索范围").pickerStyle(.segmented).frame(width: 190)
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("关闭书库检索").keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索原文、人物、概念或别名", text: $query).font(.system(size: 16)).textFieldStyle(.plain)
                    .focused($queryFocused).onSubmit { scheduleSearch(debounce: false) }
                if !query.isEmpty {
                    Button { query = ""; queryFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("清空检索词")
                }
            }.padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 52).readingGlass(radius: 16)
            HStack(spacing: 8) {
                if searching { ProgressView().controlSize(.small) }
                Text(status).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 0)
            }.frame(minHeight: 24)
            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            results.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24).background(Palette.canvas).controlSize(.large)
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
        .onAppear { if store.bookID == nil { scope = "library" }; queryFocused = true; scheduleSearch() }
        .onDisappear { searchTask?.cancel(); navigationTask?.cancel(); searchGeneration = UUID() }
    }

    private var status: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "只查询当前已载入的原书和对象名称，不读取笔记正文，也不调用 AI。" }
        if searching { return "正在原文中查找…" }
        guard let response else { return "输入后自动查找。" }
        let bound = response.bounded ? " · 已达显示上限，可增加检索词缩小范围" : ""
        return "原文 \(response.matches.count) 处 · 对象 \(response.entityMatches.count) 项 · 范围 \(response.searchedBookCount) 本\(bound)"
    }

    @ViewBuilder private var results: some View {
        if let response, !response.matches.isEmpty || !response.entityMatches.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
        } else if !searching, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response != nil {
            ContentUnavailableView("没有找到匹配原文", systemImage: "text.magnifyingglass", description: Text("试试原书中的词语或别名。未识别扫描页须先完成 OCR；这里不会用 AI 猜补结果。"))
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
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).readingGlass(radius: 16).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(opening || store.isBusy)
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
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).readingGlass(radius: 16).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(opening || store.isBusy)
    }

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let generation = UUID(); searchGeneration = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = snapshots
        let bookID = scope == "current" ? store.bookID : nil
        response = nil; errorMessage = ""
        guard !text.isEmpty else { searching = false; return }
        if scope == "current", bookID == nil { searching = false; errorMessage = "请先打开一本书，或选择整个书库。"; return }
        searching = true
        searchTask = Task {
            do {
                if debounce { try await Task.sleep(nanoseconds: 240_000_000) }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) { try LibraryTextSearch.search(query: text, snapshots: input, bookID: bookID) }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard searchGeneration == generation else { return }
                response = result; searching = false
            } catch is CancellationError {
                // A later input owns the visible progress/result state.
            } catch {
                guard searchGeneration == generation else { return }
                errorMessage = error.localizedDescription; searching = false
            }
        }
    }

    private func prepareBook(_ id: String) async -> Bool {
        guard !store.isBusy else { errorMessage = "请先等待当前任务结束。"; return false }
        guard !store.editorDirty else { errorMessage = "请先保存当前文档，再从检索结果切换阅读位置。"; return false }
        if store.bookID != id { await store.selectBook(id) }
        guard !Task.isCancelled else { return false }
        guard store.bookID == id else { errorMessage = "无法切换书籍，请先处理当前草稿或任务。"; return false }
        guard !store.editorDirty else { errorMessage = "这本书恢复了上次未保存的文档草稿，请先保存草稿，再从检索结果定位。"; return false }
        return true
    }

    private func open(_ match: LibraryTextMatch) {
        guard !opening else { return }
        opening = true
        navigationTask = Task {
            defer { opening = false }
            guard await prepareBook(match.bookID), let book = store.book else { return }
            do {
                try match.validate(in: book)
                store.navigateToUnit(match.unitID)
                let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: match.sourceHash, unitID: match.unitID, quote: match.quote,
                                                                       prefix: match.prefix, suffix: match.suffix, in: book)
                let resolved = try ReadingExperienceRuntime.resolve(anchor, in: book)
                guard resolved.range == match.range else { throw ReadingError.invalid("原文定位不一致，请重新检索。") }
                if !store.readingExperienceIndex.anchors.contains(where: { $0.id == anchor.id }) { store.readingExperienceIndex.anchors.append(anchor) }
                store.focusedReadingAnchorID = anchor.id; store.route = "reader"
                close()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func open(_ match: LibraryEntityMatch) {
        guard !opening else { return }
        opening = true
        navigationTask = Task {
            defer { opening = false }
            guard await prepareBook(match.bookID), let book = store.book else { return }
            guard book.sourceHash == match.sourceHash, book.entities.contains(where: { $0.id == match.entity.id }) else {
                errorMessage = "该对象的原书版本已变化，请重新检索。"; return
            }
            store.route = "reader"
            store.showReadingObject(match.entity.id)
            close()
        }
    }

    private func close() { searchTask?.cancel(); if let onClose { onClose() } else { dismiss() } }
}
