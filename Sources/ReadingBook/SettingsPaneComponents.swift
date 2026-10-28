import SwiftUI

/// Labelled form controls retain one native hierarchy at every width. Layout
/// changes proposals and placement, never constructs an alternative Picker.
struct SettingsPaneField<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            control()
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsPaneControlRow<Control: View>: View {
    let title: String
    let detail: String
    var controlWidth: CGFloat = 210
    @ViewBuilder var control: () -> Control
    var body: some View {
        SettingsPaneControlLayout(controlWidth: controlWidth) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16)
    }
}

struct SettingsPaneToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.regular).padding(16)
            .help(detail).accessibilityLabel(title).accessibilityHint(detail)
    }
}

struct SettingsPaneFieldGrid: Layout {
    var minimumColumnWidth: CGFloat = 165
    var spacing: CGFloat = 16
    private func dimensions(_ width: CGFloat?, _ subviews: Subviews) -> (width: CGFloat, column: CGFloat, heights: [CGFloat], inline: Bool) {
        let count = subviews.count
        guard count > 0 else { return (max(0, width ?? 0), 0, [], false) }
        let fallback = minimumColumnWidth * CGFloat(count) + spacing * CGFloat(count - 1)
        let available = max(1, width.flatMap { $0.isFinite ? $0 : nil } ?? fallback)
        let inline = available >= fallback
        let column = inline ? (available - spacing * CGFloat(count - 1)) / CGFloat(count) : available
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
        return (available, column, heights, inline)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let value = dimensions(proposal.width, subviews)
        let height = value.inline ? (value.heights.max() ?? 0) : value.heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: value.width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let value = dimensions(bounds.width, subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let x = value.inline ? bounds.minX + CGFloat(index) * (value.column + spacing) : bounds.minX
            subviews[index].place(at: CGPoint(x: x, y: value.inline ? bounds.minY : y), anchor: .topLeading,
                proposal: ProposedViewSize(width: value.column, height: value.heights[index]))
            y += value.heights[index] + spacing
        }
    }
}

private struct SettingsPaneControlLayout: Layout {
    var controlWidth: CGFloat
    private let labelWidth: CGFloat = 155
    private let spacing: CGFloat = 16
    private let stackedSpacing: CGFloat = 10
    private func dimensions(_ width: CGFloat?, _ subviews: Subviews) -> (width: CGFloat, label: CGSize, control: CGSize, inline: Bool) {
        guard subviews.count == 2 else { return (max(0, width ?? 0), .zero, .zero, false) }
        let available = max(1, width.flatMap { $0.isFinite ? $0 : nil } ?? (labelWidth + spacing + controlWidth))
        let actionWidth = min(controlWidth, available)
        let inline = available >= labelWidth + spacing + actionWidth
        let leading = subviews[0].sizeThatFits(ProposedViewSize(width: inline ? available - actionWidth - spacing : available, height: nil))
        let control = subviews[1].sizeThatFits(ProposedViewSize(width: actionWidth, height: nil))
        return (available, leading, control, inline)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let value = dimensions(proposal.width, subviews)
        return CGSize(width: value.width, height: value.inline ? max(value.label.height, value.control.height) : value.label.height + stackedSpacing + value.control.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let value = dimensions(bounds.width, subviews), total = value.inline ? max(value.label.height, value.control.height) : value.label.height + stackedSpacing + value.control.height
        let leadingWidth = value.inline ? max(0, bounds.width - value.control.width - spacing) : bounds.width
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (value.inline ? (total - value.label.height) / 2 : 0)), anchor: .topLeading,
            proposal: ProposedViewSize(width: leadingWidth, height: value.label.height))
        subviews[1].place(at: CGPoint(x: value.inline ? bounds.maxX - value.control.width : bounds.minX,
            y: bounds.minY + (value.inline ? (total - value.control.height) / 2 : value.label.height + stackedSpacing)), anchor: .topLeading,
            proposal: ProposedViewSize(value.control))
    }
}
