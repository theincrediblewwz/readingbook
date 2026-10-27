import SwiftUI

/// Both modes stay mounted. Closing the card or changing its tab never clears a
/// question, its permission controls, a frozen companion scope or a save sheet.
struct ReaderAIPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.isReaderPanelActive) private var panelActive
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                tab("伴读", value: "companion")
                tab("对话", value: "chat")
            }.padding(3).background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            ReadingPreparationIndicator(state: store.readingPreparationState)
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
        }
    }
    private func tab(_ title: String, value: String) -> some View {
        Button {
            store.readingCompanionTab = value
            if value != "chat" { store.queryAllowsOrganizing = false }
        } label: { Text(title).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(store.readingCompanionTab == value ? Palette.accent : .secondary)
            .background(store.readingCompanionTab == value ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityAddTraits(store.readingCompanionTab == value ? .isSelected : [])
    }
}
