import SwiftUI
import ReadingCore

/// Search input and results stay local to the outline; typing does not publish
/// a change to every view subscribed to the reading workspace's AppStore.
struct ReaderOutlinePanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.isReaderPanelActive) private var panelActive
    @Binding var bookmarksOnly: Bool
    @State private var query = ""
    @State private var results: [SourceUnit] = []
    @State private var resultRequest: SearchRequest?
    @State private var searching = false
    @State private var pendingScrollID: String?
    @State private var sourceRevision = 0
    @State private var snapshotBookID: String?
    @State private var snapshotSourceHash: String?
    @State private var sourceUnits: [SourceUnit] = []
    @StateObject private var outline = ReaderBookOutlineState()
    @State private var collapsed = Set<String>()
    @State private var outlineRetry = 0
    @State private var sourceRefreshTask: Task<Void, Never>?
    @State private var sourceRefreshSerial = 0
    @State private var outlineProgressID: UUID?
    @State private var outlineProgressOwner: String?

    private struct SearchRequest: Hashable, Sendable {
        let bookID: String?
        let sourceHash: String?
        let revision: Int
        let query: String
    }
    private var request: SearchRequest {
        SearchRequest(bookID: store.bookID, sourceHash: store.book?.sourceHash,
                      revision: sourceRevision, query: query)
    }
    private var visibleUnits: [SourceUnit] {
        guard panelActive, resultRequest == request else { return [] }
        guard bookmarksOnly else { return results }
        let bookmarkedIDs = Set(store.book?.bookmarks ?? [])
        return results.filter { bookmarkedIDs.contains($0.id) }
    }
    private var isPDF: Bool { store.sourceFileURL?.pathExtension.lowercased() == "pdf" }
    private var outlineOwner: String {
        [store.libraryRootURL.path, store.bookID ?? "", store.book?.sourceHash ?? "", store.sourceFileURL?.path ?? "", String(sourceRevision), String(outlineRetry), store.pdfUnlockedBookIDs.contains(store.bookID ?? "") ? "unlocked" : "locked"].joined(separator: "|")
    }
    private var activeSearchRequest: SearchRequest? {
        panelActive && (!isPDF || bookmarksOnly || !query.isEmpty) ? request : nil
    }
    private var activeOutlineOwner: String? { panelActive ? outlineOwner : nil }
    private var outlineEntries: [BookOutlineEntry] {
        guard panelActive else { return [] }
        if isPDF {
            guard outline.isCurrent(owner: outlineOwner) else { return [] }
            return outline.original.isEmpty ? outline.generated?.entries ?? [] : outline.original
        }
        var seen = Set<String>()
        return sourceUnits.compactMap { unit in
            guard seen.insert(unit.chapter).inserted else { return nil }
            return BookOutlineEntry(id: unit.id, title: unit.chapter, page: unit.page)
        }
    }
    private struct OutlineRow: Identifiable {
        let entry: BookOutlineEntry
        let hasChildren: Bool
        var id: String { entry.id }
    }
    private var visibleOutline: [OutlineRow] {
        let entries = outlineEntries
        var result: [OutlineRow] = [], hiddenBelow: Int?
        for (index, entry) in entries.enumerated() {
            if let level = hiddenBelow {
                if entry.level > level { continue }
                hiddenBelow = nil
            }
            result.append(OutlineRow(entry: entry, hasChildren: index + 1 < entries.count && entries[index + 1].level > entry.level))
            if collapsed.contains(entry.id) { hiddenBelow = entry.level }
        }
        return result
    }
    private var selectedOutlineID: String? {
        guard panelActive else { return nil }
        let entries = outlineEntries
        if let project = store.book, let position = store.chapterReadingAnchor(in: project), let offset = position.utf16Location {
            if let match = entries.last(where: { entry in
                entry.anchor?.unitID == position.unitID && (entry.anchor?.utf16Location ?? Int.max) <= offset
            }) { return match.id }
        }
        guard isPDF, let page = store.selectedUnit?.page else {
            return entries.first(where: { $0.title == store.selectedUnit?.chapter })?.id
        }
        var selected: BookOutlineEntry?
        for entry in entries {
            guard let target = entry.page, target <= page else { continue }
            if target >= (selected?.page ?? 0) { selected = entry }
        }
        return selected?.id
    }

    var body: some View {
        let currentRequest = request
        let currentOutlineID = selectedOutlineID
        VStack(spacing: 0) {
            Picker("阅读导航内容", selection: $bookmarksOnly) {
                Text("目录").tag(false); Text("书签").tag(true)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 12)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "magnifyingglass").readingSearchIcon()
                TextField("搜索原文或章节", text: $query).readingSearchInput()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).frame(width: 44, height: 44).accessibilityLabel("清空原文搜索")
                }
            }.padding(.horizontal, 14).frame(minHeight: 46)
                .background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if isPDF && !bookmarksOnly && query.isEmpty {
                            directoryHeader
                            ForEach(visibleOutline) { row in chapterRow(row, selected: currentOutlineID == row.id) }
                        } else {
                            ForEach(visibleUnits) { unit in outlineRow(unit) }
                        }
                        if (!query.isEmpty || bookmarksOnly) && (resultRequest != currentRequest || searching) {
                            ProgressView().controlSize(.small).padding(20).accessibilityLabel("正在搜索原文")
                        } else if (!query.isEmpty || bookmarksOnly) && visibleUnits.isEmpty {
                            Text(bookmarksOnly ? (query.isEmpty ? "还没有书签" : "没有匹配的书签") : "没有匹配的原文").font(.system(size: 14)).foregroundStyle(.secondary).padding(24)
                        }
                    }.padding(8)
                }
                .onChange(of: store.selectedUnitID) { _, id in
                    if !bookmarksOnly && query.isEmpty, let selectedOutlineID { proxy.scrollTo(selectedOutlineID, anchor: .center); return }
                    pendingScrollID = id
                    if let id, visibleUnits.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center); pendingScrollID = nil }
                }
                .onChange(of: resultRequest) { _, _ in
                    if let id = pendingScrollID, visibleUnits.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center); pendingScrollID = nil }
                }
                .onChange(of: currentOutlineID) { _, id in
                    if !bookmarksOnly && query.isEmpty, let id { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear { pendingScrollID = store.selectedUnitID }
                .onChange(of: store.bookID) { _, _ in pendingScrollID = store.selectedUnitID }
            }
        }.background(Palette.surface.opacity(0.45))
            // Library reloads can replace units without incrementing the
            // project's edit revision. Observe source publication, not typing.
            .onReceive(store.$books) { books in
                guard panelActive else { return }
                refreshSource(from: books)
                if outline.isCurrent(owner: outlineOwner) { outline.refreshDerived(from: books.first { $0.id == store.bookID }) }
            }
            .onChange(of: store.bookID) { _, _ in refreshSource(from: store.books) }
            .onChange(of: panelActive) { _, active in
                if active { refreshSource(from: store.books) }
                else { suspendPreparation() }
            }
            .task(id: activeSearchRequest) {
                guard !Task.isCancelled, let input = activeSearchRequest else { return }
                await search(input)
            }
            .task(id: activeOutlineOwner) {
                guard !Task.isCancelled, let owner = activeOutlineOwner, panelActive else { return }
                if outline.isCurrent(owner: owner), outline.phase == .ready {
                    outline.refreshDerived(from: store.book)
                    return
                }
                if !isPDF {
                    collapsed = []
                    await outline.load(owner: owner, project: nil, url: nil, store: store)
                    return
                }
                let progressID = UUID(), progressOwner = store.libraryRootURL.path + "|" + (store.bookID ?? "")
                finishOutlineProgress()
                outlineProgressID = progressID; outlineProgressOwner = progressOwner
                store.readingPreparationState.apply(.started(progressID, ReadingPreparationProgress(phase: .outline)), lane: "outline", owner: progressOwner)
                defer {
                    if outlineProgressID == progressID { finishOutlineProgress() }
                }
                if !outline.isCurrent(owner: owner) { collapsed = [] }
                // Also reset/cancel the PDF-owned task on a switch to text or
                // EPUB. A guard-return here leaves the old request alive.
                await outline.load(owner: owner, project: isPDF ? store.book : nil,
                    url: isPDF ? store.sourceFileURL : nil, store: store)
                guard !Task.isCancelled, panelActive, activeOutlineOwner == owner else { return }
                outline.refreshDerived(from: store.book)
            }
            .onDisappear(perform: suspendPreparation)
    }

    @ViewBuilder private var directoryHeader: some View {
        if isPDF {
            switch outline.phase {
            case .idle, .loading:
                ProgressView("读取原书目录…").controlSize(.small).padding(20)
            case .locked:
                VStack(spacing: 10) {
                    Text("解锁原书后显示目录。").font(.system(size: 14)).foregroundStyle(.secondary)
                    Button("解锁原书") {
                        Task {
                            guard let id = store.bookID, let url = store.sourceFileURL else { return }
                            do { _ = try await store.ensurePDFSession(bookID: id, sourceURL: url) }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }.buttonStyle(ReadingToolbarButtonStyle())
                }.padding(20)
            case .failed:
                VStack(spacing: 10) {
                    Text(outline.message ?? "原书目录暂时无法读取。").font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("重试") { outlineRetry &+= 1 }.buttonStyle(ReadingToolbarButtonStyle())
                }.padding(16)
            case .ready:
                if outline.original.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(outline.generated == nil ? "原书未附目录" : "AI 整理的目录").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        if outline.generating {
                            ReaderOutlineGenerationProgress(state: outline.progressState, pause: { outline.cancel() })
                            if let generated = outline.generated { Text("已检查 \(generated.scannedUnitCount)/\(generated.totalUnitCount) 个原文单元").font(.caption).foregroundStyle(.secondary) }
                        } else if outline.generated?.complete != true && (outline.remainingRequestCount > 0 || outline.generated != nil) {
                            Button { outline.generate(store: store) } label: { Label(outline.generated == nil ? "用 AI 整理目录" : "继续整理目录", systemImage: "sparkles") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.storageState.working)
                            Text(outline.remainingRequestCount > 0 ? "本轮最多 \(min(outline.remainingRequestCount, store.settings.maxRequestsPerRun)) 次请求，可暂停继续。" : "核对剩余空白页面，不会发送请求。").font(.caption2).foregroundStyle(.secondary)
                        } else if outline.generated == nil { Text("尚无可读标题，可先识别页面。").font(.caption).foregroundStyle(.secondary) }
                        if let message = outline.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func chapterRow(_ row: OutlineRow, selected: Bool) -> some View {
        let entry = row.entry
        return HStack(alignment: .top, spacing: 6) {
            if row.hasChildren {
                Button { if !collapsed.insert(entry.id).inserted { collapsed.remove(entry.id) } } label: {
                    Image(systemName: collapsed.contains(entry.id) ? "chevron.right" : "chevron.down").font(.system(size: 11)).frame(width: 22, height: 24)
                }.buttonStyle(.plain).accessibilityLabel(collapsed.contains(entry.id) ? "展开章节" : "收起章节")
            } else { Color.clear.frame(width: 22, height: 24) }
            Button {
                store.navigateToChapter(entry)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if let page = entry.page { Text(String(page)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isPDF && entry.page == nil)
        }.padding(.leading, CGFloat(min(8, entry.level)) * 12).padding(.trailing, 12).padding(.vertical, 10)
            .background(selected ? Palette.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .id(entry.id)
    }

    private func outlineRow(_ unit: SourceUnit) -> some View {
        let status = store.book?.coverage[unit.id]?.status ?? .pending
        return Button { store.navigateToUnit(unit.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: status == .completed ? "checkmark.circle.fill" : status == .needsReview || unit.warning != nil ? "exclamationmark.circle" : "circle")
                    .font(.caption).foregroundStyle(status == .completed ? Palette.accent : .secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(isPDF ? "第 \(unit.page ?? 1) 页" : unit.chapter).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("行 \(unit.lineStart)–\(unit.lineEnd)").font(.caption2).foregroundStyle(.secondary)
                    Text(unit.text.isEmpty ? "尚未识别文本" : String(unit.text.prefix(64)).replacingOccurrences(of: "\n", with: " "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if store.book?.bookmarks.contains(unit.id) == true { Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Palette.copper) }
            }.padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .background(store.selectedUnitID == unit.id ? Palette.accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).id(unit.id).accessibilityLabel("\(unit.locator)，点击定位原文")
    }

    private func refreshSource(from books: [BookProject]) {
        guard panelActive else { return }
        let project = books.first { $0.id == store.bookID }
        let units = project?.units ?? []
        sourceRefreshTask?.cancel(); sourceRefreshSerial &+= 1
        if snapshotBookID != store.bookID || snapshotSourceHash != project?.sourceHash {
            snapshotBookID = store.bookID; snapshotSourceHash = project?.sourceHash
            sourceUnits = units; sourceRevision &+= 1; return
        }
        // A copied immutable Array can prove identity in O(1). Re-decoded or
        // edited arrays need a literal comparison in a worker: Swift's == alone
        // would miss canonically equivalent but byte-different OCR updates.
        let identical = sourceUnits.withUnsafeBufferPointer { old in
            units.withUnsafeBufferPointer { new in old.count == new.count && old.baseAddress == new.baseAddress }
        }
        guard !identical else { return }
        let previous = sourceUnits, serial = sourceRefreshSerial, bookID = store.bookID, hash = project?.sourceHash, root = store.libraryRootURL
        sourceRefreshTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> Bool in
                guard previous == units else { return false }
                for (index, pair) in zip(previous, units).enumerated() {
                    if index.isMultiple(of: 64) { try Task.checkCancellation() }
                    if !pair.0.text.utf8.elementsEqual(pair.1.text.utf8)
                        || !pair.0.chapter.utf8.elementsEqual(pair.1.chapter.utf8)
                        || !pair.0.id.utf8.elementsEqual(pair.1.id.utf8)
                        || !(pair.0.warning ?? "").utf8.elementsEqual((pair.1.warning ?? "").utf8) { return false }
                }
                return true
            }
            do {
                let equal = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, sourceRefreshSerial == serial, store.libraryRootURL == root, store.bookID == bookID, store.book?.sourceHash == hash else { return }
                if !equal { sourceUnits = units; sourceRevision &+= 1 }
            } catch { /* A newer source publication owns the replacement check. */ }
        }
    }

    @MainActor private func search(_ input: SearchRequest) async {
        guard panelActive, !Task.isCancelled, input == request, snapshotBookID == input.bookID, snapshotSourceHash == input.sourceHash else { return }
        if resultRequest == input { return }
        let units = sourceUnits
        resultRequest = nil; results = []; searching = !input.query.isEmpty
        guard !input.query.isEmpty else {
            guard panelActive, !Task.isCancelled, input == request else { return }
            results = units; resultRequest = input; searching = false; return
        }
        do {
            try await Task.sleep(nanoseconds: 180_000_000)
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) { () throws -> [SourceUnit] in
                var matches: [SourceUnit] = []
                for (index, unit) in units.enumerated() {
                    if index.isMultiple(of: 64) { try Task.checkCancellation() }
                    if unit.chapter.localizedCaseInsensitiveContains(input.query)
                        || unit.text.localizedCaseInsensitiveContains(input.query)
                        || unit.locator.localizedCaseInsensitiveContains(input.query) { matches.append(unit) }
                }
                try Task.checkCancellation()
                return matches
            }
            let found = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard panelActive, !Task.isCancelled, input == request else { return }
            results = found; resultRequest = input; searching = false
        } catch {
            // A replacement task owns the current input and its result state.
            if panelActive, !Task.isCancelled, input == request { resultRequest = input; searching = false }
        }
    }
    private func finishOutlineProgress() {
        guard let id = outlineProgressID, let owner = outlineProgressOwner else { return }
        outlineProgressID = nil; outlineProgressOwner = nil
        guard owner == store.libraryRootURL.path + "|" + (store.bookID ?? "") else { return }
        store.readingPreparationState.apply(.finished(id), lane: "outline", owner: owner)
    }
    private func suspendPreparation() {
        outline.cancel(); sourceRefreshTask?.cancel(); sourceRefreshTask = nil; sourceRefreshSerial &+= 1
        searching = false; finishOutlineProgress()
    }
}

private struct ReaderOutlineGenerationProgress: View {
    @ObservedObject var state: AIProgressObservableState
    let pause: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { ProgressView().controlSize(.small); Text(state.value.phaseTitle).font(.system(size: 13)); Spacer(); Button("暂停", action: pause).buttonStyle(.plain) }
            if state.value.reasoningCharacters > 0 || state.value.answerCharacters > 0 {
                Text("思考 \(state.value.reasoningCharacters.formatted()) · 输出 \(state.value.answerCharacters.formatted()) 字符").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
