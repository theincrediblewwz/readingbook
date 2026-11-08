import AppKit
import Foundation
import MapKit
import QuartzCore
import SwiftUI
import Vision
@testable import ReadingBook
@testable import ReadingCore

@MainActor private final class MapFixture: ObservableObject {
    @Published var dark = false
}
private struct MapFixtureView: View {
    @ObservedObject var model: MapFixture
    let store: AppStore
    var body: some View {
        SpatialTimelineView().environmentObject(store).environmentObject(ReadingTypographySettings())
            .environment(\.colorScheme, model.dark ? .dark : .light).environment(\.readingReduceMotion, true)
    }
}
@MainActor private final class MapRunner: NSObject, NSApplicationDelegate {
    var output: URL!
    var window: NSWindow!
    var host: NSHostingView<MapFixtureView>!
    var store: AppStore!
    let model = MapFixture()
    var checks: [String: Bool] = [:]
    var observations: [[String: Any]] = []
    var expected: [BookProject] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try finish(nil) } catch { try? finish(String(describing: error)) }
            if ProcessInfo.processInfo.environment["MAP_GATE_HOLD"] == "1" { try? await Task.sleep(for: .seconds(100)) }
            window?.orderOut(nil); NSApp.terminate(nil)
        }
    }
    func require(_ name: String, _ condition: Bool) throws {
        checks[name] = condition; guard condition else { throw ReadingError.invalid(name) }
    }
    func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    func map() throws -> MKMapView {
        let maps = descendants(host, MKMapView.self)
        guard maps.count == 1, let map = maps.first else { throw ReadingError.invalid("Expected one native MapKit view") }
        return map
    }
    func annotations() throws -> [MKAnnotation] { try map().annotations.filter { !($0 is MKUserLocation) } }
    func settle(_ ms: Int = 180) async throws {
        try await Task.sleep(for: .milliseconds(ms)); host.layoutSubtreeIfNeeded(); CATransaction.flush(); window.displayIfNeeded()
        guard window.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { throw ReadingError.invalid("Foreground lost") }
    }
    func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    func fixture(_ id: String, suffix: String = "") -> BookProject {
        let units = (0..<80).map { SourceUnit(id: "u\($0)", order: $0, chapter: "章\($0)", page: $0 + 1, text: "第\($0)页的合成原文 café。") }
        var book = BookProject(id: id, title: "地图内容更新合成书\(suffix)", originalName: "synthetic.txt", sourceHash: String(repeating: id == "book-a" ? "a" : "b", count: 64), units: units)
        PluginEngine.seed(&book)
        book.entities = (0..<80).map { i in KnowledgeEntity(id: "p\(i)", typeID: "place", name: "地点\(i)\(suffix)", latitude: 20 + Double(i % 10) * 0.7, longitude: 80 + Double(i / 10) * 0.7, evidence: [Evidence(unitID: units[i].id, quote: units[i].text)]) }
        book.events = (0..<80).map { i in KnowledgeEvent(id: "e\(i)", name: "事件\(i)地点相会\(suffix)", dateText: "\(200+i)年", startYear: 200+i, placeIDs: ["p\(i)"], evidence: [Evidence(unitID: units[i].id, quote: units[i].text)]) }
        return book
    }
    func configure(_ book: BookProject) {
        store.books = [book]; store.bookID = book.id; store.selectedUnitID = book.units.last?.id
        store.readingScopeCurrent = false; store.temporalAxis = "legacy"; store.timeFrom = 195; store.timeTo = 400
        store.workspaceMemory = BookWorkspaceMemory(bookID: book.id, sourceHash: book.sourceHash)
        store.updateWorkspaceMemory { $0.temporalAxis = "legacy"; $0.timeFrom = 195; $0.timeTo = 400 }
        expected = [book]
    }
    func marker(_ index: Int) throws -> MKAnnotationView {
        let point = store.book!.entities[index]
        guard let annotation = try annotations().first(where: { abs($0.coordinate.latitude - point.latitude!) < 1e-8 && abs($0.coordinate.longitude - point.longitude!) < 1e-8 }), let view = try map().view(for: annotation) else { throw ReadingError.invalid("Visible native marker \(index) missing") }
        return view
    }
    func click(_ view: MKAnnotationView) async throws {
        // MapKit can return a reused annotation before moving it from its old
        // frame (including {{0,0},{44,44}}). Do not queue a click until the
        // rendered annotation agrees with MapKit's current coordinate projection.
        // This only bounds input readiness; the existing 550ms result deadline,
        // exact recenter/zoom assertions and native event dispatch stay unchanged.
        let native = try map(), started = ProcessInfo.processInfo.systemUptime
        var stablePoint: CGPoint?, stableSince = started
        while true {
            host.layoutSubtreeIfNeeded(); native.layoutSubtreeIfNeeded()
            guard let annotation = view.annotation else { throw ReadingError.invalid("Marker lost its annotation") }
            let projected = native.convert(annotation.coordinate, toPointTo: host)
            let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: host)
            let expected = CGPoint(x: projected.x + view.centerOffset.x,
                                   y: projected.y + (host.isFlipped ? view.centerOffset.y : -view.centerOffset.y))
            let aligned = hypot(center.x - expected.x, center.y - expected.y) < 0.5
            let current = native.view(for: annotation) === view && view.window === window
                && !view.isHidden && view.alphaValue > 0 && host.bounds.intersects(view.convert(view.bounds, to: host))
            let now = ProcessInfo.processInfo.systemUptime
            if current && aligned {
                if let previous = stablePoint, hypot(previous.x - center.x, previous.y - center.y) < 0.5 {
                    if now - stableSince >= 0.04 && now - started < 1.5 {
                        observations.append(["stage": "click-geometry-ready", "uptime": now,
                            "readinessSeconds": now - started, "projectedPoint": NSStringFromPoint(projected),
                            "annotationCenter": NSStringFromPoint(center), "centerOffset": NSStringFromPoint(view.centerOffset)])
                        break
                    }
                } else { stablePoint = center; stableSince = now }
            } else { stablePoint = nil; stableSince = now }
            guard now - started < 1.5 else {
                observations.append(["stage": "click-geometry-not-ready", "uptime": now,
                    "projectedPoint": NSStringFromPoint(projected), "annotationCenter": NSStringFromPoint(center)])
                throw ReadingError.invalid("Marker geometry did not become ready within 1500ms")
            }
            try await settle(16)
        }
        // Use the visible pin itself, rather than the middle of the selected
        // pin-plus-label group, which can be covered by another annotation.
        let y = view.bounds.height > 90 ? (view.isFlipped ? view.bounds.minY + 21 : view.bounds.maxY - 21) : view.bounds.midY
        let point = view.convert(CGPoint(x: view.bounds.midX, y: y), to: nil)
        guard host.bounds.contains(host.convert(point, from: nil)) else { throw ReadingError.invalid("Marker outside fixture") }
        let hitPoint = host.superview?.convert(point, from: nil) ?? point
        let hit = host.hitTest(hitPoint)
        observations.append(["stage": "actual-hit-receiver", "insideNativeMap": hit === native || hit?.isDescendant(of: native) == true,
            "receiver": hit.map { String(describing: type(of: $0)) } ?? "missing", "point": NSStringFromPoint(point)])
        guard hit === native || hit?.isDescendant(of: native) == true else { throw ReadingError.invalid("Marker click is outside the interactive map or covered") }
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) else { throw ReadingError.invalid("Fixture-local event") }
            NSApp.postEvent(event, atStart: false)
        }
        try await settle(550)
    }
    func labelStrings(_ root: NSView) -> [String] {
        // Public in-process AppKit accessibility properties, never another app.
        var result = [String](), visited = Set<ObjectIdentifier>()
        func walk(_ object: Any, _ depth: Int) {
            guard depth < 24, let element = object as? NSAccessibilityProtocol else { return }
            let id = ObjectIdentifier(element); guard visited.insert(id).inserted else { return }
            if let label = element.accessibilityLabel() { result.append(label) }
            for child in element.accessibilityChildren() ?? [] { walk(child, depth + 1) }
            if let view = object as? NSView { for child in view.subviews { walk(child, depth + 1) } }
        }
        walk(root, 0)
        return result
    }
    func verifyCurrentTitle(_ index: Int, _ check: String) throws {
        let view = try marker(index), labels = labelStrings(view), title = store.book!.events.first { $0.id == "e\(index)" }!.name
        var hierarchy = [[String: Any]]()
        func inspect(_ view: NSView, _ depth: Int) {
            guard depth < 20 else { return }
            hierarchy.append(["class": String(describing: type(of: view)), "depth": depth,
                "bounds": [view.bounds.origin.x, view.bounds.origin.y, view.bounds.width, view.bounds.height], "label": view.accessibilityLabel() ?? ""])
            for child in view.subviews { inspect(child, depth + 1) }
        }
        inspect(view, 0)
        for (name, target) in [(check+"-marker", view), (check+"-window", host as NSView)] {
            if let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) {
                target.cacheDisplay(in: target.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent(name+".png")) }
            }
        }
        let pixels = try renderedTexts(view)
        observations.append(["stage": check, "nativeLabels": labels, "nativeRasterText": pixels, "expectedTitle": title, "viewHierarchy": hierarchy])
        try require(check, (labels + pixels).contains { comparable($0).contains(comparable(title)) })
    }
    func comparable(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    func renderedTexts(_ view: NSView) throws -> [String] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReadingError.invalid("Marker raster missing") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw ReadingError.invalid("Marker image missing") }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
    func verifyNarrowTimeAxes() async throws {
        let probe = NSWindow(contentRect: .init(x: 120, y: 120, width: 640, height: 190), styleMask: [.titled], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        defer { probe.orderOut(nil); window.makeKeyAndOrderFront(nil) }
        for (lower, upper, range) in [(99603.0, 99603.0, 99603.0...99604.0),
                                       (99603.0, 99603.0, 99603.0...99603.0), (0.0, 0.25, 0.0...1.0)] {
            let content = NSHostingView(rootView: TimelineRangeControl(lower: .constant(lower), upper: .constant(upper), bounds: range,
                events: [], selectedID: nil, select: { _ in }, cursor: .constant(lower)))
            probe.contentView = content; probe.orderFront(nil); try await settle(80)
            content.layoutSubtreeIfNeeded()
            // Force the same accessibility representation used by VoiceOver
            // and the real single-day UI action that previously trapped.
            let labels = labelStrings(content)
            guard labels.contains("当前时间"), content.bounds.width > 0, content.bounds.height > 0 else {
                throw ReadingError.invalid("单时间点的实际原生时间轴没有显示当前时间")
            }
            observations.append(["stage": "narrow-time-axis", "lower": lower, "upper": upper,
                "axisLower": range.lowerBound, "axisUpper": range.upperBound, "currentTimeAXPresent": true])
        }
    }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/"), Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("Isolation") }
        let root = output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1": root.path, "service-profiles": Data("[]".utf8), "appearance.reduceMotion": true], forName: UserDefaults.argumentDomain)
        store = AppStore(); store.libraryRootURL = root; store.repository = LibraryRepository(rootURL: root)
        store.settings = .init(baseURL: "http://127.0.0.1:1/disabled", model: ""); store.apiKey = ""; configure(fixture("book-a"))
        window = NSWindow(contentRect: .init(x: 100, y: 80, width: 1120, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ReadingBook 地图内容复用 · 隔离回归"; window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: MapFixtureView(model: model, store: store)); window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); try await settle(650)
        try await verifyNarrowTimeAxes(); try await settle(160)
        let identity = ObjectIdentifier(try map())
        try require("isolatedLibrary", store.libraryRootURL.standardizedFileURL == root.standardizedFileURL)
        try require("all80NativeMarkersPresent", try annotations().count == 80)
        try await click(try marker(7)); try require("nativeMarkerSelectsCurrentEvent", store.selectedObjectID == "e7")
        try verifyCurrentTitle(7, "initialSelectedTitleVisible")
        let target = try map().region
        for cycle in 0..<3 {
            try map().setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: target.center.latitude + 0.2, longitude: target.center.longitude - 0.4), span: MKCoordinateSpan(latitudeDelta: target.span.latitudeDelta * 1.15, longitudeDelta: target.span.longitudeDelta * 1.15)), animated: false)
            try await settle(250)
            try require("nativePanApplied-\(cycle)", abs(try map().region.center.longitude - target.center.longitude) > 0.2)
            try await click(try marker(7)); let actual = try map().region
            observations.append(["cycle": cycle, "selectedID": store.selectedObjectID ?? "", "actualLatitude": actual.center.latitude, "actualLongitude": actual.center.longitude, "targetLatitude": target.center.latitude, "targetLongitude": target.center.longitude])
            try require("sameMarkerRecenters-\(cycle)", abs(actual.center.latitude - target.center.latitude) < 1e-6 && abs(actual.center.longitude - target.center.longitude) < 1e-6)
            try require("sameMarkerZoomRestored-\(cycle)", abs(actual.span.latitudeDelta - target.span.latitudeDelta) < 1e-5)
        }
        store.books[0].events[7].name = "更新后的事件七"; expected[0] = store.books[0]; try await settle()
        try verifyCurrentTitle(7, "sameIDTitleRefreshesNativeLabel")
        store.books[0].entities[7].name = "改名后的地点"; expected[0] = store.books[0]; try await settle()
        try require("sameIDSubtitleRefreshesNativeLabel", try renderedTexts(marker(7)).contains { $0.contains("改名后的地点") })
        let oldLatitude = store.books[0].entities[7].latitude!, oldLongitude = store.books[0].entities[7].longitude!
        store.books[0].entities[7].latitude = oldLatitude + 0.04; expected[0] = store.books[0]; try await settle(300)
        try require("sameIDCoordinateRefreshesNativeAnnotation", try annotations().contains { abs($0.coordinate.latitude - oldLatitude - 0.04) < 1e-8 })
        try require("oldCoordinateNotRetained", try !annotations().contains { abs($0.coordinate.latitude - oldLatitude) < 1e-8 && abs($0.coordinate.longitude - oldLongitude) < 1e-8 })
        store.timeTo = 220; try await settle(300)
        try require("filterCrossesTo21Markers", try annotations().count == 21)
        try require("sameNativeMapWhenCrossingBelowThreshold", ObjectIdentifier(try map()) == identity)
        store.timeTo = 400; try await settle(300)
        try require("filterRestores80Markers", try annotations().count == 80)
        try require("sameNativeMapWhenCrossingAboveThreshold", ObjectIdentifier(try map()) == identity)
        model.dark = true; try await settle()
        // The previous event is deliberately located above/alongside its tall
        // detail card. A different northern marker can then lie in reserved
        // navigation chrome. Pan it into the clear right side before clicking;
        // do not preselect it or substitute an action for the real native click.
        let themedMap = try map(), themedRegion = themedMap.region
        guard let themedCoordinate = try marker(8).annotation?.coordinate else { throw ReadingError.invalid("Theme marker missing") }
        observations.append(["stage": "theme-click-pan-precondition", "selectedIDBeforeClick": store.selectedObjectID ?? "", "targetID": "e8"])
        themedMap.setRegion(.init(center: .init(latitude: themedCoordinate.latitude,
            longitude: themedCoordinate.longitude - themedRegion.span.longitudeDelta * 0.28), span: themedRegion.span), animated: false)
        try await settle(250); try await click(try marker(8))
        try require("themeChangePreservesCurrentSelection", store.selectedObjectID == "e8")
        window.setContentSize(.init(width: 900, height: 680)); try await settle(300)
        try require("resizeKeepsAllMarkers", try annotations().count == 80)
        try require("resizeKeepsNativeMap", ObjectIdentifier(try map()) == identity)
        store.books[0].events.removeAll { $0.id == "e8" }; expected[0] = store.books[0]; try await settle(300)
        try require("sameIDRemovalUpdatesNativeAnnotations", try annotations().count == 79)
        configure(fixture("book-b", suffix: " · 第二本")); store.selectedObjectID = nil; try await settle(450)
        try require("newBookWithSameMarkerIDsHas80Markers", try annotations().count == 80)
        try await click(try marker(7)); try require("newBookMarkerUsesCurrentBinding", store.selectedObjectID == "e7")
        try verifyCurrentTitle(7, "newBookUsesCurrentTitle")
        let newRoot = output.appendingPathComponent("same-ids-new-library")
        store.libraryRootURL = newRoot; store.repository = LibraryRepository(rootURL: newRoot)
        // Root alone changes here: same IDs, selected ID, title and coordinates.
        // A stale cached scope would reject this repeated click and leave it panned.
        try await settle(450); let newTarget = try map().region
        try map().setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: newTarget.center.latitude + 0.2, longitude: newTarget.center.longitude - 0.4), span: newTarget.span), animated: false)
        try await settle(250); try await click(try marker(7)); let current = try map().region
        try require("newLibraryMarkerUsesCurrentBinding", store.selectedObjectID == "e7" && abs(current.center.latitude - newTarget.center.latitude) < 1e-6 && abs(current.center.longitude - newTarget.center.longitude) < 1e-6)
        store.books[0].events[7].name = "新书库事件七"; expected[0] = store.books[0]; try await settle()
        try verifyCurrentTitle(7, "newLibraryUsesCurrentTitle")
        try require("onlyIntentionalFixtureDataChanges", try encoded(store.books) == encoded(expected))
        try require("noModelRequests", store.requestsUsed == 0 && store.apiKey.isEmpty && store.savedServices.isEmpty)
    }
    func finish(_ error: String?) throws {
        let record: [String: Any] = ["status": error == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } ? "passed" : "failed", "error": error ?? NSNull(), "checks": checks, "checkCount": checks.count, "observations": observations, "realNetworkRequests": 0, "originalLibraryUsed": false, "scope": "Uninstrumented product SpatialTimelineView, native MapKit annotations and labels, fixture-window AppKit marker clicks. No simulated FPS claim."]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
}
@main private enum MapMain {
    @MainActor static func main() { let app = NSApplication.shared; app.setActivationPolicy(.regular); app.appearance = NSAppearance(named: .aqua); let runner = MapRunner(); app.delegate = runner; app.run(); withExtendedLifetime(runner) {} }
}
