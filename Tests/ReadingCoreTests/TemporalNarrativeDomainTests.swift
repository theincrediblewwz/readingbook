import Foundation
import XCTest
@testable import ReadingCore

final class TemporalNarrativeDomainTests: XCTestCase {
    private func extent(_ order: Int, domain: String? = "source-order", end: Int? = nil) -> TemporalExtent {
        .init(sourceText: "将近三更", precision: .narrative, uncertainty: .exact, kind: end == nil ? .point : .interval,
              narrativeStart: order, narrativeEnd: end, assertion: .explicit, narrativeDomain: domain)
    }
    private func fixture() throws -> BookProject {
        let unit = SourceUnit(id: "u606", order: 605, chapter: "第四十九回", page: 606, text: "孔明正坐，忽聽得風聲響，正是將近三更，東南風起。")
        var value = BookProject(title: "叙事基准合成测试", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(unit.text.utf8)), units: [unit])
        PluginEngine.seed(&value)
        value.events = [.init(id: "wind", name: "起风", evidence: [.init(unitID: unit.id, quote: unit.text)])]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: unit.id, quote: unit.text, in: value)
        var time = extent(605); time.sourceText = "將近三更"
        value.temporalKnowledge = .init(anchors: [anchor], eventMetadata: [.init(eventID: "wind", extent: time, sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        return value
    }
    func testDifferentNarrativeScalesNeverCompareAsOneAxis() throws {
        let source = extent(605), chapters = extent(49, domain: "chapters"), legacy = extent(80, domain: nil)
        XCTAssertEqual(TemporalAxis.available([source, chapters, legacy]), ["narrative", "narrative-domain:chapters", "narrative-domain:source-order"])
        let axis = TemporalAxis("narrative-domain:source-order")
        XCTAssertEqual(axis.title, "原文顺序"); XCTAssertEqual(axis.value(source), 605)
        XCTAssertNil(axis.value(chapters)); XCTAssertNil(axis.value(legacy)); XCTAssertNil(TemporalAxis("narrative").value(source))
        XCTAssertEqual(axis.point(605), .ordered(605, domain: "source-order")); XCTAssertEqual(axis.parse("605"), 605)
        XCTAssertEqual(axis.window(from: 604, to: 606), .ordered(from: 604, to: 606, domain: "source-order"))
    }
    func testPointAndWindowMatchingKeepDomainsSeparate() throws {
        let source = extent(605), other = extent(605, domain: "stages")
        XCTAssertEqual(TemporalKnowledgeRuntime.match(source, at: .ordered(605, domain: "source-order")), .matches)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(source, at: .ordered(604, domain: "source-order")), .outside)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(source, at: .narrative(605)), .unknown)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(other, within: .ordered(from: 604, to: 606, domain: "source-order")), .unknown)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(source, within: .narrative(from: 604, to: 606)), .unknown)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(source, within: .ordered(from: 604, to: 606, domain: "source-order")), .matches)
    }
    func testOriginalUnitOrderIsValidatedRatherThanGuessedChapterNumber() throws {
        var value = try fixture(); try TemporalKnowledgeRuntime.validateStoredState(in: value)
        value.temporalKnowledge?.eventMetadata[0].extent?.narrativeStart = 49
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: value)) { error in
            XCTAssertTrue(error.localizedDescription.contains("605")); XCTAssertTrue(error.localizedDescription.contains("order"))
        }
    }
    func testSourceOrderCannotBorrowUnreferencedOrFutureUnit() throws {
        var value = try fixture()
        value.units.append(.init(id: "future", order: 700, chapter: "后文", page: 701, text: "后文"))
        value.temporalKnowledge?.eventMetadata[0].extent?.narrativeStart = 700
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: value))
    }
    func testDomainDoesNotCreateCalendarDatesOrChangeLegacyEncoding() throws {
        let data = Data(#"{"kind":"point","narrativeStart":49,"precision":"narrative","sourceText":"第四十九回","uncertainty":"exact"}"#.utf8)
        let old = try JSONDecoder().decode(TemporalExtent.self, from: data); XCTAssertNil(old.narrativeDomain)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; XCTAssertEqual(try encoder.encode(old), data)
        let source = extent(605); XCTAssertNil(source.calendar); XCTAssertNil(source.start)
        var invalid = source; invalid.precision = .day; invalid.calendar = "建安"; invalid.start = .init(year: 12, month: 11, day: 20)
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateExtent(invalid))
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validate(window: .ordered(from: 5, to: 4, domain: "source-order")))
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validate(window: .ordered(from: 1, to: 3, domain: "")))
    }
    func testSharedSourceOrderQueryRetainsClockWordsAndReadBoundary() throws {
        let value = try fixture()
        let events = try TemporalKnowledgeRuntime.events(in: value, at: .ordered(605, domain: "source-order"), boundary: .all)
        XCTAssertEqual(events.map(\.object.id), ["wind"]); XCTAssertEqual(events.first?.extent.sourceText, "將近三更")
        XCTAssertEqual(events.first?.extent.narrativeStart, 605)
        XCTAssertTrue(try TemporalKnowledgeRuntime.events(in: value, at: .ordered(605, domain: "source-order"), boundary: .init(allowedUnitIDs: [])).isEmpty)
        XCTAssertEqual(try TemporalKnowledgeRuntime.events(in: value, at: .ordered(49, domain: "chapters"), boundary: .all).first?.match, .unknown)
    }
    func testPreparedSourceSuppliesActualOrderWithoutChangingText() throws {
        let value = try fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: value, context: .init(unitID: "u606", page: 606))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: value)
        let payload = try XCTUnwrap(session.initialSource(maximumBytes: 20_000))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(body["actualReadFragments"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["order"] as? Int, 605); XCTAssertEqual(rows.first?["text"] as? String, value.units[0].text)
        let schema = try XCTUnwrap(ReadingProposalSchemas.extent["properties"] as? [String: Any]); XCTAssertNotNil(schema["narrativeDomain"])
    }
    func testAIViewWindowAcceptsDatesWithoutInventingOrdinalCoordinates() throws {
        let data = Data(#"{"at":{"calendar":"建安","year":12,"month":11,"day":20},"fromDate":{"year":12,"month":11,"day":20},"toDate":{"year":12,"month":11,"day":21}}"#.utf8)
        let value = try TemporalViewWindow(arguments: data, availableAxes: ["calendar-day:建安", "calendar:建安"])
        XCTAssertEqual(value.axis, "calendar-day:建安"); XCTAssertEqual(value.to-value.from, 1)
        XCTAssertEqual(TemporalAxis(value.axis).label(value.cursor), "12年11月20日")
        XCTAssertEqual(TemporalAxis(value.axis).window(from: value.from, to: value.to), .date(from: .init(year: 12, month: 11, day: 20), to: .init(year: 12, month: 11, day: 21), calendar: "建安"))
        XCTAssertThrowsError(try TemporalViewWindow(arguments: data, availableAxes: ["calendar-day:公历"]))
    }
    func testAIViewWindowNarrativeDomainAndLegacyYearRemainDistinct() throws {
        let data = Data(#"{"at":{"narrativeOrder":605,"narrativeDomain":"source-order"},"from":532,"to":624}"#.utf8)
        let value = try TemporalViewWindow(arguments: data, availableAxes: ["narrative-domain:source-order"])
        XCTAssertEqual(value.axis,"narrative-domain:source-order"); XCTAssertEqual(value.cursor, 605)
        XCTAssertThrowsError(try TemporalViewWindow(arguments: data, availableAxes: ["narrative"]))
        let old = try TemporalViewWindow(arguments: Data(#"{"at":{"calendar":"建安","year":12},"from":11,"to":13}"#.utf8), availableAxes: ["calendar:建安"])
        XCTAssertEqual(old.axis, "calendar:建安"); XCTAssertEqual(old.from, 11); XCTAssertEqual(old.to, 13)
    }
    func testAIViewWindowRejectsMixedDatesBooleansAndMissingBounds() throws {
        for text in [
            #"{"at":{"narrativeOrder":true},"from":0,"to":1}"#,
            #"{"at":{"narrativeOrder":605,"narrativeDomain":7},"from":600,"to":606}"#,
            #"{"at":{"calendar":"建安","year":12,"month":11,"day":20},"from":12,"to":12}"#,
            #"{"at":{"narrativeOrder":605},"fromDate":{"year":12},"toDate":{"year":13}}"#,
            #"{"at":{"narrativeOrder":605},"from":606,"to":604}"#,
            #"{"at":{"calendar":"建安","year":12,"month":true,"day":20},"fromDate":{"year":12,"month":11,"day":20},"toDate":{"year":12,"month":11,"day":21}}"#] {
            XCTAssertThrowsError(try TemporalViewWindow(arguments: Data(text.utf8), availableAxes: ["narrative", "calendar-day:建安"]))
        }
    }
}
