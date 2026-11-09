// Appended to the exact product SpatialTimelineView source by the runner so
// this fixture exercises its private renderer, without changing its visibility.
import AppKit
import QuartzCore

@MainActor private final class TrajectoryInput: ObservableObject {
    @Published var count = 80
    @Published var sequence: [CLLocationCoordinate2D] = []
    @Published var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: .init(latitude: 25, longitude: 85),
        span: .init(latitudeDelta: 20, longitudeDelta: 20)))
    @Published var selection: ReadingMapSelection?
}
private struct TrajectoryFixtureView: View {
    @ObservedObject var input: TrajectoryInput
    private var points: [ReadingMapPoint] {
        (0..<input.count).map { index in
            let latitude = 22 + Double(index % 10) * 0.1
            let longitude = 82 + Double(index / 10) * 0.1
            return ReadingMapPoint(id: "p\(index)", targetID: "e\(index)", title: "地点\(index)", subtitle: "合成出处",
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
    }
    var body: some View {
        ReadingMapRenderer(points: points, routes: [], sequence: input.sequence, selectedID: nil,
        scope: ReadingMapScope(root: URL(fileURLWithPath: CommandLine.arguments[1]), key: "trajectory"),
        cameraValue: input.camera, camera: $input.camera, selection: $input.selection,
        inspectedRoute: .constant(nil)).equatable()
            .environment(\.readingReduceMotion, true)
    }
}
@MainActor private final class TrajectoryContentRunner: NSObject, NSApplicationDelegate {
    let input = TrajectoryInput()
    var window: NSWindow!, host: NSHostingView<TrajectoryFixtureView>!
    var checks = [String: Bool](), rows = [[String: Any]]()
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try finish(nil) } catch { try? finish(String(describing: error)) }
            window?.orderOut(nil); NSApp.terminate(nil)
        }
    }
    func map(_ root: NSView) -> MKMapView? {
        (root as? MKMapView) ?? root.subviews.lazy.compactMap { self.map($0) }.first
    }
    func coordinates(_ map: MKMapView) -> [[Double]] {
        guard let line = map.overlays.compactMap({ $0 as? MKPolyline }).first else { return [] }
        var result = [CLLocationCoordinate2D](repeating: .init(), count: line.pointCount)
        line.getCoordinates(&result, range: NSRange(location: 0, length: result.count))
        return result.map { [$0.latitude, $0.longitude] }
    }
    func matches(_ actual: [[Double]], _ expected: [[Double]]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy {
            abs($0[0] - $1[0]) < 1e-8 && abs($0[1] - $1[1]) < 1e-8
        }
    }
    func expectedMarkerCount(_ count: Int, _ native: MKMapView) -> Int {
        let points = (0..<count).map { index -> SpatialMarkerScreenPoint in
            let coordinate = SpatialCoordinate(latitude: 22 + Double(index % 10) * 0.1, longitude: 82 + Double(index / 10) * 0.1)
            let screen = native.convert(coordinate.mapCoordinate, toPointTo: native)
            return .init(seed: .init(id: "p\(index)", objectID: "e\(index)", title: "地点\(index)", coordinate: coordinate, assetID: "event"), x: screen.x, y: screen.y)
        }
        return SpatialMarkerPacking.layout(points, width: native.bounds.width, height: native.bounds.height,
            showTitles: native.region.span.longitudeDelta < 1.5, retainOffscreen: true).nodes.count
    }
    func run() async throws {
        window = NSWindow(contentRect: .init(x: 100, y: 80, width: 1000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ReadingBook 轨迹更新 · 原生回归"; window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: TrajectoryFixtureView(input: input)); window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(700))
        guard let native = map(host) else { throw ReadingError.invalid("Native map missing") }
        let identity = ObjectIdentifier(native), originalRegion = native.region
        let original = [[26.3, 80.0], [26.3, 82.8], [26.3, 84.9]]
        let changed = [[26.4, 80.1], [26.5, 82.9], [26.6, 85.0]]
        let phases: [(String, Int, [[Double]])] = [
            ("initial", 80, []), ("largeThree", 80, original),
            ("crossBelowTwo", 1, Array(original.prefix(2))),
            ("smallThree", 1, original), ("sameCountNewCoordinates", 1, changed),
            ("clear", 0, []), ("crossAboveThree", 80, original),
            ("largeTwo", 80, Array(original.prefix(2)))
        ]
        for (name, count, expected) in phases {
            input.count = count; input.sequence = expected.map { .init(latitude: $0[0], longitude: $0[1]) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            repeat {
                try await Task.sleep(for: .milliseconds(20))
                if native.annotations.filter({ !($0 is MKUserLocation) }).count == expectedMarkerCount(count, native),
                   matches(coordinates(native), expected) { break }
            } while ProcessInfo.processInfo.systemUptime < deadline
            let actual = coordinates(native), region = native.region
            checks[name + "Markers"] = native.annotations.filter { !($0 is MKUserLocation) }.count == expectedMarkerCount(count, native)
            checks[name + "Trajectory"] = matches(actual, expected)
            checks[name + "SameMap"] = map(host).map(ObjectIdentifier.init) == identity
            checks[name + "PreservesCamera"] = abs(region.center.latitude-originalRegion.center.latitude) < 1e-6
                && abs(region.center.longitude-originalRegion.center.longitude) < 1e-6
                && abs(region.span.latitudeDelta-originalRegion.span.latitudeDelta) < 1e-6
            rows.append(["phase": name, "markers": native.annotations.count, "sourceMarkers": count,
                "expectedLODMarkers": expectedMarkerCount(count, native), "coordinates": actual, "expected": expected])
        }
        guard checks.count == 32, checks.values.allSatisfy({ $0 }) else { throw ReadingError.invalid("Stale native map content") }
    }
    func finish(_ error: String?) throws {
        let value: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error ?? NSNull(),
            "checks": checks, "checkCount": checks.count, "observations": rows,
            "originalLibraryUsed": false, "realNetworkRequests": 0,
            "scope": "Exact private product renderer; fixture state changes; public native MapKit coordinates and map identity."]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("result.json"))
    }
}
@main private enum TrajectoryContentMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.appearance = NSAppearance(named: .aqua)
        let runner = TrajectoryContentRunner(); app.delegate = runner; app.run(); withExtendedLifetime(runner) {}
    }
}
