import Foundation
import XCTest
@testable import ReadingCore

final class TemporalDatePresentationTests: XCTestCase {
    func testTimeAssertionIsDistinctFromEventAssertionAndPreservesUncertainty() {
        var extent = TemporalExtent(sourceText: "三更", calendar: "建安", start: .init(year: 12, month: 11, day: 20),
            precision: .day, uncertainty: .approximate, assertion: .inferred, explanation: "由祭风日及密书推断")
        XCTAssertEqual(TemporalDatePresentation.summary(extent), "推算时间（约略） · 建安12年11月20日")
        extent.assertion = .explicit; extent.uncertainty = .disputed
        XCTAssertEqual(TemporalDatePresentation.summary(extent), "原文明示时间（有争议） · 建安12年11月20日")
        extent.assertion = nil; extent.uncertainty = .exact
        XCTAssertEqual(TemporalDatePresentation.summary(extent), "时间依据待核对 · 建安12年11月20日")
    }
    func testUnknownNarrativeAndOpenIntervalsNeverInventADate() {
        XCTAssertEqual(TemporalDatePresentation.summary(.init(sourceText: "时间待考")), "日期尚未确定")
        XCTAssertEqual(TemporalDatePresentation.summary(.init(sourceText: "當夜\n三更")), "日期尚未确定 · 原文时语：當夜 三更")
        XCTAssertEqual(TemporalDatePresentation.summary(.init(precision: .narrative, narrativeStart: 612, narrativeEnd: 613, narrativeDomain: "source-order")), "原文先后，非史事日期")
        let open = TemporalExtent(calendar: "gregorian", start: .init(year: 208), precision: .year, uncertainty: .unknown, kind: .interval, assertion: .inferred)
        XCTAssertEqual(TemporalDatePresentation.summary(open), "推算时间（不确定） · 公历208年起，终点未定")
        let interval = TemporalExtent(calendar: "自定历法", start: .init(year: 5), end: .init(year: 6), precision: .year, uncertainty: .exact, kind: .interval, assertion: .explicit)
        XCTAssertEqual(TemporalDatePresentation.summary(interval), "原文明示时间 · 自定历法5年—6年")
    }
    func testScopedDiscoveryAndClosingKeepInferredDateWithoutChangingCanonicalVersionOrSourcePermissions() async throws {
        let unit = SourceUnit(id: "u1", order: 0, chapter: "火攻", page: 1, text: "十一月二十日，黄盖约三更火攻。")
        var book = BookProject(title: "日期", originalName: "date.txt", sourceHash: "source", units: [unit])
        PluginEngine.seed(&book)
        book.events = [.init(id: "fire", name: "黄盖火攻", evidence: [.init(unitID: "u1", quote: unit.text)])]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: unit.text, in: book)
        book.temporalKnowledge = .init(anchors: [anchor], eventMetadata: [.init(eventID: "fire", kind: "fire",
            extent: .init(sourceText: "三更", calendar: "建安", start: .init(year: 12, month: 11, day: 20), precision: .day, uncertainty: .approximate, assertion: .inferred, explanation: "约略推断"),
            sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(book)
        var q = ReadingQuerySession(snapshot: try .freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1)), history: [], loader: nil, providedDocuments: [:], project: book)
        let scoped = try XCTUnwrap(q.scopedKnowledgeProject())
        let version = try XCTUnwrap(TemporalKnowledgeRuntime.events(in: scoped, boundary: .init(allowedUnitIDs: Set(q.snapshot.unitIDs))).first?.object.version)
        for full in [false, true] {
            let text = try await q.execute(name: "events_query", arguments: ["includeEvidence": full], maximumBytes: 16_000)
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let row = try XCTUnwrap((root["items"] as? [[String: Any]])?.first)
            XCTAssertEqual(row["timeSummary"] as? String, "推算时间（约略） · 建安12年11月20日")
            XCTAssertEqual((row["object"] as? [String: Any])?["version"] as? String, version)
            if !full { XCTAssertTrue(q.sourceReferences.isEmpty); XCTAssertTrue(q.sourceExcerpts.isEmpty) }
        }
        let closing = try XCTUnwrap(q.finalEvidence(maximumBytes: 16_000))
        XCTAssertTrue(closing.contains("timeSummary")); XCTAssertTrue(closing.contains("推算时间"))
        let rendered = try q.modelSourceText(closing)
        XCTAssertTrue(rendered.contains("时间说明：推算时间（约略）"))
        XCTAssertEqual(Set(q.sourceExcerpts.map { $0.0 }), ["u1"], "Only the explicitly requested evidence is supplied")
        XCTAssertEqual(try encoder.encode(book), before); XCTAssertEqual(book.events.first?.dateText, "时间待考")
    }
}
