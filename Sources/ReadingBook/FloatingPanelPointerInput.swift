import SwiftUI
import AppKit

/// Only covers the panel's title/handle, leaving its axis, buttons and text alone.
/// AppKit retains the mouse receiver; window-space deltas never follow the panel.
struct FloatingPanelPointerInput: NSViewRepresentable {
    var epoch: Int
    var begin: () -> Void
    var drag: (CGSize, Bool) -> Void
    var cancel: () -> Void

    func makeNSView(context: Context) -> PointerView { PointerView() }
    func updateNSView(_ view: PointerView, context: Context) {
        if view.epoch != epoch { view.stopTracking(); view.epoch = epoch }
        view.begin = begin; view.drag = drag; view.cancel = cancel
    }

    final class PointerView: NSView {
        var epoch = 0
        var begin: (() -> Void)?
        var drag: ((CGSize, Bool) -> Void)?
        var cancel: (() -> Void)?
        private var origin: CGPoint?
        private var didDrag = false
        private var escapeMonitor: Any?
        private var focusObservers: [NSObjectProtocol] = []
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            stopTracking(); origin = event.locationInWindow; begin?()
            NSCursor.closedHand.set()
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.origin != nil else { return event }
                self.stopTracking(); self.cancel?(); return nil
            }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?), (NSApplication.didResignActiveNotification, NSApplication.shared as AnyObject?)] {
                focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.origin != nil else { return }
                        self.stopTracking(); self.cancel?()
                    }
                })
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            guard didDrag || hypot(delta.width, delta.height) >= 4 else { return }
            didDrag = true; drag?(delta, false)
        }
        override func mouseUp(with event: NSEvent) {
            guard let origin else { return }
            let moved = didDrag
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            stopTracking()
            if moved { drag?(delta, true) } else { cancel?() }
        }
        func stopTracking() {
            let wasTracking = origin != nil
            origin = nil; didDrag = false
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
            focusObservers = []
            if wasTracking { NSCursor.openHand.set() }
        }
        override func cancelOperation(_ sender: Any?) { stopTracking(); cancel?() }
        override func viewDidMoveToWindow() {
            if window == nil {
                let wasTracking = origin != nil; stopTracking()
                if wasTracking { cancel?() }
            }
        }
        deinit {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
