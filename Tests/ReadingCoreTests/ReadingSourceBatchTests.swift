import Foundation
import XCTest
@testable import ReadingCore

final class ReadingSourceBatchTests: XCTestCase {
    private func book() -> BookProject {
        BookProject(id: "batch-book", title: "批量原文", originalName: "book.pdf", sourceHash: "original", units: [
            .init(id: "one", order: 0, chapter: "一", page: 1, text: "甲行。\n乙行。🙂e\u{301}与原书的\\n。"),
            .init(id: "two", order: 1, chapter: "一", page: 2, text: "第二页，不改引号\"。\n下一行。"),
            .init(id: "three", order: 2, chapter: "二", page: 3, text: "后续未读结局。")])
    }
    private func session(_ b: BookProject) throws -> ReadingQuerySession {
        .init(snapshot: try .freeze(scope: .book, in: b), history: [], loader: nil, providedDocuments: [:], project: b)
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func testBatchMatchesSeparateReadsAndLiteralSourceReferencesWithoutReadingOtherPages() async throws {
        let b = book(); var batch = try session(b), one = try session(b)
        let result = try await batch.execute(name: "source_read", arguments: ["ids": ["one", "two"]], maximumBytes: 16000)
        let text = try batch.modelSourceReadText(result), value = try object(result)
        for id in ["one", "two"] {
            let part = try await one.execute(name: "source_read", arguments: ["id": id], maximumBytes: 16000)
            _ = try one.modelSourceReadText(part)
        }
        XCTAssertEqual(batch.sourceReferences, one.sourceReferences)
        XCTAssertEqual(batch.sourceExcerpts.map(\.0), ["one", "two"])
        XCTAssertEqual(batch.sourceExcerpts.map(\.1), Array(b.units.prefix(2).map(\.text)))
        XCTAssertTrue(text.contains(b.units[0].text)); XCTAssertTrue(text.contains(b.units[1].text))
        XCTAssertFalse(text.contains("后续未读结局")); XCTAssertFalse(text.contains("\"items\"")); XCTAssertFalse(text.contains("\"hash\""))
        XCTAssertEqual(value["partial"] as? Bool, false); XCTAssertEqual(value["remainingIDs"] as? [String], [])
        XCTAssertLessThanOrEqual(text.utf8.count, result.utf8.count)
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("[unit:three]", session: batch))
    }
    func testOutOfScopeOrDuplicateIDsAndMixedSingleArgumentsFailBeforeAnyRead() async throws {
        let b = book(); let snap = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "one", page: 1))
        for args: [String: Any] in [["ids": ["one", "two"]], ["ids": ["one", "missing"]], ["ids": ["one", "one"]],
                                   ["ids": [String]()], ["ids": ["one"], "id": "one"], ["ids": ["one"], "offset": 1],
                                   ["ids": ["one"], "expectedHash": "stale"], ["ids": ["one"], "length": 0],
                                   ["ids": ["one"], "length": true]] {
            var s = ReadingQuerySession(snapshot: snap, history: [], loader: nil, providedDocuments: [:], project: b)
            do { _ = try await s.execute(name: "source_read", arguments: args, maximumBytes: 16000); XCTFail("Invalid batch read succeeded") } catch {}
            XCTAssertTrue(s.sourceExcerpts.isEmpty); XCTAssertTrue(s.sourceReferences.isEmpty)
        }
    }
    func testSelectionBatchCannotRecoverUnselectedTextOfSamePage() async throws {
        let b = book(), chosen = "甲行。"
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: b, context: .init(sourceHash: b.sourceHash, unitID: "one", selectedText: chosen, page: 1))
        var s = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b)
        let raw = try await s.execute(name: "source_read", arguments: ["ids": ["one"]], maximumBytes: 4000)
        let text = try s.modelSourceReadText(raw)
        XCTAssertTrue(text.contains(chosen)); XCTAssertFalse(text.contains("乙行")); XCTAssertEqual(s.sourceExcerpts.map(\.1), [chosen])
        XCTAssertEqual(s.sourceReferences["one"]?.quote, chosen)
    }
    func testOneCharacterBudgetAcrossSeveralPagesHasExactContinuationAndNoUnreadCitation() async throws {
        let b = book(); var s = try session(b)
        let raw = try await s.execute(name: "source_read", arguments: ["ids": ["one", "two"], "length": 1], maximumBytes: 4000)
        let value = try object(raw), row = try XCTUnwrap((value["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["text"] as? String, "甲"); XCTAssertEqual(row["nextOffset"] as? Int, 1)
        XCTAssertEqual(value["remainingIDs"] as? [String], ["two"]); XCTAssertEqual(value["partial"] as? Bool, true)
        let formatted = try s.modelSourceReadText(raw)
        XCTAssertTrue(formatted.contains("后续起点：1")); XCTAssertTrue(formatted.contains("尚未读取的单元：two"))
        XCTAssertEqual(s.sourceExcerpts.map(\.0), ["one"]); XCTAssertEqual(s.sourceReferences["one"]?.quote, "甲")
        XCTAssertNil(s.sourceReferences["two"])
        let remainder = try await s.execute(name: "source_read", arguments: ["id": "one", "offset": 1], maximumBytes: 4000)
        XCTAssertEqual(try object(remainder)["text"] as? String, String(b.units[0].text.dropFirst()))
    }
    func testWireByteLimitTruncatesOnlyWholeGraphemesAndSharesItAcrossUnits() async throws {
        var b = book(); let phrase = "🙂e\u{301}𠀀中\n"
        b.units[0].text = String(repeating: phrase, count: 3000)
        var s = try session(b)
        let raw = try await s.execute(name: "source_read", arguments: ["ids": ["one", "two", "three"]], maximumBytes: 900)
        let value = try object(raw), row = try XCTUnwrap((value["items"] as? [[String: Any]])?.first), text = try XCTUnwrap(row["text"] as? String)
        XCTAssertLessThanOrEqual(raw.utf8.count, 900); XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(b.units[0].text.hasPrefix(text)); XCTAssertEqual(row["nextOffset"] as? Int, text.count)
        XCTAssertEqual(value["remainingIDs"] as? [String], ["two", "three"])
        XCTAssertEqual(s.sourceExcerpts.map(\.1), [text]); XCTAssertFalse(s.sourceExcerpts.contains { $0.0 == "two" })
        _ = try s.modelSourceReadText(raw); XCTAssertNil(s.sourceReferences["two"])
    }
    func testByteLimitedTailDoesNotGrantAnyUnitOmittedFromReturnedItems() async throws {
        var b = book();b.units[1].text = String(repeating: "第二页。", count: 3000)
        var s = try session(b)
        let raw = try await s.execute(name: "source_read", arguments: ["ids": ["one", "two", "three"]], maximumBytes: 1100)
        let value = try object(raw), rows = try XCTUnwrap(value["items"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(raw.utf8.count, 1100)
        XCTAssertEqual(s.sourceExcerpts.map(\.0), rows.compactMap { $0["id"] as? String })
        XCTAssertFalse(rows.contains { $0["id"] as? String == "three" }); XCTAssertNil(s.sourceReferences["three"])
    }
    func testInconsistentBatchFormatterDoesNotIssueEarlierRowReferences() async throws {
        let b = book(); var s = try session(b)
        let raw = try await s.execute(name: "source_read", arguments: ["ids": ["one", "two"]], maximumBytes: 4000)
        var value = try object(raw), rows = try XCTUnwrap(value["items"] as? [[String: Any]])
        rows[1]["text"] = "伪造的原文。"; value["items"] = rows
        let forged = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        XCTAssertThrowsError(try s.modelSourceReadText(forged)); XCTAssertTrue(s.sourceReferences.isEmpty)
        XCTAssertEqual(s.sourceExcerpts.map(\.1), Array(b.units.prefix(2).map(\.text)))
    }
}
