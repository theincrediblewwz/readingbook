import SwiftUI
import ReadingCore

/// One window's source choice, not a saved copy of the component or its facts.
struct ReadingComponentViewState {
    let id = UUID()
    let root: URL
    let bookID: String
    let sourceHash: String
    let route: String
    let snapshot: ReadingQuerySnapshot?
    let context: ReadingContext?
    var projection: BookProject?
    var issue: String?

    @MainActor func owns(_ store: AppStore) -> Bool {
        root == store.libraryRootURL && bookID == store.bookID
    }
}

/// Remember a source choice, never a second copy of its projected book. Leaving
/// a component still restores the reader boundary; reopening a wider range is
/// an explicit, source-validated action by the reader.
struct ReadingComponentSourceChoice {
    let root: URL
    let bookID: String
    let sourceHash: String
    let route: String
    let snapshot: ReadingQuerySnapshot
    let context: ReadingContext?
    @MainActor func owns(_ store: AppStore) -> Bool {
        root == store.libraryRootURL && bookID == store.bookID && sourceHash == store.book?.sourceHash && route == store.route
    }
}

@MainActor extension AppStore {
    var activeComponentView: ReadingComponentViewState? {
        guard let state = readingComponentView, state.owns(self), state.route == route else { return nil }
        return state
    }
    var componentDataScopeID: UUID? { activeComponentView?.id }
    var componentDataBook: BookProject? {
        guard let state = activeComponentView, state.snapshot != nil else { return book }
        return state.projection
    }
    var componentReadingContext: ReadingContext { activeComponentView?.context ?? currentReadingContext }
    // An explicit question scope has already sliced the shared data. Applying
    // the reader's optional current-page filter again would silently shrink it.
    var componentUsesCurrentContext: Bool { activeComponentView?.snapshot == nil && readingScopeCurrent }
    var componentSpatialScopeTitle: String {
        activeComponentView?.snapshot?.displayTitle ?? (readingScopeCurrent ? "当前原文" : "全书关系")
    }
    var restorableComponentSource: ReadingComponentSourceChoice? {
        lastReadingComponentSource.flatMap { $0.owns(self) ? $0 : nil }
    }
    var componentSourceControlTitle: String {
        activeComponentView?.issue ?? activeComponentView?.snapshot?.displayTitle ?? "跟随阅读位置"
    }
    func followReaderComponentSource() {
        readingComponentView = nil; readingContextCacheKey = nil
    }
    func restoreComponentSource() {
        guard let choice = restorableComponentSource else { return }
        do { try installComponentView(route: route, snapshot: choice.snapshot, context: choice.context) }
        catch { activity = "上次范围已失效，请重新选择范围。" }
    }
    func showWholeBookComponentSource() {
        guard let book else { return }
        do { try installComponentView(route: route, snapshot: .freeze(scope: .book, in: book), context: nil) }
        catch { activity = error.localizedDescription }
    }
    func toggleComponentSpatialScope() {
        if activeComponentView?.snapshot != nil { toggleComponentWholeBook() }
        else { readingScopeCurrent.toggle() }
    }

    func installComponentView(route: String, snapshot: ReadingQuerySnapshot?, context: ReadingContext?) throws {
        guard let book else { throw ReadingError.invalid("请先打开一本书。") }
        let projection = try snapshot.map { try ReadingComponentProjection.project($0, in: book) }
        readingContextCacheKey = nil
        readingComponentView = .init(root: libraryRootURL, bookID: book.id, sourceHash: book.sourceHash,
            route: route, snapshot: snapshot, context: context, projection: projection)
        if let snapshot {
            lastReadingComponentSource = .init(root: libraryRootURL, bookID: book.id, sourceHash: book.sourceHash,
                route: route, snapshot: snapshot, context: context)
        }
    }

    func refreshComponentData(_ project: BookProject) {
        guard var state = readingComponentView, state.root == libraryRootURL, state.bookID == project.id else { return }
        guard let snapshot = state.snapshot else { return }
        do { state.projection = try ReadingComponentProjection.project(snapshot, in: project); state.issue = nil }
        catch { state.projection = nil; state.issue = "原文已更新，请重新选择查看范围。" }
        readingContextCacheKey = nil
        readingComponentView = state
    }

    func toggleComponentWholeBook() {
        guard let state = activeComponentView, let book else { return }
        do {
            let snapshot = try state.snapshot?.scope == .book ? nil : ReadingQuerySnapshot.freeze(scope: .book, in: book)
            try installComponentView(route: state.route, snapshot: snapshot, context: nil)
        } catch { activity = error.localizedDescription }
    }
}

struct ReadingComponentScopeControl: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingChoices = false
    var body: some View {
            Button { showingChoices.toggle() } label: {
                Label(store.componentSourceControlTitle, systemImage: "book")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: 210, minHeight: 34)
            }.buttonStyle(ReadingToolbarButtonStyle())
                .help(store.activeComponentView?.snapshot == nil
                    ? "当前按阅读位置和防剧透设置显示。点击可恢复上次范围或查看全书已有资料；不会调用模型。"
                    : "本次组件沿用所选范围。点击更换查看范围；不会改写资料或防剧透偏好。")
                .accessibilityIdentifier("component-source-scope")
                .popover(isPresented: $showingChoices, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        sourceButton("跟随阅读位置", icon: "book", help: "回到阅读器原有的范围和防剧透边界。") { store.followReaderComponentSource() }
                        if store.activeComponentView?.snapshot == nil, let previous = store.restorableComponentSource {
                            sourceButton("恢复上次查看范围", icon: "arrow.uturn.backward", help: previous.snapshot.displayTitle) { store.restoreComponentSource() }
                        }
                        Divider().padding(.vertical, 4)
                        sourceButton("全书已有资料", icon: "books.vertical", help: "仅更改本窗口显示范围，不重新分析，也不修改防剧透偏好。") { store.showWholeBookComponentSource() }
                    }.padding(14).frame(width: 280)
                }
    }
    private func sourceButton(_ title: String, icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button { action(); showingChoices = false } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 8)
        }.buttonStyle(ReadingQuietButtonStyle()).help(help)
    }
}
