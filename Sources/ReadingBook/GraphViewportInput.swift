import SwiftUI
import AppKit

/// Wheel and pinch events also work above node NSViews. Scope the monitor to
/// this viewport and exclude floating panels so their lists retain scrolling.
struct GraphViewportInput: NSViewRepresentable {
    var enabled: Bool
    var exclusion: CGRect?
    var scroll: (CGSize) -> Void
    var zoom: (CGFloat, CGPoint) -> Void
    func makeNSView(context: Context) -> ViewportView { ViewportView() }
    func updateNSView(_ view: ViewportView, context: Context) {
        view.enabled = enabled; view.exclusion = exclusion; view.scroll = scroll; view.zoom = zoom
    }
    final class ViewportView: NSView {
        var enabled = true
        var exclusion: CGRect?
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
                guard self.bounds.contains(point), self.exclusion?.contains(point) != true else { return event }
                // Camera controls occupy this corner. Let native controls own
                // their own input rather than moving content behind them.
                let controls = CGRect(x: max(0, self.bounds.width - 360), y: max(0, self.bounds.height - 64), width: 360, height: 64)
                guard !controls.contains(point) else { return event }
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
