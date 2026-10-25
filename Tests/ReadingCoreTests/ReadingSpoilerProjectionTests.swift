import Foundation
import XCTest
@testable import ReadingCore

final class ReadingSpoilerProjectionTests: XCTestCase {
    private func book() -> BookProject {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "开篇", text: "190年，神秘人与徐晃入营。"),
                     SourceUnit(id: "u2", order: 1, chapter: "后文", text: "200年，神秘人原来是曹操，另一人是许褚。")]
        var book = BookProject(title: "边界", originalName: "book.txt", sourceHash: "source", units: units)
        book.entities = [
            KnowledgeEntity(id: "hidden", typeID: "person", name: "曹操", summary: "曹操后来的结局。", properties: ["身份": "魏王"], aliases: ["神秘人"], latitude: 30, longitude: 110,
                evidence: [Evidence(unitID: "u1", quote: "神秘人"), Evidence(unitID: "u2", quote: "神秘人原来是曹操")]),
            KnowledgeEntity(id: "known", typeID: "person", name: "徐晃", evidence: [Evidence(unitID: "u1", quote: "徐晃")]),
            KnowledgeEntity(id: "future", typeID: "person", name: "许褚", evidence: [Evidence(unitID: "u2", quote: "许褚")])]
        return book
    }
    func testEarlierReadingShowsOnlyLiteralAliasAndNeverFutureIdentityOrFields() throws {
        let book = book(), original = book.entities[0]
        let view = try XCTUnwrap(ReadingSpoilerProjection.entity(original, in: book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(view.id, original.id); XCTAssertEqual(view.name, "神秘人")
        XCTAssertFalse(view.aliases.contains("曹操")); XCTAssertEqual(view.summary, ""); XCTAssertTrue(view.properties.isEmpty)
        XCTAssertNil(view.latitude); XCTAssertNil(view.longitude)
        XCTAssertNil(ReadingSpoilerProjection.entity(book.entities[2], in: book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(book.entities[0], original, "只读投影不能改写完整本地卡片。")
        XCTAssertEqual(ReadingSpoilerProjection.entity(original, in: book, allowedUnitIDs: nil), original)
    }
    func testEventHidesFutureDateAndParticipantsAndRetainsVerbatimCurrentYear() throws {
        let book = book()
        let current = KnowledgeEvent(id: "entry", name: "入营", summary: "本地事件", dateText: "190年", startYear: 190,
            participantIDs: ["known", "future"], evidence: [Evidence(unitID: "u1", quote: book.units[0].text)])
        let view = try XCTUnwrap(ReadingSpoilerProjection.event(current, in: book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(view.name, "入营"); XCTAssertEqual(view.dateText, "190年"); XCTAssertEqual(view.startYear, 190)
        XCTAssertEqual(view.participantIDs, ["known"])
        var future = current; future.name = "曹操称王"; future.dateText = "200年"; future.startYear = 200
        future.evidence.append(Evidence(unitID: "u2", quote: book.units[1].text))
        let hidden = try XCTUnwrap(ReadingSpoilerProjection.event(future, in: book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(hidden.name, "本段关联事件"); XCTAssertEqual(hidden.dateText, "时间待考")
        XCTAssertNil(hidden.startYear); XCTAssertNil(hidden.endYear); XCTAssertTrue(hidden.participantIDs.isEmpty); XCTAssertTrue(hidden.summary.isEmpty)
        var unsupportedConversion = current; unsupportedConversion.dateText = "初平元年"
        XCTAssertNil(ReadingSpoilerProjection.event(unsupportedConversion, in: book, allowedUnitIDs: ["u1"])?.startYear)
    }
    func testQueryAndEmbeddedCompositionProjectionDoNotRestoreHiddenCanonicalValues() throws {
        var book = book()
        book.events = [KnowledgeEvent(id: "event", name: "曹操称王", summary: "曹操后来称王。", dateText: "200年", startYear: 200,
            participantIDs: ["hidden", "future"], evidence: [Evidence(unitID: "u1", quote: book.units[0].text)])]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: ReadingContext(unitID: "u1", selectedText: book.units[0].text))
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let projected = try XCTUnwrap(session.scopedKnowledgeProject())
        XCTAssertEqual(projected.entities.first(where: { $0.id == "hidden" })?.name, "神秘人")
        XCTAssertEqual(projected.events.first?.name, "本段关联事件"); XCTAssertNil(projected.events.first?.startYear)
        XCTAssertEqual(projected.events.first?.summary, "", "不能从摘要把被隐藏的事件身份重新带回。")
        XCTAssertEqual(projected.events.first?.dateText, "时间待考"); XCTAssertFalse(projected.events.first?.participantIDs.contains("future") == true)
    }
}
