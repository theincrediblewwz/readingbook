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
        HStack(spacing: 10) {
            Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                .layoutPriority(1)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            actions.controlSize(.small).font(.subheadline)
        }
        .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 44)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5) }
    }
}
