import AppKit
import MapKit
import SwiftUI
import ReadingCore

/// MapKit consumes wheel input before the enclosing SwiftUI scroll view sees it.
/// Only maps embedded in a composition opt into forwarding ordinary wheels to
/// that page. No synthetic event, global monitor or per-frame map work is needed.
struct CompositionPageScrollInput: NSViewRepresentable {
    @Environment(\.workspaceCanvasBlocked) private var blocked

    static func isOrdinaryWheel(_ event: NSEvent) -> Bool {
        event.type == .scrollWheel && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
    func makeNSView(context: Context) -> ScrollView { ScrollView() }
    func updateNSView(_ view: ScrollView, context: Context) { view.enabled = !blocked }
    static func dismantleNSView(_ view: ScrollView, coordinator: ()) { view.invalidate() }

    final class ScrollView: NSView {
        var enabled = true { didSet { if !enabled { ownership.reset() } } }
        private var monitor: Any?
        private var ownership = CanvasGestureOwnership()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            invalidate()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.route(event)
            }
        }
        func route(_ event: NSEvent) -> NSEvent? {
            guard enabled, !isHiddenOrHasHiddenAncestor, Self.accepts(event),
                  let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  let page = enclosingScrollView else { ownership.reset(); return event }
            let point = convert(event.locationInWindow, from: nil)
            let eligible = visibleRect.contains(point) && ownsMapHit(event.locationInWindow, window: window, page: page)
            guard ownership.accepts(phase: Self.phase(event.phase), momentum: Self.phase(event.momentumPhase), isEligible: eligible)
            else { return event }
            page.scrollWheel(with: event)
            return nil
        }
        private static func accepts(_ event: NSEvent) -> Bool { CompositionPageScrollInput.isOrdinaryWheel(event) }
        private func ownsMapHit(_ point: CGPoint, window: NSWindow, page: NSScrollView) -> Bool {
            guard let content = window.contentView, let document = page.documentView else { return false }
            let hitPoint = content.superview?.convert(point, from: nil) ?? point
            guard let hit = content.hitTest(hitPoint), hit.isDescendant(of: document) else { return false }
            var candidate: NSView? = hit
            while let view = candidate, view !== document {
                if view is MKMapView { return true }
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
        func invalidate() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            ownership.reset()
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
