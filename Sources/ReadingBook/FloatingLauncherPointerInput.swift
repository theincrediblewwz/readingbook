import SwiftUI
import AppKit

struct FloatingLauncherInteraction {
    var epoch: Int
    var begin: () -> Void
    var move: (CGSize, Bool) -> Void
    var cancel: () -> Void
}

/// Use window-space deltas while moving the control itself. A completed drag
/// never activates its button; Escape/focus loss restore the saved position.
struct FloatingLauncherPointerInput: NSViewRepresentable {
    var interaction: FloatingLauncherInteraction
    var activate: () -> Void

    func makeNSView(context: Context) -> Receiver { Receiver() }
    func updateNSView(_ view: Receiver, context: Context) {
        if view.epoch != interaction.epoch {
            let tracking = view.isTracking; view.finish()
            if tracking { view.interaction?.cancel() }
            view.epoch = interaction.epoch
        }
        view.interaction = interaction; view.activate = activate
    }
    final class Receiver: NSView {
        var epoch = 0
        var interaction: FloatingLauncherInteraction?
        var activate: (() -> Void)?
        private var origin: CGPoint?
        private var dragged = false
        private var escapeMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        var isTracking: Bool { origin != nil }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func mouseDown(with event: NSEvent) {
            finish(); origin = event.locationInWindow; interaction?.begin()
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.isTracking,
                      let trackingWindow = self.window, event.window === trackingWindow else { return event }
                self.finish(); self.interaction?.cancel(); return nil
            }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?), (NSApplication.didResignActiveNotification, NSApplication.shared as AnyObject?)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isTracking else { return }
                        self.finish(); self.interaction?.cancel()
                    }
                })
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            guard dragged || hypot(delta.width, delta.height) >= 5 else { return }
            dragged = true; NSCursor.closedHand.set(); interaction?.move(delta, false)
        }
        override func mouseUp(with event: NSEvent) {
            guard let origin else { return }
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            let moved = dragged || hypot(delta.width, delta.height) >= 5
            finish()
            if moved { interaction?.move(delta, true) }
            else { interaction?.cancel(); activate?() }
        }
        override func cancelOperation(_ sender: Any?) { finish(); interaction?.cancel() }
        override func viewDidMoveToWindow() {
            if window == nil { let tracking = isTracking; finish(); if tracking { interaction?.cancel() } }
        }
        func finish() {
            origin = nil; dragged = false
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
            NSCursor.arrow.set()
        }
        deinit {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
