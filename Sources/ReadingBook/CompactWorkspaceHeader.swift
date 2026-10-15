import SwiftUI

/// One compact header for workspace pages; the content keeps the remaining area.
struct CompactWorkspaceHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let actions: Actions

    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.subtitle = subtitle; self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                .layoutPriority(1)
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: ReadingLayout.groupSpacing)
            actions.controlSize(.regular).font(.system(size: 13)).frame(minHeight: ReadingLayout.controlHeight)
        }
        .padding(.horizontal, ReadingLayout.panelPadding).padding(.vertical, 8).frame(minHeight: 56)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5) }
    }
}
