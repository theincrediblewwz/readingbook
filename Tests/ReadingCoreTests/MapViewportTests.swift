import Foundation
import XCTest
@testable import ReadingCore

final class MapViewportTests: XCTestCase {
    func testFitSpaceAvoidsInspectorAndTimelineInsteadOfUsingCanvasCenter() throws {
        let viewport = CGRect(x: 0, y: 0, width: 1320, height: 860)
        let cards = [CGRect(x: 12, y: 12, width: 420, height: 480), CGRect(x: 320, y: 560, width: 680, height: 280)]
        let available = try XCTUnwrap(SpatialViewportVisibility.availableRect(in: viewport, excluding: cards, padding: 28))
        XCTAssertTrue(available.midX > viewport.midX); XCTAssertTrue(available.midY < viewport.midY)
        XCTAssertTrue(cards.allSatisfy { !$0.intersects(available) })
        XCTAssertTrue(viewport.contains(available)); XCTAssertTrue(available.width > 800); XCTAssertTrue(available.height > 450)
        XCTAssertEqual(SpatialViewportVisibility.availableRect(in: viewport, excluding: cards.reversed(), padding: 28), available)
    }
    func testFitSpaceHandlesTotalOcclusionInvalidGeometryAndEmptyCards() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 80)
        XCTAssertNil(SpatialViewportVisibility.availableRect(in: viewport, excluding: [viewport]))
        XCTAssertNil(SpatialViewportVisibility.availableRect(in: .zero, excluding: []))
        XCTAssertNil(SpatialViewportVisibility.availableRect(in: CGRect(x: Double.nan, y: 0, width: 100, height: 80), excluding: []))
        XCTAssertNil(SpatialViewportVisibility.availableRect(in: viewport, excluding: [.infinite]))
        XCTAssertNil(SpatialViewportVisibility.availableRect(in: viewport, excluding: [], padding: -1))
        XCTAssertEqual(SpatialViewportVisibility.availableRect(in: viewport, excluding: [.zero], padding: 4), viewport.insetBy(dx: 4, dy: 4))
    }
    func testFitSpaceMatchesSmallGridExhaustiveOracle() {
        let viewport = CGRect(x: 0, y: 0, width: 6, height: 6)
        let candidates = [CGRect(x: 0, y: 0, width: 2, height: 3), CGRect(x: 2, y: 2, width: 3, height: 2), CGRect(x: 3, y: 0, width: 3, height: 1), CGRect(x: 1, y: 5, width: 4, height: 1)]
        for mask in 0..<16 {
            let blocks = candidates.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            var largest = 0.0
            for x in 0..<6 { for y in 0..<6 { for w in 1...(6-x) { for h in 1...(6-y) {
                let rect = CGRect(x: x, y: y, width: w, height: h)
                if blocks.allSatisfy({ $0.intersection(rect).width <= 0 || $0.intersection(rect).height <= 0 || $0.intersection(rect).isNull }) { largest = max(largest, Double(w*h)) }
            } } } }
            let result = SpatialViewportVisibility.availableRect(in: viewport, excluding: blocks, padding: 0)
            XCTAssertEqual(result.map { Double($0.width * $0.height) } ?? 0, largest)
        }
    }
    func testPointVisibilityExcludesViewportAndFloatingCards() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100), card = CGRect(x: 40, y: 20, width: 60, height: 60)
        XCTAssertTrue(SpatialViewportVisibility.contains(.init(x: 20, y: 50), in: rect, excluding: [card]))
        XCTAssertFalse(SpatialViewportVisibility.contains(.init(x: 50, y: 50), in: rect, excluding: [card]))
        XCTAssertFalse(SpatialViewportVisibility.contains(.init(x: -1, y: 50), in: rect, excluding: []))
        XCTAssertFalse(SpatialViewportVisibility.contains(.init(x: Double.nan, y: 50), in: rect, excluding: []))
    }
    func testVisibleRouteSegmentIsNotConfusedWithProjectedEndpoints() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let crossing = [CGPoint(x: -40, y: 50), CGPoint(x: 140, y: 50)]
        XCTAssertTrue(SpatialViewportVisibility.intersects(crossing, viewport: rect, excluding: []))
        XCTAssertFalse(SpatialViewportVisibility.intersects(crossing, viewport: rect, excluding: [rect]))
        XCTAssertTrue(SpatialViewportVisibility.intersects(crossing, viewport: rect, excluding: [.init(x: 40, y: 0, width: 60, height: 100)]))
        XCTAssertFalse(SpatialViewportVisibility.intersects(crossing, viewport: rect, excluding: [.init(x: 0, y: 0, width: 60, height: 100), .init(x: 40, y: 0, width: 60, height: 100)]))
        XCTAssertFalse(SpatialViewportVisibility.intersects([.init(x: -10, y: -10), .init(x: -1, y: -1)], viewport: rect, excluding: []))
        XCTAssertFalse(SpatialViewportVisibility.intersects([.init(x: 40, y: Double.infinity), .init(x: 50, y: 20)], viewport: rect, excluding: []))
        XCTAssertFalse(SpatialViewportVisibility.intersects(crossing, viewport: .zero, excluding: []))
    }
    func testViewportAndClockRejectNonfiniteOrUnboundedMetadata() throws {
        var map = ReadingMapViewport(partID: "map", latitude: 30, longitude: 110, latitudeDelta: 3, longitudeDelta: 3,
            objectIDs: [], visibleRouteIDs: [], projectedRouteIDs: [])
        XCTAssertTrue(map.isValid)
        XCTAssertEqual(try JSONDecoder().decode(ReadingMapViewport.self, from: JSONEncoder().encode(map)), map)
        map.latitude = .nan; XCTAssertFalse(map.isValid)
        map.latitude = 91; XCTAssertFalse(map.isValid)
        map.latitude = 30; map.longitudeDelta = -1; XCTAssertFalse(map.isValid)
        var clock = ReadingViewTimeWindow(groupID: "main", axis: "gregorian", from: 1, to: 10, current: 4)
        XCTAssertTrue(clock.isValid)
        clock.current = 20; XCTAssertFalse(clock.isValid)
        clock.current = .infinity; XCTAssertFalse(clock.isValid)
    }
    func testMapToolSnapshotReappliesEvidenceBoundaryAndDoesNotCallProjectionVisible() async throws {
        var project = BookProject(id: "viewport-book", title: "范围", originalName: "book.txt", sourceHash: "hash", units: [
            .init(id: "u1", order: 0, chapter: "第一回", page: 1, text: "甲地进攻乙地。"),
            .init(id: "u2", order: 1, chapter: "第二回", page: 2, text: "乙地撤往丙地。")])
        PluginEngine.seed(&project)
        let p1 = Evidence(unitID: "u1", quote: project.units[0].text), p2 = Evidence(unitID: "u2", quote: project.units[1].text)
        project.entities = [.init(id: "a", typeID: "place", name: "甲地", evidence: [p1]), .init(id: "b", typeID: "place", name: "乙地", evidence: [p1]), .init(id: "c", typeID: "place", name: "丙地", evidence: [p2])]
        project.relations = [.init(id: "attack", fromID: "a", toID: "b", label: "进攻", evidence: [p1]), .init(id: "secret-retreat", fromID: "b", toID: "c", label: "撤退", evidence: [p2])]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: .init(unitID: "u1", page: 1))
        let map = ReadingMapViewport(partID: "map", latitude: 30, longitude: 110, latitudeDelta: 3, longitudeDelta: 3,
            objectIDs: ["a", "c"], visibleRouteIDs: ["secret-retreat"], projectedRouteIDs: ["attack", "secret-retreat"])
        let workspace = ReadingWorkspaceSnapshot(bookID: project.id, sourceHash: project.sourceHash, rendererID: "composition",
            visibleObjects: .init(rendererID: "composition", objectIDs: ["a", "c"]), mapViewports: [map], sourceScopeTitle: "第 1 页")
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project,
            hostTools: .init(viewActions: [], performViewAction: { _, _ in Data() }, readWorkspace: { workspace }))
        let result = try await session.execute(name: "workspace_context_get", arguments: [:], maximumBytes: 8000)
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let maps = try XCTUnwrap(data["mapViewports"] as? [[String: Any]])
        XCTAssertEqual(maps.count, 1)
        XCTAssertEqual(maps[0]["projectedRouteCount"] as? Int, 1)
        XCTAssertEqual(maps[0]["visibleRouteCount"] as? Int, 0)
        XCTAssertEqual(maps[0]["visibleObjectIDs"] as? [String], ["a"])
        XCTAssertFalse(result.contains("secret-retreat")); XCTAssertFalse(result.contains("\"c\""))
        let visible = try await session.execute(name: "visible_objects_list", arguments: [:], maximumBytes: 4000)
        XCTAssertTrue(visible.contains("a")); XCTAssertFalse(visible.contains("\"c\""))
        var invalid = workspace; invalid.mapViewports?[0].latitude = .nan
        let invalidSnapshot = invalid
        var rejected = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project,
            hostTools: .init(viewActions: [], performViewAction: { _, _ in Data() }, readWorkspace: { invalidSnapshot }))
        do { _ = try await rejected.execute(name: "workspace_context_get", arguments: [:], maximumBytes: 4000); XCTFail("无效相机不可传给模型") } catch {}
    }
    func testOlderWorkspaceSnapshotDecodesWithoutMapFields() throws {
        let old = try JSONDecoder().decode(ReadingWorkspaceSnapshot.self, from: Data(#"{"bookID":"b","sourceHash":"h","selectedObjectIDs":[],"selectedNodeIDs":[]}"#.utf8))
        XCTAssertNil(old.mapViewports); XCTAssertNil(old.timeWindows); XCTAssertNil(old.sourceScopeTitle)
    }
}
