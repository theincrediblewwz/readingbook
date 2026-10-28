import SwiftUI

struct ManagementActionOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    var enabled = true
    var destructive = false
}

/// Explicit commands with readable descriptions. Destructive commands retain
/// their original confirmation flow and never receive initial keyboard focus.
struct ManagementActionPopover: View {
    let title: String
    let options: [ManagementActionOption]
    var width: CGFloat = 340
    var maximumHeight: CGFloat = 440
    let close: () -> Void
    let select: (String) -> Void
    @FocusState private var focusedID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .buttonStyle(.plain).help("关闭" + title).accessibilityLabel("关闭" + title)
            }.padding(.leading, 16).padding(.trailing, 8).frame(height: 48)
            Divider().opacity(0.4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(options) { option in
                        Button { select(option.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.icon).font(.system(size: 18))
                                    .foregroundStyle(option.destructive ? Palette.copper : Palette.accent).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.title).font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(option.destructive ? Palette.copper : Palette.ink)
                                    Text(option.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(ManagementActionRowStyle()).disabled(!option.enabled)
                            .focused($focusedID, equals: option.id)
                            .help(option.title + "\n" + option.detail).accessibilityElement(children: .combine)
                    }
                }.padding(6)
            }.frame(height: min(maximumHeight - 49, CGFloat(options.count) * 64 + 12))
        }.frame(width: width).background(Palette.surface)
            .onExitCommand(perform: close)
            .onAppear { focusedID = options.first(where: { $0.enabled && !$0.destructive })?.id }
            .onMoveCommand { direction in
                let enabled = options.filter(\.enabled).map(\.id)
                guard !enabled.isEmpty, direction == .up || direction == .down else { return }
                let delta = direction == .down ? 1 : -1
                let index = focusedID.flatMap { enabled.firstIndex(of: $0) } ?? (delta > 0 ? -1 : enabled.count)
                focusedID = enabled[min(enabled.count - 1, max(0, index + delta))]
            }
    }
}

private struct ManagementActionRowStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.accent.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? 1 : 0.45).onHover { hovered = $0 }
    }
}
