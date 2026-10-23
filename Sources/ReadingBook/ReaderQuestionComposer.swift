import SwiftUI
import ReadingCore

/// Reader questions use the same read-only scope boundary as the full chat.
/// Sending continues in chat, where exact answer selections and merged saving
/// remain available, rather than introducing a second answer storage path.
struct ReaderQuestionComposer: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    @State private var question = ""
    @Binding var isExpanded: Bool
    var compact = false
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            composer
                .opacity(isExpanded ? 1 : 0).scaleEffect(isExpanded || reduceMotion ? 1 : 0.94, anchor: .bottomTrailing)
                .allowsHitTesting(isExpanded).accessibilityHidden(!isExpanded)
            if !isExpanded {
                Button { isExpanded = true; inputFocused = true } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22, weight: .medium)).foregroundStyle(Palette.accent)
                        .frame(width: 58, height: 58)
                        .overlay(alignment: .topTrailing) {
                            if !question.isEmpty { Circle().fill(Palette.accent).frame(width: 8, height: 8).padding(5) }
                        }
                }.buttonStyle(.plain).readingGlass(radius: 29, interactive: true)
                    .help(question.isEmpty ? "问 AI" : "继续未发送的问题").accessibilityLabel("展开 AI 提问")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }.frame(height: isExpanded ? nil : 58, alignment: .bottomTrailing)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: isExpanded)
            .onChange(of: store.bookID) { _, _ in question = ""; isExpanded = false }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                QueryScopeControl()
                QueryAttachmentsControl()
                Spacer(minLength: 0)
                Button { store.requestedWorkspaceRoute = "query" } label: { Image(systemName: "bubble.left.and.bubble.right") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("打开与书对话")
                Button { inputFocused = false; isExpanded = false } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("缩为悬浮按钮，保留草稿").accessibilityLabel("收起 AI 提问")
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("围绕所选内容，问一个问题…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(compact ? 1...2 : 1...3)
                    .frame(minHeight: 36).focused($inputFocused).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 26, height: 28) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.isBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canUseQueryScope(store.queryScope))
                    .help("按所选范围提问").accessibilityLabel("发送问题")
            }.padding(.bottom, 4)
        }.padding(.horizontal, 15).padding(.vertical, compact ? 5 : 8)
            .readingGlass(radius: 22)
    }
    private func send() {
        guard !store.isBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // ask synchronously freezes the boundary before this view can navigate.
        store.ask(question)
        if store.isBusy { question = ""; store.requestedWorkspaceRoute = "query" }
    }
}
