import SwiftUI
import AppKit

/// An initial floor derived from the longest standard labels and existing
/// control targets. Native Menu widths are then measured in their single live
/// hierarchy, so fonts/localization or an extra restore menu can raise it.
enum ReadingCompanionToolbarMetrics {
    static let modeTabWidth: CGFloat = 48
    static let compactHeaderControlWidth: CGFloat = 32
    static var minimumPanelWidth: CGFloat {
        func text(_ value: String, size: CGFloat) -> CGFloat {
            (value as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width
        }
        let mode = text("解释与译文", size: 15) + 15 + 8 + 16
        let scope = text("当前章节", size: 13) + 13 + 8 + 16
        let tools = 32 + 16 + ReadingLayout.controlHeight * 2 + 8 * 2
        let toolbar = mode + scope + tools + 8 * 2 + ReadingLayout.panelPadding * 2
        let title = text("伴读与对话", size: ReadingLayout.panelTitleSize) + 20 + 8
        let tabs = modeTabWidth * 2 + 2 + 2 * 2
        let header = title + tabs + compactHeaderControlWidth + ReadingLayout.controlHeight + 8 * 3 + ReadingLayout.panelPadding * 2
        return ceil(max(toolbar, header))
    }
}

/// Each fixed-size toolbar group reports an intrinsic extent plus its share of
/// the padding/gap. These extents never depend on the panel's proposed width.
/// The floating host sums them after layout, without constructing alternative
/// native menus or publishing state from sizeThatFits/placeSubviews.
struct ReaderPanelIntrinsicWidthPreference: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}
