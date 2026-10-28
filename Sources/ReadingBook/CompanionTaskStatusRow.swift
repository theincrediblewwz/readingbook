import SwiftUI

/// One compact strip for both independent foreground tasks. Expansion lives in
/// the title, so an idle workspace never needs an otherwise empty status row.
/// The host reserves its extent above the mounted content, leaving text visible.
struct CompanionTaskStatusRow: View {
    @ObservedObject var state: AIProgressObservableState
    @ObservedObject var queryState: AIProgressObservableState
    let bookID: String?
    let libraryRoot: URL
    let cancel: () -> Void
    let cancelQuery: () -> Void
    @State private var details: Lane?
    private enum Lane: String, Identifiable { case companion, query; var id: String { rawValue } }
    private func running(_ value: AIProgressPresentationState) -> Bool {
        value.isRunning && value.bookID == bookID && value.libraryRoot == libraryRoot
    }
    var body: some View {
        if running(state.value) || running(queryState.value) {
        HStack(spacing: 6) {
            if running(state.value) { status("伴读", state: state, lane: .companion, cancel: cancel) }
            if running(queryState.value) { status("对话", state: queryState, lane: .query, cancel: cancelQuery) }
        }.frame(height: 32)
            .padding(.leading, 10).padding(.trailing, 4)
            .background(Palette.surface.opacity(0.82), in: Capsule())
            .overlay { Capsule().strokeBorder(Palette.line.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false) }
            .sheet(item: $details) { lane in
                switch lane {
                case .companion: AIRequestHistoryView(state: state)
                case .query: AIRequestHistoryView(state: queryState)
                }
            }
            .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 4)
        }
    }
    private func status(_ title: String, state: AIProgressObservableState, lane: Lane, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button { details = lane } label: {
                HStack(spacing: 5) {
                    Circle().fill(Palette.accent.opacity(0.7)).frame(width: 4, height: 4)
                    Text("\(title) · \(state.value.phaseTitle)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(title)：\(state.value.phaseTitle)。点击查看请求详情。")
                .accessibilityLabel("\(title) · \(state.value.phaseTitle)；查看请求详情")
            Button(action: cancel) { Image(systemName: "pause").font(.system(size: 11)).frame(width: 28, height: 32) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("只停止这次\(title)，其他AI任务继续").accessibilityLabel("停止这次\(title)")
        }.frame(maxWidth: .infinity)
    }
}
