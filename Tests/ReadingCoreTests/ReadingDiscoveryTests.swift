import Foundation
import XCTest
@testable import ReadingCore

final class ReadingDiscoveryTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let text = "208年，第一回。" + String(repeating: "曹操到江陵，众人议事。", count: 200)
        var book = BookProject(id: "discovery", title: "资料目录", originalName: "book.pdf", sourceHash: "original", units: [
            .init(id: "one", order: 0, chapter: "一", page: 1, text: text),
            .init(id: "two", order: 1, chapter: "二", page: 2, text: "未来秘密人物结局。")])
        PluginEngine.seed(&book)
        let evidence = [Evidence(unitID: "one", quote: text)]
        book.entities = [.init(id: "cao", typeID: "person", name: "曹操", summary: "本范围介绍", evidence: evidence)]
        book.events = (0..<12).map { .init(id: "event-\($0)", name: "事件\($0)", summary: $0 == 0 ? String(repeating: "较长但真实保存的说明。", count: 50) : "行程", participantIDs: ["cao"], evidence: evidence) }
        book.events.append(.init(id: "future", name: "未读秘密", evidence: [.init(unitID: "two", quote: book.units[1].text)]))
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "one", quote: text, in: book)
        book.temporalKnowledge = .init(anchors: [anchor], eventMetadata: [.init(eventID: "event-0", extent: .init(sourceText: "208年", calendar: "gregorian", start: .init(year: 208), precision: .year, uncertainty: .exact), sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        return book
    }
    private func session(_ book: BookProject) throws -> ReadingQuerySession {
        var context = ReadingContext(sourceHash: book.sourceHash, unitID: "one", page: 1); context.queryRange = .init(pageStart: 1, pageEnd: 1)
        return ReadingQuerySession(snapshot: try .freeze(scope: .range, in: book, context: context), history: [], loader: nil, providedDocuments: [:], project: book)
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func collect(_ name: String, full: Bool, session: inout ReadingQuerySession) async throws -> ([[String: Any]], Int) {
        var result: [[String: Any]] = [], offset = 0, pages = 0
        repeat {
            let text = try await session.execute(name: name, arguments: ["limit": 20, "offset": offset, "includeEvidence": full], maximumBytes: 16000)
            XCTAssertLessThanOrEqual(text.utf8.count, 16000)
            let value = try object(text), rows = try XCTUnwrap(value["items"] as? [[String: Any]])
            result += rows; pages += 1
            guard let next = value["nextOffset"] as? Int else { return (result, pages) }
            XCTAssertGreaterThan(next, offset); offset = next
        } while pages < 30
        XCTFail("分页没有向前推进"); return (result, pages)
    }
    func testCompactEventDiscoveryKeepsEveryIdentityVersionAndTimeWithoutRepeatedBodies() async throws {
        let book = try fixture(); var compactSession = try session(book), fullSession = try session(book)
        let (compact, compactPages) = try await collect("events_query", full: false, session: &compactSession)
        let (full, fullPages) = try await collect("events_query", full: true, session: &fullSession)
        XCTAssertEqual(compactPages, 1); XCTAssertGreaterThan(fullPages, compactPages)
        XCTAssertEqual(compact.count, 12); XCTAssertEqual(compact.count, full.count)
        for (a, b) in zip(compact, full) {
            let first = try XCTUnwrap(a["object"] as? [String: Any]), second = try XCTUnwrap(b["object"] as? [String: Any])
            XCTAssertEqual(first["id"] as? String, second["id"] as? String)
            XCTAssertEqual(first["version"] as? String, second["version"] as? String)
            XCTAssertEqual(first["references"] as? [String: [String]], second["references"] as? [String: [String]])
            XCTAssertEqual(a["match"] as? String, b["match"] as? String)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: a["extent"]!, options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: b["extent"]!, options: [.sortedKeys]))
            XCTAssertNil(first["evidence"]); XCTAssertEqual(first["sourceUnitIDs"] as? [String], ["one"])
            XCTAssertEqual(first["evidenceOmitted"] as? Bool, true)
            XCTAssertFalse(String(describing: a).contains("未来秘密"))
        }
        XCTAssertTrue(compactSession.sourceExcerpts.isEmpty)
        XCTAssertFalse(fullSession.sourceExcerpts.isEmpty)
    }
    func testExplicitFullEventReadPreservesExactQuotesAndOnlyGrantsReturnedEvidence() async throws {
        let book = try fixture(); var query = try session(book)
        let result = try await query.execute(name: "events_query", arguments: ["includeEvidence": true, "limit": 1], maximumBytes: 16000)
        let value = try object(result), row = try XCTUnwrap((value["items"] as? [[String: Any]])?.first)
        let record = try XCTUnwrap(row["object"] as? [String: Any]), evidence = try XCTUnwrap(record["evidence"] as? [[String: Any]])
        XCTAssertEqual(evidence.first?["quote"] as? String, book.units[0].text)
        XCTAssertTrue(query.sourceExcerpts.allSatisfy { $0.0 == "one" && $0.1 == book.units[0].text })
        XCTAssertEqual((record["sourceAnchorIDs"] as? [String]), book.temporalKnowledge?.eventMetadata[0].sourceAnchorIDs)
        XCTAssertFalse(result.contains("未读秘密"))
    }
    func testObjectDiscoveryKeepsReusableSummaryAndCorrectionWithoutRepeatingSavedExcerpts() async throws {
        var book = try fixture(); book.knowledgeUserEdits = .init()
        book.knowledgeUserEdits?.records = [.init(kind: .entity, objectID: "cao", fields: ["summary"], basis: .interpretation)]
        var query = try session(book)
        let compact = try object(try await query.execute(name: "objects_search", arguments: ["query": "曹操"], maximumBytes: 16000))
        let row = try XCTUnwrap((compact["items"] as? [[String: Any]])?.first), saved = try XCTUnwrap(row["previouslySaved"] as? [String: Any])
        XCTAssertEqual(saved["summary"] as? String, "本范围介绍")
        XCTAssertNil(saved["sources"]); XCTAssertEqual(saved["sourceExcerptsOmitted"] as? Bool, true)
        XCTAssertNotNil(saved["readerCorrection"])
        let full = try object(try await query.execute(name: "objects_search", arguments: ["query": "曹操", "includeEvidence": true], maximumBytes: 16000))
        let fullSaved = try XCTUnwrap((full["items"] as? [[String: Any]])?.first?["previouslySaved"] as? [String: Any])
        XCTAssertEqual((fullSaved["sources"] as? [[String: String]])?.first?["excerpt"], String(book.units[0].text.prefix(240)))
        XCTAssertEqual(saved["sourceCount"] as? Int, fullSaved["sourceCount"] as? Int)
        XCTAssertTrue(query.sourceExcerpts.isEmpty, "此前保存的摘录仍是派生资料，不冒充本次已读原文")
    }
    func testLongEventSummaryIsHonestPreviewAndFullObjectRemainsAvailable() async throws {
        let book = try fixture(); var query = try session(book)
        let result = try object(try await query.execute(name: "events_query", arguments: ["limit": 1], maximumBytes: 16000))
        let preview = try XCTUnwrap((result["items"] as? [[String: Any]])?.first?["object"] as? [String: Any])
        XCTAssertEqual(preview["summaryTruncated"] as? Bool, true)
        XCTAssertEqual(preview["summary"] as? String, String(book.events[0].summary.prefix(400)))
        let full = try object(try await query.execute(name: "object_get", arguments: ["id": "event-0"], maximumBytes: 16000))
        XCTAssertEqual((full["object"] as? [String: Any])?["summary"] as? String, book.events[0].summary)
        XCTAssertEqual((full["object"] as? [String: Any])?["version"] as? String, preview["version"] as? String)
    }
    func testAlreadyProvidedSourceIsNotAppendedAgainByKnowledgeSearchOrReads() async throws {
        let book = try fixture(); var query = try session(book)
        _ = try XCTUnwrap(query.initialSource(maximumBytes: 16000))
        let count = query.sourceExcerpts.count
        _ = try await query.execute(name: "events_query", arguments: ["limit": 1, "includeEvidence": true], maximumBytes: 16000)
        _ = try await query.execute(name: "source_read", arguments: ["id": "one", "length": 20], maximumBytes: 16000)
        _ = try await query.execute(name: "source_search", arguments: ["keywords": ["曹操"]], maximumBytes: 16000)
        XCTAssertEqual(query.sourceExcerpts.count, count)
        XCTAssertFalse(query.hasOnlyPreloadedSources, "实际读过正文后仍须严格检查引用；缓存去重不改变这项要求")
    }
    func testPartiallyReadSourceCanStillAddNewEvidenceButIdenticalReadDoesNotAccumulate() async throws {
        let book = try fixture(); var query = try session(book)
        _ = try await query.execute(name: "source_read", arguments: ["id": "one", "length": 5], maximumBytes: 16000)
        let first = query.sourceExcerpts.count
        _ = try await query.execute(name: "source_read", arguments: ["id": "one", "length": 15], maximumBytes: 16000)
        XCTAssertGreaterThan(query.sourceExcerpts.count, first)
        let extended = query.sourceExcerpts.count
        _ = try await query.execute(name: "source_read", arguments: ["id": "one", "length": 5], maximumBytes: 16000)
        XCTAssertEqual(query.sourceExcerpts.count, extended)
        XCTAssertTrue(query.sourceExcerpts.contains { $0.0 == "one" && $0.1 == String(book.units[0].text.prefix(15)) })
    }
}

extension ReadingDiscoveryTests {
    func testDefaultDirectoryAliasesOnlyByteIdenticalTimeFieldsAndFullMetadataIsStillAvailable() async throws {
        var b = try fixture(); b.temporalKnowledge?.eventMetadata[0].explanation = String(repeating: "完整依据说明。", count: 100)
        var brief = try session(b), complete = try session(b)
        let text = try await brief.execute(name: "events_query", arguments: ["limit": 1], maximumBytes: 16000)
        let full = try await complete.execute(name: "events_query", arguments: ["limit": 1, "includeEvidence": true], maximumBytes: 16000)
        let first = try XCTUnwrap((try object(text)["items"] as? [[String: Any]])?.first)
        let second = try XCTUnwrap((try object(full)["items"] as? [[String: Any]])?.first)
        let aliases = try XCTUnwrap(first["sameAs"] as? [String: String])
        XCTAssertEqual(aliases["object.temporalExtent"], "extent"); XCTAssertEqual(aliases["metadata.extent"], "extent")
        XCTAssertNil(aliases["sourceExtent"], "叙事出处与史事日历不同，不能合并")
        XCTAssertNotNil(first["sourceExtent"])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: first["extent"]!, options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: second["extent"]!, options: [.sortedKeys]))
        XCTAssertEqual((first["object"] as? [String: Any])?["version"] as? String, (second["object"] as? [String: Any])?["version"] as? String)
        XCTAssertNil((first["metadata"] as? [String: Any])?["explanation"])
        XCTAssertEqual(first["metadataExplanationOmitted"] as? Bool, true)
        XCTAssertEqual((second["metadata"] as? [String: Any])?["explanation"] as? String, b.temporalKnowledge?.eventMetadata[0].explanation)
        XCTAssertNotNil((second["metadata"] as? [String: Any])?["extent"])
        XCTAssertTrue(brief.sourceExcerpts.isEmpty); XCTAssertTrue(brief.sourceReferences.isEmpty)
        XCTAssertLessThan(text.utf8.count, full.utf8.count)
    }
}
