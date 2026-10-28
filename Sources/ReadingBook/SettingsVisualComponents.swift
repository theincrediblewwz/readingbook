import SwiftUI

/// Explicit button surfaces for settings only. Reading chrome retains its
/// existing toolbar style and does not inherit these denser form controls.
struct SettingsActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: ManagementControlMetrics.fontSize, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: ManagementControlMetrics.height)
            .foregroundStyle(prominent ? (scheme == .dark ? Palette.canvas : Color.white) : Palette.ink)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Palette.accent : Palette.paper)
                    .overlay {
                        if !prominent, hovered || configuration.isPressed {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Palette.accent.opacity(configuration.isPressed ? 0.12 : 0.045))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(prominent ? Palette.accent : Palette.ink.opacity(hovered && enabled ? 0.35 : 0.22), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Palette.ink.opacity(!prominent && enabled ? 0.06 : 0), radius: 1, y: 1)
            .opacity(enabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}

struct SettingsContentGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false)
            }
    }
}

struct SettingsGroupSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 3)
            SettingsContentGroup(content: content)
        }
    }
}

struct SettingsGroupDivider: View {
    var body: some View { Divider().overlay(Palette.line).padding(.horizontal, 16) }
}

/// This uses one live action hierarchy at every width; responsive sizing never
/// constructs a second set of native buttons or menus to probe their fit.
struct SettingsResponsiveActionLayout: Layout {
    var minimumLeadingWidth: CGFloat = 170
    var spacing: CGFloat = 16
    private let stackedSpacing: CGFloat = 12

    init(minimumLeadingWidth: CGFloat = 170, spacing: CGFloat = 16) {
        self.minimumLeadingWidth = minimumLeadingWidth; self.spacing = spacing
    }

    private func dimensions(_ width: CGFloat?, _ subviews: Subviews) -> (width: CGFloat, height: CGFloat, leading: CGSize, action: CGSize, inline: Bool) {
        guard subviews.count == 2 else { return (max(0, width ?? 0), 0, .zero, .zero, false) }
        let action = subviews[1].sizeThatFits(.unspecified)
        let intrinsic = subviews[0].sizeThatFits(.unspecified).width + spacing + action.width
        let available = max(0, width.flatMap { $0.isFinite ? $0 : nil } ?? intrinsic)
        let inline = available >= minimumLeadingWidth + spacing + action.width
        let leading = subviews[0].sizeThatFits(ProposedViewSize(width: inline ? max(0, available - spacing - action.width) : available, height: nil))
        let height = inline ? max(leading.height, action.height) : leading.height + stackedSpacing + action.height
        return (available, height, leading, action, inline)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let value = dimensions(proposal.width, subviews)
        return CGSize(width: value.width, height: value.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let value = dimensions(bounds.width, subviews)
        let leadingWidth = value.inline ? max(0, bounds.width - spacing - value.action.width) : bounds.width
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (value.inline ? (value.height - value.leading.height) / 2 : 0)),
            anchor: .topLeading, proposal: ProposedViewSize(width: leadingWidth, height: value.leading.height))
        subviews[1].place(at: CGPoint(x: bounds.maxX - value.action.width, y: bounds.minY + (value.inline ? (value.height - value.action.height) / 2 : value.leading.height + stackedSpacing)),
            anchor: .topLeading, proposal: ProposedViewSize(value.action))
    }
}

struct SettingsActionRow<Action: View>: View {
    let title: String
    let detail: String
    var icon: String? = nil
    @ViewBuilder var action: () -> Action
    var body: some View {
        SettingsResponsiveActionLayout {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let icon { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18) }
                    Text(title).font(.system(size: 14, weight: .medium))
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            action().fixedSize(horizontal: true, vertical: false)
        }.padding(16)
    }
}
