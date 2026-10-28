import SwiftUI

/// Both modes stay mounted. Closing the card or changing its tab never clears a
/// question, its permission controls, a frozen companion scope or a save sheet.
struct ReaderAIPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.isReaderPanelActive) private var panelActive
    var body: some View {
        ZStack {
                ReadingCompanionPanel(showsHeader: false)
                    .environment(\.isReaderPanelActive, panelActive && store.readingCompanionTab != "chat")
                    .opacity(store.readingCompanionTab == "chat" ? 0 : 1)
                    .allowsHitTesting(store.readingCompanionTab != "chat").accessibilityHidden(store.readingCompanionTab == "chat")
                    .disabled(!store.readingCompanionVisible || store.readingCompanionTab == "chat")
                EnhancedBookChatView(embedded: true)
                    .environment(\.isReaderPanelActive, panelActive && store.readingCompanionTab == "chat")
                    .opacity(store.readingCompanionTab == "chat" ? 1 : 0)
                    .allowsHitTesting(store.readingCompanionTab == "chat").accessibilityHidden(store.readingCompanionTab != "chat")
                    .disabled(!store.readingCompanionVisible || store.readingCompanionTab != "chat")
        }.frame(minHeight: 0, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Reserve its real extent. The glass strip never covers the first
            // source sentence or the first chat answer.
            CompanionTaskStatusRow(state: store.companionProgressState, queryState: store.queryProgressState,
                bookID: store.bookID, libraryRoot: store.libraryRootURL,
                cancel: store.cancelCompanion, cancelQuery: store.cancelQuery)
        }
    }
}

/// Beside the floating title, without remounting either mode's editor.
struct ReaderAIPanelTabs: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        HStack(spacing: 2) {
            tab("伴读", value: "companion")
            tab("对话", value: "chat")
        }.padding(2).background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
    private func tab(_ title: String, value: String) -> some View {
        Button {
            store.readingCompanionTab = value
            if value != "chat" { store.queryAllowsOrganizing = false }
        } label: { Text(title).font(.system(size: 13, weight: .medium)).frame(width: ReadingCompanionToolbarMetrics.modeTabWidth, height: 32).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(store.readingCompanionTab == value ? Palette.accent : .secondary)
            .background(store.readingCompanionTab == value ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityAddTraits(store.readingCompanionTab == value ? .isSelected : [])
            .accessibilityLabel(title)
            .help(value == "companion" ? "查看当前范围的解释、译文和原文对象" : "围绕所选内容继续提问，独立于伴读生成任务")
    }
}
