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
    var body: some View {
        if let state = store.activeComponentView {
            Button { store.toggleComponentWholeBook() } label: {
                Label(state.issue ?? state.snapshot?.displayTitle ?? "跟随阅读位置", systemImage: "book")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: 210, minHeight: 34)
            }.buttonStyle(ReadingToolbarButtonStyle())
                .help(state.snapshot?.scope == .book
                    ? "本次组件显示全书已有资料；点击后跟随阅读位置。不会调用模型或更改防剧透偏好。"
                    : "本次组件沿用对话范围；点击查看全书已有资料。不会调用模型或更改防剧透偏好。")
                .accessibilityIdentifier("component-source-scope")
        }
    }
}
