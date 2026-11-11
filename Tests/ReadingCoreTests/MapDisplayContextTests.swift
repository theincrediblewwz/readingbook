import Foundation
import XCTest
@testable import ReadingCore

final class MapDisplayContextTests: XCTestCase {
    private func fixture() throws -> BookProject {
        var book = BookProject(id: "context", title: "一次研究", originalName: "source.txt", sourceHash: "h", units: [
            .init(id: "u1", order: 0, chapter: "记录", page: 1, text: "完整研究。甲站校验。随后从甲站向乙站转运样本。"),
            .init(id: "u2", order: 1, chapter: "后文", page: 2, text: "尚未分享的发现。")])
        PluginEngine.seed(&book)
        let root = Evidence(unitID: "u1", quote: "完整研究。"), one = Evidence(unitID: "u1", quote: "甲站校验。")
        let two = Evidence(unitID: "u1", quote: "随后从甲站向乙站转运样本。"), hidden = Evidence(unitID: "u2", quote: "尚未分享的发现。")
        book.entities = [.init(id: "a", typeID: "place", name: "甲站", latitude: 31, longitude: 121, evidence: [one]),
                         .init(id: "b", typeID: "place", name: "乙站", latitude: 31.1, longitude: 121.1, evidence: [two])]
        book.events = [.init(id: "root", name: "完整研究", evidence: [root]),
                       .init(id: "e1", name: "校验", placeIDs: ["a"], evidence: [one]),
                       .init(id: "e2", name: "转运样本", placeIDs: ["a", "b"], evidence: [two]),
                       .init(id: "future", name: "隐藏发现", evidence: [hidden])]
        let proofs = try [root, one, two, hidden].map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.unitID, quote: $0.quote, in: book) }
        book.relations = [.init(id: "r1", fromID: "a", toID: "b", label: "送样", evidence: [two]),
                          .init(id: "r2", fromID: "b", toID: "a", label: "回程", evidence: [two])]
        book.temporalKnowledge = .init(anchors: proofs, eventMetadata: [
            .init(eventID: "root", kind: "研究", sourceAnchorIDs: [proofs[0].id]),
            .init(eventID: "e1", kind: "特殊校验", parentEventID: "root", phaseOrder: 1, sourceAnchorIDs: [proofs[1].id]),
            .init(eventID: "e2", kind: "特殊校验", parentEventID: "root", phaseOrder: 2, sourceAnchorIDs: [proofs[2].id]),
            .init(eventID: "future", kind: "未分享类别", sourceAnchorIDs: [proofs[3].id])], relationMetadata: [
                .init(id: "m1", relationID: "r1", validity: .init(), sourceAnchorIDs: [proofs[2].id], spatial: .init(kind: "样本转运", eventID: "e2")),
                .init(id: "m2", relationID: "r2", validity: .init(), sourceAnchorIDs: [proofs[2].id], spatial: .init(kind: "设备返回", eventID: "e1"))])
        return book
    }
    private func definition() -> CompositionDefinition {
        .init(sources: [.init(id: "places", collection: .objects, scope: .book, typeIDs: ["place"]),
                        .init(id: "events", collection: .events, scope: .book),
                        .init(id: "actions", collection: .relations, scope: .book)],
              parts: [.init(id: "map", primitive: .map, sourceID: "places", routeSourceID: "actions"),
                      .init(id: "details", primitive: .objectDetail, sourceID: "events")],
              layout: [.init(id: "root", kind: .overlay, children: ["map-node", "details-node"]),
                       .init(id: "map-node", kind: .part, partID: "map"),
                       .init(id: "details-node", kind: .part, partID: "details", presentation: .contextual)], rootID: "root")
    }
    func testPlaceOnlyMapActionsRetainTheAdmittedEventFamilyWithoutMovingFacts() throws {
        let book = try fixture(), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(book), projections = try CompositionRuntime.project(definition(), in: book)
        let routes = try XCTUnwrap(projections["actions"]?.mapRoutes)
        XCTAssertEqual(Set(routes.map(\.affinityID)), ["root"], "routes=\(routes.map { ($0.relationID, $0.affinityID) }) sources=\(projections.mapValues { $0.items.map(\.id) })")
        XCTAssertEqual(Set(routes.map(\.affinityTitle)), ["完整研究"], "titles=\(routes.map(\.affinityTitle))")
        let points = try XCTUnwrap(projections["places"]?.mapPoints)
        XCTAssertEqual(Set(points.map(\.targetID)), ["a", "b"], "points=\(points.map(\.targetID))")
        let seeds = SpatialMarkerSeeds.make(points: points, routes: routes)
        XCTAssertEqual(Set(seeds.filter { $0.routeID != nil }.map(\.affinityID)), ["root"])
        XCTAssertTrue(seeds.filter { $0.objectID != nil }.allSatisfy { $0.affinityID == nil })
        XCTAssertEqual(try encoder.encode(book), before)
    }
    func testHiddenParentAndHiddenMetadataCannotNameOrJoinAnActionFamily() throws {
        var book = try fixture()
        book.events[0].evidence = book.events[3].evidence
        let cutoff = KnowledgeReadBoundary(allowedUnitIDs: ["u1"])
        let routes = try SpatialKnowledgeRuntime.routes(in: book, boundary: cutoff)
        XCTAssertEqual(routes.count, 2); XCTAssertTrue(routes.allSatisfy { $0.affinityID == nil && $0.affinityTitle == nil })
        book = try fixture()
        book.temporalKnowledge!.eventMetadata[1].sourceAnchorIDs = [book.temporalKnowledge!.anchors[3].id]
        let value = try SpatialKnowledgeRuntime.routes(in: book, boundary: cutoff)
        XCTAssertNil(value.first { $0.eventID == "e1" }?.affinityID)
        XCTAssertEqual(value.first { $0.eventID == "e2" }?.affinityID, "root")
    }
    func testCyclesAndAbsentEventMembershipDoNotInventCampaigns() throws {
        var book = try fixture()
        book.temporalKnowledge!.eventMetadata[0].parentEventID = "e2"
        let routes = try SpatialKnowledgeRuntime.routes(in: book)
        XCTAssertTrue(routes.allSatisfy { $0.affinityID == nil })
        book.temporalKnowledge!.relationMetadata[0].spatial!.eventID = nil
        XCTAssertNil(try SpatialKnowledgeRuntime.routes(in: book).first { $0.relationID == "r1" }?.affinityID)
    }
    func testKindCatalogCountsOnlyFrozenSourcesAndOmitsTextAndIdentities() throws {
        let book = try fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        let sliced = try ReadingComponentProjection.project(snapshot, in: book)
        let catalog = try ReadingMapKindCatalog.make(in: sliced)
        XCTAssertFalse(catalog.partial); XCTAssertEqual(catalog.totalKinds, 4); XCTAssertEqual(catalog.totalRecords, 5)
        XCTAssertEqual(catalog.entries.first { $0.kind == "特殊校验" }?.count, 2)
        XCTAssertEqual(catalog.entries.filter { $0.actionCount > 0 }.map(\.kind), ["样本转运", "设备返回"])
        let encoded = try JSONEncoder().encode(catalog), text = String(decoding: encoded, as: UTF8.self)
        for hidden in ["未分享类别", "隐藏发现", "甲站校验。", "latitude", "sourceAnchor", "eventID", "relationID"] { XCTAssertFalse(text.contains(hidden)) }
        XCTAssertEqual(try JSONDecoder().decode(ReadingMapKindCatalog.self, from: encoded), catalog)
    }
    func testKindCatalogKeepsSelectionInsideOnePageAndReportsIncompleteResults() throws {
        let book = try fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: book,
            context: .init(unitID: "u1", selectedText: "甲站校验。", page: 1))
        let catalog = try ReadingMapKindCatalog.make(in: ReadingComponentProjection.project(snapshot, in: book))
        XCTAssertEqual(catalog.entries.map(\.kind), ["特殊校验"]); XCTAssertEqual(catalog.totalRecords, 1)
        let limited = try ReadingMapKindCatalog.make(in: book, maximumKinds: 1)
        XCTAssertTrue(limited.partial); XCTAssertEqual(limited.entries.count, 1); XCTAssertEqual(limited.totalKinds, 5)
        XCTAssertThrowsError(try ReadingMapKindCatalog.make(in: book, maximumKinds: 0))
        XCTAssertThrowsError(try ReadingMapKindCatalog.make(in: book, maximumKinds: 33))
    }
    func testKindCatalogIsDeterministicWithoutChangingFreeKindsOrBookBytes() throws {
        var book = try fixture(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(book), original = try ReadingMapKindCatalog.make(in: book)
        XCTAssertEqual(try encoder.encode(book), before)
        book.events.reverse(); book.relations.reverse(); book.temporalKnowledge!.eventMetadata.reverse(); book.temporalKnowledge!.relationMetadata.reverse()
        XCTAssertEqual(try ReadingMapKindCatalog.make(in: book), original)
        XCTAssertTrue(original.entries.contains { $0.kind == "特殊校验" })
    }
    func testSharedEventAndActionKindHasOneMappingKeyAndSeparateCounts() throws {
        var book = try fixture()
        book.temporalKnowledge!.relationMetadata[0].spatial!.kind = "特殊校验"
        let catalog = try ReadingMapKindCatalog.make(in: book)
        let matching = catalog.entries.filter { $0.kind == "特殊校验" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.eventCount, 2); XCTAssertEqual(matching.first?.actionCount, 1)
        XCTAssertEqual(matching.first?.count, 3)
        XCTAssertEqual(catalog.totalRecords, 6); XCTAssertEqual(catalog.totalKinds, 4)
        XCTAssertFalse(catalog.partial)
    }
    func testRouteContextUsesOneMatchingContextualCardAndKeepsOtherGroups() throws {
        let book = try fixture(), definition = definition(), projections = try CompositionRuntime.project(definition, in: book)
        let chosen = CompositionRouteContext.detailPartID(eventID: "e2", mapPartID: "map", definition: definition, projections: projections, selectedIDs: ["e2"])
        XCTAssertEqual(chosen, "details")
        var other = definition; other.parts[1].selectionGroup = "different"
        XCTAssertNil(CompositionRouteContext.detailPartID(eventID: "e2", mapPartID: "map", definition: other, projections: projections, selectedIDs: ["e2"]))
        other = definition; other.layout[2].presentation = .docked
        XCTAssertNil(CompositionRouteContext.detailPartID(eventID: "e2", mapPartID: "map", definition: other, projections: projections, selectedIDs: ["e2"]))
    }
    func testRouteContextFallsBackForNoEventHiddenRecordOrCollapsedCard() throws {
        let book = try fixture(), definition = definition(), projections = try CompositionRuntime.project(definition, in: book)
        for id in [nil, "missing", "e2"] as [String?] {
            XCTAssertNil(CompositionRouteContext.detailPartID(eventID: id, mapPartID: "map", definition: definition, projections: projections, selectedIDs: []))
        }
        XCTAssertNil(CompositionRouteContext.detailPartID(eventID: "e2", mapPartID: "map", definition: definition, projections: projections, selectedIDs: ["e2"], collapsed: ["details"]))
        XCTAssertNil(CompositionRouteContext.detailPartID(eventID: "e2", mapPartID: "unknown", definition: definition, projections: projections, selectedIDs: ["e2"]))
        var none = projections; none["events"]?.items = []
        XCTAssertNil(CompositionRouteContext.detailPartID(eventID: "e2", mapPartID: "map", definition: definition, projections: none, selectedIDs: ["e2"]))
    }
}
