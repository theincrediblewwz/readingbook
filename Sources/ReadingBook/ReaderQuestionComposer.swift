import SwiftUI
import ReadingCore

/// Reader questions use the same read-only scope boundary as the full chat.
/// Sending continues in chat, where exact answer selections and merged saving
/// remain available, rather than introducing a second answer storage path.
struct ReaderQuestionComposer: View {
    @EnvironmentObject private var store: AppStore
    @State private var question = ""
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                QueryScopeControl()
                Text(store.isBusy ? store.lastQuestionContext : store.queryScopePreview)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button { store.requestedWorkspaceRoute = "query" } label: { Image(systemName: "bubble.left.and.bubble.right") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("打开与书对话")
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("围绕所选内容，问一个问题…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(compact ? 1...2 : 1...3)
                    .frame(minHeight: 36).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 26, height: 28) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.isBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canUseQueryScope(store.queryScope))
                    .help("按所选范围提问").accessibilityLabel("发送问题")
            }.padding(.bottom, 4)
        }.padding(.horizontal, 15).padding(.vertical, compact ? 5 : 8)
            .readingGlass(radius: 22).frame(maxWidth: 760)
            .onChange(of: store.bookID) { _, _ in question = "" }
    }
    private func send() {
        guard !store.isBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // ask synchronously freezes the boundary before this view can navigate.
        store.ask(question)
        if store.isBusy { question = ""; store.requestedWorkspaceRoute = "query" }
    }
}
