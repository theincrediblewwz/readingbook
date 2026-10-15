import SwiftUI
import AppKit

/// Wheel and pinch events also work above node NSViews. Scope the monitor to
/// this viewport and exclude floating panels so their lists retain scrolling.
struct GraphViewportInput: NSViewRepresentable {
    var enabled: Bool
    var exclusions: [CGRect]
    var scroll: (CGSize) -> Void
    var zoom: (CGFloat, CGPoint) -> Void
    func makeNSView(context: Context) -> ViewportView { ViewportView() }
    func updateNSView(_ view: ViewportView, context: Context) {
        view.enabled = enabled; view.exclusions = exclusions; view.scroll = scroll; view.zoom = zoom
    }
    final class ViewportView: NSView {
        var enabled = true
        var exclusions: [CGRect] = []
        var scroll: ((CGSize) -> Void)?
        var zoom: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, self.enabled, !self.isHiddenOrHasHiddenAncestor,
                      event.window === self.window, self.window?.attachedSheet == nil,
                      NSApp.modalWindow == nil || NSApp.modalWindow === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), !self.exclusions.contains(where: { $0.contains(point) }) else { return event }
                if event.type == .magnify {
                    self.zoom?(max(0.01, 1 + event.magnification), point)
                } else if event.modifierFlags.contains(.command) {
                    self.zoom?(exp(event.scrollingDeltaY * 0.012), point)
                } else {
                    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    let delta = event.modifierFlags.contains(.shift) && event.scrollingDeltaX == 0
                        ? CGSize(width: event.scrollingDeltaY * multiplier, height: 0)
                        : CGSize(width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier)
                    self.scroll?(delta)
                }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
