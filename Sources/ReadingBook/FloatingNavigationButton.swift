import SwiftUI
import AppKit
import ReadingCore

struct FloatingNavigationButton: View {
    var viewport: CGSize
    var isExpanded: Bool
    var activate: () -> Void
    @AppStorage("frost-navigation-dock-v1") private var dockName = NavigationOrbDock.topLeading.rawValue
    @Environment(\.readingReduceMotion) private var reduceMotion
    @State private var origin: CGPoint?
    @State private var movingCenter: CGPoint?
    @State private var epoch = 0
    private var dock: NavigationOrbDock { NavigationOrbDock(rawValue: dockName) ?? .topLeading }
    private var center: CGPoint { movingCenter ?? NavigationOrbGeometry.center(in: viewport, dock: dock) }

    var body: some View {
        Button(action: activate) {
            Image(systemName: "sidebar.left").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.accent)
                .frame(width: NavigationOrbGeometry.buttonDiameter, height: NavigationOrbGeometry.buttonDiameter)
                .readingGlass(radius: 24, interactive: true)
        }.buttonStyle(ReadingQuietButtonStyle()).keyboardShortcut("b", modifiers: .command)
            .overlay {
                NavigationOrbPointerInput(epoch: epoch, begin: { origin = center }, move: { delta, finished in
                    let start = origin ?? NavigationOrbGeometry.center(in: viewport, dock: dock)
                    let point = NavigationOrbGeometry.clamped(CGPoint(x: start.x + delta.width, y: start.y + delta.height), in: viewport)
                    if finished {
                        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) {
                            dockName = NavigationOrbGeometry.nearest(to: point, in: viewport).rawValue
                            movingCenter = nil; origin = nil
                        }
                    } else { movingCenter = point }
                }, cancel: { movingCenter = nil; origin = nil }, activate: activate)
            }
            // Measure the 48pt control before position expands its layout box.
            // The canvas excludes this footprint, never a full-height column.
            .workspaceChromeBounds("navigation")
            .position(center)
            .help("点击\(isExpanded ? "收起" : "展开")导航；上下拖动后停靠左上或左下 · ⌘B")
            .accessibilityLabel(isExpanded ? "收起导航" : "展开导航")
            .accessibilityHint("在左侧上下拖动可停靠左上或左下。也可用 Command B 展开。")
            .accessibilityAction(named: Text("停靠左上角")) { dockName = NavigationOrbDock.topLeading.rawValue }
            .accessibilityAction(named: Text("停靠左下角")) { dockName = NavigationOrbDock.bottomLeading.rawValue }
            .onChange(of: viewport) { _, _ in epoch += 1; origin = nil; movingCenter = nil }
    }
}

/// Window-space coordinates keep the receiver stable while its view moves.
/// A drag never emits a click; Escape and focus loss restore the saved dock.
private struct NavigationOrbPointerInput: NSViewRepresentable {
    var epoch: Int
    var begin: () -> Void
    var move: (CGSize, Bool) -> Void
    var cancel: () -> Void
    var activate: () -> Void
    func makeNSView(context: Context) -> Receiver { Receiver() }
    func updateNSView(_ view: Receiver, context: Context) {
        if view.epoch != epoch { view.finish(); view.epoch = epoch }
        view.begin = begin; view.move = move; view.cancel = cancel; view.activate = activate
    }
    final class Receiver: NSView {
        var epoch = 0
        var begin: (() -> Void)?
        var move: ((CGSize, Bool) -> Void)?
        var cancel: (() -> Void)?
        var activate: (() -> Void)?
        private var origin: CGPoint?
        private var dragged = false
        private var escapeMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func mouseDown(with event: NSEvent) {
            finish(); origin = event.locationInWindow; begin?()
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.origin != nil,
                      let trackingWindow = self.window, event.window === trackingWindow else { return event }
                self.finish(); self.cancel?(); return nil
            }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?), (NSApplication.didResignActiveNotification, NSApplication.shared as AnyObject?)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { guard let self, self.origin != nil else { return }; self.finish(); self.cancel?() }
                })
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            guard dragged || hypot(delta.width, delta.height) >= 5 else { return }
            dragged = true; NSCursor.closedHand.set(); move?(delta, false)
        }
        override func mouseUp(with event: NSEvent) {
            guard let origin else { return }
            let moved = dragged, delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            finish()
            if moved { move?(delta, true) } else { cancel?(); activate?() }
        }
        override func cancelOperation(_ sender: Any?) { finish(); cancel?() }
        override func viewDidMoveToWindow() { if window == nil { let tracking = origin != nil; finish(); if tracking { cancel?() } } }
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
