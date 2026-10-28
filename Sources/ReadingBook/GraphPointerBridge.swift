import SwiftUI
import AppKit

/// AppKit keeps the original mouse receiver for a complete gesture. Deltas are
/// measured in the window, so moving the card never changes the drag's origin.
struct GraphPointerBridge: NSViewRepresentable {
    var enabled: Bool
    var movable: Bool
    var reservePorts = false
    var resetID = 0
    var exclusion: CGRect? = nil
    var additionalExclusions: [CGRect] = []
    var canvasID: UUID? = nil
    var requiresUnobscuredDragEnd = false
    var click: (Bool) -> Void
    var drag: (CGSize, Bool) -> Void
    var cancel: () -> Void
    func makeNSView(context: Context) -> PointerView { PointerView() }
    func updateNSView(_ view: PointerView, context: Context) {
        view.configure(enabled: enabled, movable: movable, reservePorts: reservePorts, resetID: resetID, exclusion: exclusion,
                       additionalExclusions: additionalExclusions, canvasID: canvasID, requiresUnobscuredDragEnd: requiresUnobscuredDragEnd)
        view.click = click; view.drag = drag; view.cancel = cancel
    }
    static func dismantleNSView(_ view: PointerView, coordinator: ()) { view.invalidate() }
    final class PointerView: NSView, WorkspaceCanvasInputTarget {
        var enabled = true
        var movable = false
        var reservePorts = false
        var exclusion: CGRect?
        var additionalExclusions: [CGRect] = []
        var canvasInputID: UUID?
        var requiresUnobscuredDragEnd = false
        var click: ((Bool) -> Void)?
        var drag: ((CGSize, Bool) -> Void)?
        var cancel: (() -> Void)?
        private var origin: CGPoint?
        private var resetID = 0
        private var didDrag = false
        private var escapeMonitor: Any?
        private var focusObservers: [NSObjectProtocol] = []
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enabled else { return nil }
            let local = convert(point, from: superview)
            guard permitsHit(local) else { return nil }
            if reservePorts, abs(local.y - bounds.midY) <= 14, local.x <= 14 || local.x >= bounds.width - 14 { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {
            guard enabled, permitsHit(convert(event.locationInWindow, from: nil)) else { stopTracking(); return }
            stopTracking()
            origin = event.locationInWindow; didDrag = false
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.origin != nil,
                      let window = self.window, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                self.stopTracking(); self.cancel?(); return nil
            }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?), (NSApplication.didResignActiveNotification, NSApplication.shared as AnyObject?)] {
                focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { guard let self, self.origin != nil else { return }; self.stopTracking(); self.cancel?() }
                })
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard enabled, let origin else { return }
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            guard didDrag || hypot(delta.width, delta.height) >= 4 else { return }
            didDrag = true
            if movable { drag?(delta, false) }
        }
        override func mouseUp(with event: NSEvent) {
            guard let start = origin else { return }
            if didDrag, requiresUnobscuredDragEnd, !permitsHit(convert(event.locationInWindow, from: nil)) {
                stopTracking(); cancel?(); return
            }
            origin = nil
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }; focusObservers = []
            guard enabled else { didDrag = false; cancel?(); return }
            if didDrag { if movable { drag?(CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y), true) } }
            else { click?(event.clickCount >= 2) }
            didDrag = false
        }
        private func stopTracking() {
            origin = nil; didDrag = false
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }; focusObservers = []
        }
        private func permitsHit(_ local: CGPoint) -> Bool {
            guard exclusion?.contains(local) != true, !additionalExclusions.contains(where: { $0.contains(local) }) else { return false }
            guard let canvasInputID else { return true }
            return WorkspaceCanvasInputRegions.permits(local, in: self, canvasID: canvasInputID)
        }
        func configure(enabled: Bool, movable: Bool, reservePorts: Bool, resetID: Int, exclusion: CGRect?, additionalExclusions: [CGRect], canvasID: UUID?, requiresUnobscuredDragEnd: Bool) {
            if self.resetID != resetID || self.canvasInputID != canvasID || (self.enabled && !enabled) || (self.movable && !movable) { stopTracking() }
            self.resetID = resetID; self.exclusion = exclusion
            self.additionalExclusions = additionalExclusions; self.canvasInputID = canvasID
            self.requiresUnobscuredDragEnd = requiresUnobscuredDragEnd
            self.enabled = enabled; self.movable = movable; self.reservePorts = reservePorts
        }
        override func cancelOperation(_ sender: Any?) { stopTracking(); cancel?() }
        override func viewDidMoveToWindow() { if window == nil { stopTracking() } }
        func invalidate() { stopTracking(); click = nil; drag = nil; cancel = nil; canvasInputID = nil }
        deinit {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard enabled, permitsHit(convert(event.locationInWindow, from: nil)) else { return nil }
            // The SwiftUI node owns its contextual actions. Forward right-click
            // lookup to its hosting ancestors rather than swallowing the menu.
            var ancestor = superview
            while let view = ancestor {
                if let menu = view.menu(for: event) { return menu }
                ancestor = view.superview
            }
            return nil
        }
    }
}
