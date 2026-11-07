import AppKit
import MapKit
import Foundation
@testable import ReadingBook

// In-process event fixtures go directly through the production routers. They
// are never posted to the OS or NSApplication, and never operate another app.
@MainActor private final class Wheel: NSEvent {
    var owner: NSWindow!
    var point = CGPoint.zero
    var flags: NSEvent.ModifierFlags = []
    var wheelPhase: NSEvent.Phase = []
    var inertia: NSEvent.Phase = []
    var eventType: NSEvent.EventType = .scrollWheel
    override var type: NSEvent.EventType { eventType }
    override var magnification: CGFloat { 0.1 }
    override var window: NSWindow? { owner }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var phase: NSEvent.Phase { wheelPhase }
    override var momentumPhase: NSEvent.Phase { inertia }
    override var scrollingDeltaY: CGFloat { -60 }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { true }
}
@MainActor private final class Page: NSScrollView {
    var received: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { received.append(event) }
}
@MainActor private final class Document: NSView { override var isFlipped: Bool { true } }
@MainActor private final class Canvas: NSView, WorkspaceCanvasInputTarget {
    var canvasInputID: UUID?
}
@MainActor private final class Runner: NSObject, NSApplicationDelegate {
    var checks: [String: Bool] = [:]
    var output: URL!
    var window: NSWindow!
    var other: NSWindow!
    let page = Page(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    let document = Document(frame: CGRect(x: 0, y: 0, width: 780, height: 1400))
    let map = MKMapView(frame: CGRect(x: 20, y: 20, width: 550, height: 300))
    let mapInput = CompositionPageScrollInput.ScrollView(frame: CGRect(x: 20, y: 20, width: 550, height: 300))
    let graphInput = GraphViewportInput.ViewportView(frame: CGRect(x: 20, y: 350, width: 550, height: 220))
    let canvas = Canvas(frame: CGRect(x: 20, y: 350, width: 550, height: 220))
    var panCount = 0
    var zoomCount = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try finish(nil) } catch { try? finish(String(describing: error)) }
            mapInput.invalidate(); graphInput.invalidate(); window?.orderOut(nil); other?.orderOut(nil); NSApp.terminate(nil)
        }
    }
    func check(_ name: String, _ value: Bool) throws {
        checks[name] = value
        if !value { throw NSError(domain: name, code: 1) }
    }
    func wheel(_ view: NSView, flags: NSEvent.ModifierFlags = [], phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) -> Wheel {
        let value = Wheel(); value.owner = window; value.point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        value.flags = flags; value.wheelPhase = phase; value.inertia = momentum; return value
    }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/composition-scroll-"), Bundle.main.bundleIdentifier == "org.readingbook.composition-scroll-regression" else { throw NSError(domain: "isolation", code: 1) }
        window = NSWindow(contentRect: CGRect(x: 80, y: 100, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        page.hasVerticalScroller = true; page.documentView = document; window.contentView = page
        document.addSubview(map); document.addSubview(mapInput)
        canvas.canvasInputID = UUID(); document.addSubview(canvas); document.addSubview(graphInput)
        graphInput.configure(enabled: true, canvasID: canvas.canvasInputID!, exclusions: [], prefersPageScroll: true)
        graphInput.scroll = { [weak self] _ in self?.panCount += 1 }; graphInput.zoom = { [weak self] _, _ in self?.zoomCount += 1 }
        window.title = "ReadingBook 组合页滚动 · 隔离路由回归"; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(160)); window.contentView?.layoutSubtreeIfNeeded()
        try check("keyWindowReady", window.isKeyWindow)
        let event = wheel(map)
        try check("ordinaryMapWheelConsumed", mapInput.route(event) == nil)
        try check("originalEventForwardedToOuterPage", page.received.last === event)
        try check("mapBridgeDoesNotInterceptClicks", mapInput.hitTest(.zero) == nil)
        for (name, flag) in [("command", NSEvent.ModifierFlags.command), ("option", .option), ("control", .control), ("shift", .shift)] {
            let modified = wheel(map, flags: flag), count = page.received.count
            try check(name + "MapWheelRetained", mapInput.route(modified) === modified && page.received.count == count)
        }
        event.owner = other
        try check("otherWindowNotCaptured", mapInput.route(event) === event)
        event.owner = window; mapInput.enabled = false
        try check("blockedMapNotCaptured", mapInput.route(event) === event)
        mapInput.enabled = true; mapInput.isHidden = true
        try check("hiddenMapNotCaptured", mapInput.route(event) === event)
        mapInput.isHidden = false
        let overlay = NSButton(frame: CGRect(x: 200, y: 100, width: 160, height: 80)); document.addSubview(overlay)
        let overButton = wheel(overlay)
        try check("overlappingControlNotCaptured", mapInput.route(overButton) === overButton)
        overlay.removeFromSuperview()
        let nested = NSScrollView(frame: CGRect(x: 100, y: 80, width: 200, height: 100)); nested.documentView = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 500)); document.addSubview(nested)
        let overList = wheel(nested)
        try check("nestedListNotCaptured", mapInput.route(overList) === overList)
        nested.removeFromSuperview()
        let began = wheel(map, phase: .began), changed = wheel(map, phase: .changed), ended = wheel(map, phase: .ended)
        try check("mapGestureLifecycleForwarded", mapInput.route(began) == nil && mapInput.route(changed) == nil && mapInput.route(ended) == nil)
        let momentum = wheel(map, momentum: .began), final = wheel(map, momentum: .ended)
        try check("mapMomentumForwarded", mapInput.route(momentum) == nil && mapInput.route(final) == nil)
        let outside = wheel(canvas, phase: .began), moved = wheel(map, phase: .changed)
        try check("gestureCannotBeAdoptedMidway", mapInput.route(outside) === outside && mapInput.route(moved) === moved)
        let cancelled = wheel(map, phase: .cancelled)
        try check("cancelledGestureNotCaptured", mapInput.route(cancelled) === cancelled)
        let graphWheel = wheel(canvas), before = page.received.count
        try check("embeddedGraphScrollsPage", graphInput.route(graphWheel) == nil && page.received.count == before + 1 && panCount == 0)
        try check("embeddedGraphCommandWheelStillZooms", graphInput.route(wheel(canvas, flags: .command)) == nil && zoomCount == 1)
        let pinch = wheel(canvas); pinch.eventType = .magnify
        try check("embeddedGraphPinchStillZooms", graphInput.route(pinch) == nil && zoomCount == 2)
        let mapPinch = wheel(map); mapPinch.eventType = .magnify
        try check("mapPinchRetained", mapInput.route(mapPinch) === mapPinch)
        graphInput.configure(enabled: true, canvasID: canvas.canvasInputID!, exclusions: [])
        let prior = page.received.count
        try check("standaloneGraphKeepsWheelPan", graphInput.route(wheel(canvas)) == nil && panCount == 1 && page.received.count == prior)
        graphInput.configure(enabled: true, canvasID: canvas.canvasInputID!, exclusions: [graphInput.bounds], prefersPageScroll: true)
        let excluded = wheel(canvas)
        try check("graphExclusionNotCaptured", graphInput.route(excluded) === excluded)
        let detached = CompositionPageScrollInput.ScrollView(frame: mapInput.frame)
        try check("detachedBridgeNotCaptured", detached.route(wheel(map)) != nil)
        let mapBeforeRemoval = wheel(map), graphBeforeRemoval = wheel(canvas), receivedBeforeRemoval = page.received.count
        mapInput.removeFromSuperview(); graphInput.removeFromSuperview()
        try check("removedBridgesDoNotCapture", mapInput.route(mapBeforeRemoval) === mapBeforeRemoval && graphInput.route(graphBeforeRemoval) === graphBeforeRemoval && page.received.count == receivedBeforeRemoval)
    }
    func finish(_ error: String?) throws {
        let value: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error as Any? ?? NSNull(), "checks": checks, "originalLibraryUsed": false, "realNetworkRequests": 0, "eventsPostedToOS": false]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
}
@main struct Main { static func main() { let app = NSApplication.shared; let runner = Runner(); app.delegate = runner; app.setActivationPolicy(.regular); app.run(); _ = runner } }
