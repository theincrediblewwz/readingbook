import SwiftUI

/// The browser is an overlay over the same world canvas, never a layout column.
/// Its native handle measures a single window-space drag origin so previewing a
/// node or saving its position cannot move the panel underneath the pointer.
struct FloatingGraphWorkspace<Surface: View>: View {
    var items: [GraphItem]
    var selectedNodeID: String?
    var select: (GraphItem) -> Void
    var open: (GraphItem) -> Void
    var surface: (CGRect, CGFloat, CGFloat) -> Surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = true
    @State private var collapsed = false
    @State private var viewport = CGSize.zero
    @State private var savedOrigin: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var dragPosition: CGPoint?
    @State private var pointerEpoch = 0
    @State private var initialized = false
    private let margin: CGFloat = 24
    private let topReserve: CGFloat = 96

    init(items: [GraphItem], selectedNodeID: String?, select: @escaping (GraphItem) -> Void,
         open: @escaping (GraphItem) -> Void, @ViewBuilder surface: @escaping (CGRect, CGFloat, CGFloat) -> Surface) {
        self.items = items; self.selectedNodeID = selectedNodeID
        self.select = select; self.open = open; self.surface = surface
    }

    private var panelWidth: CGFloat { min(ReadingLayout.nodeBrowserWidth, max(220, viewport.width - margin * 2)) }
    private var fullHeight: CGFloat { max(220, min(770, viewport.height - topReserve - 104)) }
    private var panelHeight: CGFloat { collapsed ? 60 : fullHeight }
    private var panelFrame: CGRect {
        let origin = clamp(dragPosition ?? savedOrigin ?? CGPoint(x: viewport.width - panelWidth - margin, y: topReserve + 12))
        return CGRect(x: origin.x, y: origin.y, width: panelWidth, height: panelHeight)
    }
    private var restoreFrame: CGRect { CGRect(x: max(margin, viewport.width - 176 - margin), y: topReserve + 12, width: 176, height: 52) }
    private var exclusion: CGRect { shown ? panelFrame : restoreFrame }
    private var settledFrame: CGRect {
        CGRect(origin: clamp(savedOrigin ?? CGPoint(x: viewport.width - panelWidth - margin, y: topReserve + 12)), size: CGSize(width: panelWidth, height: panelHeight))
    }
    private var leadingCover: CGFloat {
        shown && !collapsed && settledFrame.midX < viewport.width / 2 ? min(settledFrame.maxX + margin, viewport.width - 120) : 0
    }
    private var trailingCover: CGFloat {
        shown && !collapsed && settledFrame.midX >= viewport.width / 2 ? min(viewport.width - settledFrame.minX + margin, viewport.width - 120) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Palette.canvas
                if viewport.width > 0, viewport.height > 0 {
                    surface(exclusion, leadingCover, trailingCover)
                        .overlay(alignment: .topLeading) { browserOverlay }.readingGlassGroup()
                }
            }.onAppear {
                viewport = geometry.size
                if !initialized { shown = geometry.size.width >= 1050; initialized = true }
            }
            .onChange(of: geometry.size) { old, next in
                cancelDrag(); viewport = next
                if let savedOrigin { self.savedOrigin = clamp(savedOrigin) }
                if old.width >= 1050, next.width < 1050 { animate { shown = false } }
            }
        }.onDisappear { cancelDrag() }.onExitCommand { cancelDrag() }
    }
    @ViewBuilder private var browserOverlay: some View {
        if shown {
            GraphNodeBrowser(items: items, selectedNodeID: selectedNodeID, height: fullHeight, select: select, open: open,
                             close: { animate { shown = false }; cancelDrag() }, collapsed: collapsed,
                             toggleCollapsed: { cancelDrag(); animate { collapsed.toggle() } }, width: panelWidth,
                             dragEpoch: pointerEpoch, beginDrag: beginDrag, drag: updateDrag, cancelDrag: cancelDrag)
                .position(x: panelFrame.midX, y: panelFrame.midY).transition(.opacity)
        } else {
            Button { cancelDrag(); animate { shown = true; collapsed = false } } label: {
                Label("节点 · \(items.count)", systemImage: "sidebar.right")
            }.buttonStyle(ReadingToolbarButtonStyle()).padding(5).readingGlass(interactive: true)
                .frame(width: restoreFrame.width, height: restoreFrame.height)
                .position(x: restoreFrame.midX, y: restoreFrame.midY).transition(.opacity)
                .help("恢复节点列表与内容预览")
        }
    }
    private func clamp(_ origin: CGPoint) -> CGPoint {
        CGPoint(x: min(max(margin, origin.x), max(margin, viewport.width - panelWidth - margin)),
                y: min(max(topReserve + 12, origin.y), max(topReserve + 12, viewport.height - panelHeight - margin)))
    }
    private func beginDrag() { dragOrigin = panelFrame.origin; dragPosition = nil }
    private func updateDrag(_ delta: CGSize, _ ended: Bool) {
        guard let dragOrigin else { return }
        let next = clamp(CGPoint(x: dragOrigin.x + delta.width, y: dragOrigin.y + delta.height))
        var transaction = Transaction(); transaction.animation = nil
        withTransaction(transaction) {
            if ended { savedOrigin = next; self.dragOrigin = nil; dragPosition = nil }
            else { dragPosition = next }
        }
    }
    private func cancelDrag() {
        var transaction = Transaction(); transaction.animation = nil
        withTransaction(transaction) { dragOrigin = nil; dragPosition = nil; pointerEpoch &+= 1 }
    }
    private func animate(_ action: () -> Void) { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { action() } }
}
