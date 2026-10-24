import SwiftUI
import ReadingCore

/// Search input and results stay local to the outline; typing does not publish
/// a change to every view subscribed to the reading workspace's AppStore.
struct ReaderOutlinePanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var results: [SourceUnit] = []
    @State private var resultRequest: SearchRequest?
    @State private var searching = false
    @State private var pendingScrollID: String?
    @State private var sourceRevision = 0
    @State private var snapshotBookID: String?
    @State private var snapshotSourceHash: String?
    @State private var sourceUnits: [SourceUnit] = []

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
    private var visibleUnits: [SourceUnit] { resultRequest == request ? results : [] }
    private var isPDF: Bool { store.sourceFileURL?.pathExtension.lowercased() == "pdf" }

    var body: some View {
        let currentRequest = request
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索原文或章节", text: $query).textFieldStyle(.plain).font(.system(size: 15))
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
                        ForEach(visibleUnits) { unit in outlineRow(unit) }
                        if resultRequest != currentRequest || searching {
                            ProgressView().controlSize(.small).padding(20).accessibilityLabel("正在搜索原文")
                        } else if results.isEmpty {
                            Text("没有匹配的原文").font(.caption).foregroundStyle(.secondary).padding(20)
                        }
                    }.padding(8)
                }
                .onChange(of: store.selectedUnitID) { _, id in
                    pendingScrollID = id
                    if let id, visibleUnits.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center); pendingScrollID = nil }
                }
                .onChange(of: resultRequest) { _, _ in
                    if let id = pendingScrollID, visibleUnits.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center); pendingScrollID = nil }
                }
                .onAppear { pendingScrollID = store.selectedUnitID }
                .onChange(of: store.bookID) { _, _ in pendingScrollID = store.selectedUnitID }
            }
        }.background(Palette.surface.opacity(0.45))
            // Library reloads can replace units without incrementing the
            // project's edit revision. Observe source publication, not typing.
            .onReceive(store.$books) { refreshSource(from: $0) }
            .onChange(of: store.bookID) { _, _ in refreshSource(from: store.books) }
            .task(id: currentRequest) { await search(currentRequest) }
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
        let project = books.first { $0.id == store.bookID }
        let units = project?.units ?? []
        guard snapshotBookID != store.bookID || snapshotSourceHash != project?.sourceHash || sourceUnits != units else { return }
        snapshotBookID = store.bookID; snapshotSourceHash = project?.sourceHash
        sourceUnits = units; sourceRevision &+= 1
    }

    @MainActor private func search(_ input: SearchRequest) async {
        guard input == request, snapshotBookID == input.bookID, snapshotSourceHash == input.sourceHash else { return }
        let units = sourceUnits
        resultRequest = nil; results = []; searching = !input.query.isEmpty
        guard !input.query.isEmpty else {
            guard !Task.isCancelled, input == request else { return }
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
            guard !Task.isCancelled, input == request else { return }
            results = found; resultRequest = input; searching = false
        } catch {
            // A replacement task owns the current input and its result state.
            if !Task.isCancelled, input == request { resultRequest = input; searching = false }
        }
    }
}
