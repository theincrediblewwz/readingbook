import Foundation
import XCTest
@testable import ReadingCore

final class TemporalSourceOrderTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let units = [SourceUnit(id: "fire", order: 50, chapter: "火攻", page: 51, text: "十一月二十日，火攻开始。"),
                     SourceUnit(id: "retreat", order: 51, chapter: "撤退", page: 52, text: "曹操随后退往华容。"),
                     SourceUnit(id: "later", order: 52, chapter: "后文", page: 53, text: "后文补叙。")]
        var book = BookProject(title: "日期与出处", originalName: "test.txt", sourceHash: "source", units: units)
        PluginEngine.seed(&book)
        let proof = units.map { Evidence(unitID: $0.id, quote: $0.text) }
        book.entities = [.init(id: "a", typeID: "place", name: "甲地", evidence: [proof[0]]),
                         .init(id: "b", typeID: "place", name: "乙地", evidence: [proof[0]])]
        book.events = zip(["fire", "retreat", "later"], proof).map { .init(id: $0.0, name: $0.0, evidence: [$0.1]) }
        book.relations = [.init(id: "route", fromID: "a", toID: "b", label: "撤退", evidence: [proof[1]])]
        let anchors = try units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.id, quote: $0.text, in: book) }
        let date = TemporalExtent(sourceText: "十一月二十日", calendar: "建安", start: .init(year: 12, month: 11, day: 20), precision: .day, uncertainty: .exact)
        book.temporalKnowledge = .init(anchors: anchors, eventMetadata: [
            .init(eventID: "fire", kind: "fire", extent: date, sourceAnchorIDs: [anchors[0].id], assertion: .explicit),
            .init(eventID: "retreat", kind: "retreat", sourceAnchorIDs: [anchors[1].id], assertion: .explicit)],
            relationMetadata: [.init(id: "route-time", relationID: "route", validity: date,
                sourceAnchorIDs: [anchors[1].id], assertion: .explicit)])
        return book
    }
    private func encoded(_ book: BookProject) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(book) }

    func testMixedDatesUseSourceCoordinatesWithoutMutatingSavedDatesOrProject() throws {
        let book = try fixture(), before = try encoded(book)
        let events = try TemporalKnowledgeRuntime.events(in: book, boundary: .all)
        XCTAssertEqual(events.map { $0.sourceExtent?.narrativeStart }, [50, 51, 52])
        XCTAssertEqual(events.first?.extent.calendar, "建安"); XCTAssertEqual(events.first?.extent.start?.day, 20)
        XCTAssertEqual(events[1].extent.precision, .unknown)
        XCTAssertEqual(TemporalAxis.preferred(for: events.map { [$0.extent, $0.sourceExtent].compactMap { $0 } }), "narrative-domain:source-order")
        XCTAssertEqual(TemporalKnowledgeRuntime.eventSourceExtents(in: book, boundary: .all), events.compactMap(\.sourceExtent))
        let dates = events.prefix(1).map { [$0.extent, $0.sourceExtent].compactMap { $0 } }
        XCTAssertEqual(TemporalAxis.preferred(for: dates), "calendar-day:建安", "同样完整时仍优先原有日期轴")
        XCTAssertEqual(try encoded(book), before)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("sourceExtent"))
    }

    func testSourcePointAndWindowFilterDatedAndUndatedEventsByTheirOwnProof() throws {
        let book = try fixture()
        let point = try TemporalKnowledgeRuntime.events(in: book, at: .ordered(51, domain: "source-order"), boundary: .all)
        XCTAssertEqual(point.map(\.object.id), ["retreat"]); XCTAssertEqual(point.first?.match, .matches)
        let window = try TemporalKnowledgeRuntime.events(in: book, within: .ordered(from: 50, to: 51, domain: "source-order"), boundary: .all)
        XCTAssertEqual(window.map(\.object.id), ["fire", "retreat"])
        XCTAssertEqual(window.first?.extent.start?.day, 20)
        let date = try TemporalKnowledgeRuntime.events(in: book, at: .date(.init(year: 12, month: 11, day: 20), calendar: "建安"), boundary: .all)
        XCTAssertEqual(date.first?.match, .matches); XCTAssertEqual(date.first?.extent.precision, .day)
        XCTAssertEqual(date.first(where: { $0.object.id == "retreat" })?.match, .unknown)
        XCTAssertTrue(try TemporalKnowledgeRuntime.relations(in: book, within: .ordered(from: 50, to: 50, domain: "source-order"), boundary: .all).isEmpty)
        let route = try TemporalKnowledgeRuntime.relations(in: book, at: .ordered(51, domain: "source-order"), boundary: .all)
        XCTAssertEqual(route.first?.match, .matches); XCTAssertEqual(route.first?.metadata?.validity.start?.day, 20)
        XCTAssertEqual(route.first?.sourceExtent?.narrativeStart, 51)
    }

    func testSourceCoordinatesRespectProofBoundariesAndDoNotManufacturePresence() throws {
        var book = try fixture()
        book.events[0].participantIDs = ["a"]
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: ["fire"])
        let events = try TemporalKnowledgeRuntime.events(in: book, boundary: boundary)
        XCTAssertEqual(events.map(\.object.id), ["fire"])
        XCTAssertEqual(TemporalKnowledgeRuntime.eventSourceExtents(in: book, boundary: boundary), events.compactMap(\.sourceExtent))
        XCTAssertTrue(try TemporalKnowledgeRuntime.relations(in: book, at: .ordered(51, domain: "source-order"), boundary: boundary).isEmpty)
        let person = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "a", in: book, at: .ordered(50, domain: "source-order"), boundary: .all)
        XCTAssertTrue(person.presences.isEmpty); XCTAssertTrue(person.footprints.isEmpty); XCTAssertTrue(person.participations.isEmpty)
        book.events[0].evidence.append(.init(unitID: "later", quote: "后文补叙。"))
        XCTAssertTrue(TemporalKnowledgeRuntime.eventSourceExtents(in: book, boundary: boundary).isEmpty)
    }
}
