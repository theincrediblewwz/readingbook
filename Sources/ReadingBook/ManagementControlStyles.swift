import SwiftUI

enum ManagementControlMetrics {
    static let height: CGFloat = 36
    static let fontSize: CGFloat = 15
    static let cornerRadius: CGFloat = 8
}

/// macOS extracts native menu titles and icons from these simple labels.
/// Put the control surface on the Menu itself, outside that extraction.
struct ManagementMenuLabel: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var body: some View {
        if let icon { Label(title, systemImage: icon) }
        else { Text(title) }
    }
}

struct ManagementMenuSurface: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.font(.system(size: ManagementControlMetrics.fontSize, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: ManagementControlMetrics.height)
            .foregroundStyle(Palette.ink)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: ManagementControlMetrics.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ManagementControlMetrics.cornerRadius)
                    .strokeBorder(Palette.ink.opacity(hovered && enabled ? 0.35 : 0.22), lineWidth: 1).allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: ManagementControlMetrics.cornerRadius))
            .opacity(enabled ? 1 : 0.45).onHover { hovered = $0 }
    }
}

typealias ManagementMenuControlLabel = ManagementMenuLabel

struct ManagementSegmentOption: Identifiable {
    let id: String
    let title: String
    let detail: String
}

struct ManagementSegmentedControl: View {
    @Binding var selection: String
    let options: [ManagementSegmentOption]
    @Environment(\.isEnabled) private var enabled
    @State private var hovered: String?
    @FocusState private var focusedOption: String?
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                Button {
                    focusedOption = option.id
                    guard selection != option.id else { return }
                    selection = option.id
                } label: {
                    Text(option.title).font(.system(size: ManagementControlMetrics.fontSize, weight: .medium))
                        .lineLimit(1).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: ManagementControlMetrics.height)
                        .foregroundStyle(selection == option.id ? Palette.ink : Color.secondary)
                        .background(selection == option.id ? Palette.paper : Palette.accent.opacity(hovered == option.id ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: ManagementControlMetrics.cornerRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: ManagementControlMetrics.cornerRadius)
                                .strokeBorder(Palette.ink.opacity(selection == option.id ? 0.18 : 0), lineWidth: 1).allowsHitTesting(false)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: ManagementControlMetrics.cornerRadius))
                }.buttonStyle(.plain).help(option.detail)
                    .focusable()
                    .focused($focusedOption, equals: option.id)
                    .accessibilityLabel(option.title).accessibilityValue(selection == option.id ? "已选中" : "未选中")
                    .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                    .onHover { entered in if enabled { hovered = entered ? option.id : (hovered == option.id ? nil : hovered) } }
            }
        }.padding(4).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false) }
            .opacity(enabled ? 1 : 0.45).accessibilityElement(children: .contain)
            .onMoveCommand(perform: moveSelection)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard enabled, !options.isEmpty else { return }
        let offset: Int
        switch direction {
        case .left, .up: offset = -1
        case .right, .down: offset = 1
        default: return
        }
        let index = options.firstIndex(where: { $0.id == focusedOption })
            ?? options.firstIndex(where: { $0.id == selection }) ?? 0
        let target = options[max(0, min(options.count - 1, index + offset))].id
        focusedOption = target
        if selection != target { selection = target }
    }
}
