import Foundation
import XCTest
@testable import ReadingCore

final class CompositionRouteSourcesTests: XCTestCase {
    private func fixture() throws -> BookProject {
        var book = BookProject(title: "独立行动图层合成回归", originalName: "book.txt", sourceHash: "route-source", units: [
            .init(id: "u1", order: 0, chapter: "第一回", page: 1, text: "208年，甲军从甲地进攻乙地；援军另由甲地调往乙地。"),
            .init(id: "u2", order: 1, chapter: "第二回", page: 2, text: "209年，乙军从乙地撤退至丙地。")])
        PluginEngine.seed(&book)
        let proof1 = Evidence(unitID: "u1", quote: book.units[0].text), proof2 = Evidence(unitID: "u2", quote: book.units[1].text)
        book.entities = [KnowledgeEntity(id: "a", typeID: "place", name: "甲地", latitude: 30, longitude: 110, evidence: [proof1]),
            KnowledgeEntity(id: "b", typeID: "place", name: "乙地", latitude: 30, longitude: 111, evidence: [proof1]),
            KnowledgeEntity(id: "c", typeID: "place", name: "丙地", latitude: 30, longitude: 112, evidence: [proof2])]
        book.events = [KnowledgeEvent(id: "battle", name: "进攻", startYear: 208, placeIDs: ["a", "b"], evidence: [proof1])]
        book.relations = [.init(id: "attack", fromID: "a", toID: "b", label: "进攻", evidence: [proof1]),
            .init(id: "retreat", fromID: "b", toID: "c", label: "撤退", evidence: [proof2]),
            .init(id: "reinforce", fromID: "a", toID: "b", label: "调兵", evidence: [proof1])]
        let a1 = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: proof1.quote, in: book)
        let a2 = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u2", quote: proof2.quote, in: book)
        book.temporalKnowledge = .init(anchors: [a1, a2], relationMetadata: [
            .init(id: "m1", relationID: "attack", validity: .init(sourceText: "208年", calendar: "gregorian", start: .init(year: 208), precision: .year, uncertainty: .exact), sourceAnchorIDs: [a1.id], assertion: .explicit, spatial: .init(kind: "进攻", eventID: "battle")),
            .init(id: "m2", relationID: "retreat", validity: .init(sourceText: "209年", calendar: "gregorian", start: .init(year: 209), precision: .year, uncertainty: .exact), sourceAnchorIDs: [a2.id], assertion: .explicit, spatial: .init(kind: "撤退")),
            .init(id: "m3", relationID: "reinforce", validity: .init(), sourceAnchorIDs: [a1.id], assertion: .explicit, spatial: .init(kind: "调兵"))])
        return book
    }
    private func definition(_ independent: Bool = true) -> CompositionDefinition {
        .init(sources: [.init(id: "events", collection: .events, scope: .book)] + (independent ? [.init(id: "actions", collection: .relations, scope: .book)] : []),
            parts: [.init(id: "map", primitive: .map, sourceID: "events", routeSourceID: independent ? "actions" : nil)],
            layout: [.init(id: "root", kind: .part, partID: "map")], rootID: "root")
    }
    func testIndependentActionsDoNotNeedInventedEventMembership() throws {
        let book = try fixture(), before = try CompositionRuntime.project(definition(false), in: book)
        XCTAssertEqual(before["events"]?.mapRoutes.map(\.relationID), ["attack"])
        let value = definition(), after = try CompositionRuntime.project(value, in: book)
        XCTAssertEqual(Set(after["actions"]?.mapRoutes.map(\.relationID) ?? []), ["attack", "retreat", "reinforce"])
        XCTAssertEqual(after["events"]?.items.map(\.id), ["battle"])
        XCTAssertNil(book.temporalKnowledge?.relationMetadata.first { $0.relationID == "retreat" }?.spatial?.eventID)
        XCTAssertEqual(try JSONDecoder().decode(CompositionDefinition.self, from: JSONEncoder().encode(value)), value)
    }
    func testActionSourceHonorsOwnFilterEvenWhenUnmatchedRouteSharesBothEndpoints() throws {
        let book = try fixture(); var value = definition()
        value.sources[1].filters = [.init(field: "label", operation: .equals, value: "进攻")]
        let after = try CompositionRuntime.project(value, in: book)
        XCTAssertEqual(after["actions"]?.mapRoutes.map(\.relationID), ["attack"])
        XCTAssertEqual(after["actions"]?.edges.map(\.id), ["attack"])
    }
    func testSharedTimeWindowFiltersDatedActionAndPreservesUnknownAction() throws {
        let book = try fixture(), value = definition()
        let after = try CompositionRuntime.project(value, in: book,
            windows: ["main": .date(from: .init(year: 209), to: .init(year: 209), calendar: "gregorian")])
        XCTAssertEqual(Set(after["actions"]?.mapRoutes.map(\.relationID) ?? []), ["retreat", "reinforce"])
        XCTAssertEqual(after["actions"]?.mapRoutes.first { $0.relationID == "reinforce" }?.timeMatch, .unknown)
        XCTAssertEqual(after["actions"]?.mapRoutes.first { $0.relationID == "retreat" }?.timeMatch, .matches)
    }
    func testIndependentSourceCannotWidenFrozenPageBoundary() throws {
        let book = try fixture(), context = ReadingContext(unitID: "u1", page: 1)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: context)
        let prepared = try CompositionRuntime.prepare(definition(), in: book, context: context, sourceSnapshot: snapshot)
        let after = try CompositionRuntime.project(prepared)
        XCTAssertEqual(Set(after["actions"]?.mapRoutes.map(\.relationID) ?? []), ["attack", "reinforce"])
        XCTAssertFalse((after["actions"]?.items.map(\.id) ?? []).contains("c"))
    }
    func testRouteBindingMustUseExistingRelationSourceAndSameTimeAndSelectionGroups() throws {
        let book = try fixture(), valid = definition()
        XCTAssertNoThrow(try CompositionRuntime.validate(valid, in: book))
        for kind in [0, 1, 2, 3, 4] {
            var value = valid
            switch kind {
            case 0: value.parts[0].routeSourceID = "missing"
            case 1: value.sources[1].collection = .documents
            case 2: value.sources[1].timeGroup = "other-time"
            case 3: value.sources[1].selectionGroup = "other-selection"
            default: value.parts[0].primitive = .timeline
            }
            do { try CompositionRuntime.validate(value, in: book); XCTFail("Invalid binding \(kind)") }
            catch let error as ReadingCompositionError {
                let path = kind == 2 ? "sources[1].timeGroup" : kind == 3 ? "sources[1].selectionGroup" : "parts[0].routeSourceID"
                let issue = try XCTUnwrap(error.issues.first { $0.path == path })
                if kind == 2 || kind == 3 { XCTAssertEqual(issue.expectedValue, "main"); XCTAssertNotEqual(issue.currentValue, issue.expectedValue) }
            }
        }
        let old = try JSONDecoder().decode(CompositionPart.self, from: Data(#"{"id":"map","primitive":"geo.map","sourceID":"events"}"#.utf8))
        XCTAssertNil(old.routeSourceID)
    }
}
