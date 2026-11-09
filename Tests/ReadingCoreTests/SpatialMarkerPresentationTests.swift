import Foundation
import XCTest
@testable import ReadingCore

final class SpatialMarkerPresentationTests: XCTestCase {
    private func point(_ id: String, _ x: Double, _ y: Double, affinity: String? = nil) -> SpatialMarkerScreenPoint {
        .init(seed: .init(id: id, objectID: id, title: "记录" + id,
            coordinate: .init(latitude: 30, longitude: 110), assetID: "event", affinityID: affinity), x: x, y: y)
    }
    func testAssetsAcceptFreeKindsAndUseTitlesOnlyAsDisplayHints() {
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "火攻").id, "fire")
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "密渡").id, "water")
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "retreat", title: "火攻后撤退").id, "retreat")
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "event", title: "黃蓋火攻").id, "fire")
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "自定义登月", title: "任意事件").id, "event")
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "entityLocation", title: "火攻镇", fallback: "place").id, "place")
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "presence", title: "火攻将军", fallback: "person").id, "person")
        XCTAssertEqual(Set(SpatialMarkerAssets.all.map(\.id)).count, SpatialMarkerAssets.all.count)
    }
    func testDistanceGroupsPreserveEveryIdentityAndNeverInventBattleMembership() {
        let source = [point("a", 80, 90), point("b", 90, 100), point("c", 360, 200)]
        let result = SpatialMarkerPacking.layout(source, width: 800, height: 600)
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(Set(result.nodes.flatMap(\.members).map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(result.nodes.first?.title, "同处记录")
        XCTAssertNil(result.nodes.first?.members.first?.affinityID)
        XCTAssertEqual(result.nodes.first?.coordinate, source[0].seed.coordinate)
        XCTAssertEqual(source[0].seed.coordinate, .init(latitude: 30, longitude: 110))
    }
    func testRealDistanceRatherThanBucketBoundariesControlsMembership() {
        let original = [point("a", 84, 150), point("b", 122, 150), point("c", 180, 150)]
        let moved = original.map { SpatialMarkerScreenPoint(seed: $0.seed, x: $0.x + 17, y: $0.y + 11) }
        let a = SpatialMarkerPacking.layout(original, width: 800, height: 600)
        let b = SpatialMarkerPacking.layout(moved.reversed(), width: 800, height: 600)
        XCTAssertEqual(a.nodes.map { $0.members.map(\.id) }, b.nodes.map { $0.members.map(\.id) })
        XCTAssertEqual(a.nodes.map(\.id), b.nodes.map(\.id))
    }
    func testLeaderBoundsStopTransitiveChainsAndZoomRevealsDetails() {
        let source = (0..<10).map { point(String(format: "%02d", $0), 60 + Double($0) * 30, 120) }
        let far = SpatialMarkerPacking.layout(source, width: 1000, height: 600)
        let near = SpatialMarkerPacking.layout(source.map { .init(seed: $0.seed, x: $0.x * 2, y: $0.y) }, width: 1200, height: 600)
        XCTAssertEqual(far.nodes.count, 5)
        XCTAssertEqual(near.nodes.count, 10)
        XCTAssertTrue(far.nodes.allSatisfy { $0.members.count <= 2 })
        XCTAssertEqual(Set(far.nodes.flatMap(\.members).map(\.id)), Set(near.nodes.flatMap(\.members).map(\.id)))
    }
    func testSelectedObjectsAndRoutesStayIndividuallyReachable() {
        var route = point("route", 110, 110); route.seed.objectID = nil; route.seed.routeID = "r"
        let result = SpatialMarkerPacking.layout([point("a", 100, 100), point("b", 105, 100), route], width: 600, height: 500,
            selectedObjectIDs: ["a"], selectedRouteID: "r")
        XCTAssertEqual(result.nodes.count, 3)
        XCTAssertEqual(result.nodes.filter(\.isSelected).count, 2)
        XCTAssertTrue(result.nodes.filter(\.isSelected).allSatisfy { !$0.isGroup && $0.showsTitle })
    }
    func testExplicitParentsAreNotMergedWithUnrelatedCampaignsOrUnknowns() {
        var a = point("a", 150, 150, affinity: "campaign-a"); a.seed.affinityTitle = "明载战役"
        var b = point("b", 152, 150, affinity: "campaign-a"); b.seed.affinityTitle = "明载战役"
        let c = point("c", 151, 150, affinity: "campaign-b"), d = point("d", 150, 151)
        let result = SpatialMarkerPacking.layout([a, b, c, d], width: 800, height: 600)
        XCTAssertEqual(result.nodes.count, 3)
        XCTAssertEqual(result.nodes.first?.title, "明载战役")
        XCTAssertEqual(result.nodes.first?.members.map(\.id), ["a", "b"])
    }
    func testDuplicatesAndInvalidOffscreenCoordinatesDoNotBecomeMarkers() {
        var bad = point("bad", 100, 100); bad.seed.coordinate.latitude = .nan
        let result = SpatialMarkerPacking.layout([point("a", 80, 90), point("a", 80, 90), point("off", -400, 60), point("nan", .nan, 60), bad], width: 600, height: 500)
        XCTAssertEqual(result.candidateCount, 1); XCTAssertEqual(result.nodes.first?.members.first?.id, "a")
        XCTAssertTrue(SpatialMarkerPacking.layout([], width: .infinity, height: 500).nodes.isEmpty)
        XCTAssertTrue(SpatialMarkerPacking.layout([], width: 500, height: 500, radius: 0).nodes.isEmpty)
        XCTAssertTrue(SpatialMarkerPacking.layout(Array(repeating: point("x", 1, 1), count: 2049), width: 500, height: 500).nodes.isEmpty)
    }
    func testSparseLargeMapUsesBoundedNeighbourAndLabelChecks() {
        let points = (0..<2048).map { point(String(format: "%04d", $0), 50 + Double($0 % 64) * 60, 50 + Double($0 / 64) * 60) }
        let result = SpatialMarkerPacking.layout(points, width: 4000, height: 2100)
        XCTAssertEqual(result.nodes.count, 2048)
        XCTAssertLessThan(result.distanceChecks, 2048 * 10)
        XCTAssertLessThan(result.overlapChecks, 2048 * 20)
    }
    func testGroupBadgesReserveTheirFullVisualAndPointerArea() {
        let result = SpatialMarkerPacking.layout([point("a", 100, 150), point("b", 102, 150), point("c", 164, 150), point("d", 166, 150)], width: 800, height: 600)
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertTrue(result.nodes.allSatisfy(\.isGroup))
        XCTAssertGreaterThanOrEqual(abs(result.nodes[1].offsetY - result.nodes[0].offsetY), 44)
    }
    func testSeedProjectionUsesSharedIDsAndLeavesStoredKnowledgeUntouched() throws {
        let points = [CompositionMapPoint(id: "event.e.place", targetID: "e", title: "黃蓋火攻", subtitle: "赤壁",
            latitude: 30, longitude: 110, evidence: [], kind: "eventLocation", markerKind: "event")]
        let seeds = SpatialMarkerSeeds.make(points: points, routes: [])
        XCTAssertEqual(seeds.first?.objectID, "e"); XCTAssertEqual(seeds.first?.assetID, "fire")
        XCTAssertNil(seeds.first?.affinityID); XCTAssertNil(points[0].affinityID)
        XCTAssertEqual(points[0].markerKind, "event")
        XCTAssertEqual(SpatialMarkerPacking.bootstrap(seeds).flatMap(\.members), seeds)
    }
    func testLegacyViewportDecodesAndGroupsAreBounded() throws {
        let old = try JSONDecoder().decode(ReadingMapViewport.self, from: Data(#"{"partID":"map","latitude":30,"longitude":110,"latitudeDelta":3,"longitudeDelta":3,"objectIDs":[],"visibleRouteIDs":[],"projectedRouteIDs":[]}"#.utf8))
        XCTAssertNil(old.markerGroups); XCTAssertTrue(old.isValid)
        var new = old; new.markerGroups = [.init(id: "group", objectIDs: ["a", "b"], routeIDs: ["r"])]
        XCTAssertTrue(new.isValid)
        XCTAssertEqual(try JSONDecoder().decode(ReadingMapViewport.self, from: JSONEncoder().encode(new)), new)
        new.markerGroups = Array(repeating: .init(id: "group", objectIDs: [], routeIDs: []), count: 513)
        XCTAssertFalse(new.isValid)
    }
    func testGroupReceiptReappliesScopeAndNeverLeaksInternalLeaderOrChronology() async throws {
        var book = BookProject(id: "b", title: "范围", originalName: "book.txt", sourceHash: "h", units: [
            .init(id: "u1", order: 0, chapter: "一", page: 1, text: "甲地。"), .init(id: "u2", order: 1, chapter: "二", page: 2, text: "秘密地点。")])
        PluginEngine.seed(&book)
        book.entities = [.init(id: "a", typeID: "place", name: "甲地", evidence: [.init(unitID: "u1", quote: "甲地。")]),
                         .init(id: "secret", typeID: "place", name: "秘密地点", evidence: [.init(unitID: "u2", quote: "秘密地点。")])]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        let map = ReadingMapViewport(partID: "map", latitude: 30, longitude: 110, latitudeDelta: 3, longitudeDelta: 3,
            objectIDs: [], visibleRouteIDs: [], projectedRouteIDs: [], markerGroups: [.init(id: "secret-leader", objectIDs: ["a", "secret"], routeIDs: ["secret-route"])])
        let workspace = ReadingWorkspaceSnapshot(bookID: "b", sourceHash: "h", rendererID: "composition", visibleObjects: .init(rendererID: "composition", objectIDs: []), mapViewports: [map])
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book,
            hostTools: .init(viewActions: [], performViewAction: { _, _ in Data() }, readWorkspace: { workspace }))
        let output = try await session.execute(name: "workspace_context_get", arguments: [:], maximumBytes: 8000)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let maps = try XCTUnwrap(root["mapViewports"] as? [[String: Any]])
        XCTAssertEqual(maps[0]["visibleObjectCount"] as? Int, 0)
        XCTAssertEqual(maps[0]["groupedObjectCount"] as? Int, 1)
        XCTAssertEqual(maps[0]["markerGroupCount"] as? Int, 1)
        XCTAssertFalse(output.contains("secret")); XCTAssertTrue(output.contains("not chronology"))
        XCTAssertTrue(output.contains("不是全程可见"))
        try session.recordHostReceipt(output, tool: "workspace_context_get")
        let summary = try XCTUnwrap(session.closingHostReceiptSummaries().last?["actualView"] as? [String: Any])
        let closing = try XCTUnwrap(summary["mapViewports"] as? [[String: Any]])
        XCTAssertEqual(closing[0]["groupedObjectCount"] as? Int, 1)
        XCTAssertEqual(closing[0]["visibleObjectCount"] as? Int, 0)
    }
}
