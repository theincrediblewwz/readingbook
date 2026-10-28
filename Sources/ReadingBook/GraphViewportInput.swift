import SwiftUI
import AppKit
import ReadingCore

/// A monitor is necessary because nodes are native mouse receivers above the
/// background. Geometry alone is insufficient: an overlapping sidebar may be
/// inside that same rectangle. Only a positively identified canvas hit owns
/// wheel/pinch input; all other events continue to their original responder.
struct GraphViewportInput: NSViewRepresentable {
    var enabled: Bool
    var canvasID: UUID
    var exclusions: [CGRect]
    var scroll: (CGSize) -> Void
    var zoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> ViewportView { ViewportView() }
    func updateNSView(_ view: ViewportView, context: Context) {
        view.configure(enabled: enabled, canvasID: canvasID, exclusions: exclusions)
        view.scroll = scroll; view.zoom = zoom
    }
    static func dismantleNSView(_ view: ViewportView, coordinator: ()) { view.invalidate() }

    final class ViewportView: NSView {
        private var enabled = true
        private var canvasID: UUID?
        private var exclusions: [CGRect] = []
        var scroll: ((CGSize) -> Void)?
        var zoom: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?
        private var wheelOwnership = CanvasGestureOwnership()
        private var pinchOwnership = CanvasGestureOwnership()

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(enabled: Bool, canvasID: UUID, exclusions: [CGRect]) {
            if self.enabled != enabled || self.canvasID != canvasID { resetOwnership() }
            if self.canvasID != canvasID { WorkspaceCanvasInputRegions.remove(self, id: self.canvasID) }
            self.enabled = enabled; self.canvasID = canvasID; self.exclusions = exclusions
            registerInputRegion()
        }
        override func viewDidMoveToWindow() {
            removeMonitor(); resetOwnership()
            WorkspaceCanvasInputRegions.remove(self, id: canvasID)
            guard window != nil else { return }
            registerInputRegion()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self else { return event }
                return self.route(event)
            }
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard enabled, !isHiddenOrHasHiddenAncestor,
                  let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else {
                resetOwnership(); return event
            }
            let point = convert(event.locationInWindow, from: nil)
            let eligible = bounds.contains(point)
                && !exclusions.contains(where: { $0.contains(point) })
                && ownsHit(at: event.locationInWindow, window: window)
            let phase = Self.phase(event.phase)
            if event.type == .magnify {
                let accepted = pinchOwnership.accepts(phase: phase, isEligible: eligible)
                if phase == .ended { pinchOwnership.reset() }
                guard accepted else { return event }
                zoom?(max(0.01, 1 + event.magnification), point)
            } else {
                let accepted = wheelOwnership.accepts(phase: phase, momentum: Self.phase(event.momentumPhase), isEligible: eligible)
                guard accepted else { return event }
                if event.modifierFlags.contains(.command) {
                    zoom?(exp(event.scrollingDeltaY * 0.012), point)
                } else {
                    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    let delta = event.modifierFlags.contains(.shift) && event.scrollingDeltaX == 0
                        ? CGSize(width: event.scrollingDeltaY * multiplier, height: 0)
                        : CGSize(width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier)
                    scroll?(delta)
                }
            }
            return nil
        }

        private func ownsHit(at windowPoint: CGPoint, window: NSWindow) -> Bool {
            guard let canvasID, let content = window.contentView else { return false }
            // AppKit hitTest takes a point in the receiver's *superview*
            // coordinates, unlike the viewport's own local exclusion checks.
            let hitPoint = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
            var candidate = content.hitTest(hitPoint)
            while let view = candidate {
                // Never steal a wheel/pinch event from a native list, editor,
                // search field or button, even if nested in a canvas container.
                if view is NSScrollView || view is NSClipView || view is NSControl || view is NSTextView { return false }
                if let target = view as? WorkspaceCanvasInputTarget {
                    return target.canvasInputID == canvasID
                }
                candidate = view.superview
            }
            return false
        }
        private static func phase(_ phase: NSEvent.Phase) -> CanvasGesturePhase {
            if phase.contains(.cancelled) { return .cancelled }
            if phase.contains(.began) { return .began }
            if phase.contains(.mayBegin) { return .mayBegin }
            if phase.contains(.ended) { return .ended }
            return phase.isEmpty ? .none : .changed
        }
        private func resetOwnership() { wheelOwnership.reset(); pinchOwnership.reset() }
        private func registerInputRegion() {
            guard let canvasID, window != nil else { return }
            WorkspaceCanvasInputRegions.register(self, id: canvasID, exclusions: exclusions)
        }
        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        func invalidate() {
            removeMonitor(); resetOwnership(); WorkspaceCanvasInputRegions.remove(self, id: canvasID)
            scroll = nil; zoom = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
