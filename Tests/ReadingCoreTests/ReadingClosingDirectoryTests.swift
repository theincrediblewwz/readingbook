import Foundation
import XCTest
@testable import ReadingCore

final class ReadingClosingDirectoryTests: XCTestCase {
    private func fixture(hiddenParent: Bool = false) throws -> BookProject {
        let names = (1...7).map { "第\($0)个阶段" }.joined(separator: "、")
        let units = [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: "黄盖火攻，曹操退走，关羽放行。已有主线：\(names)。用户改过的阶段1。未返回的同页事件。"),
                     SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "未分享的后文与秘密父事件。")]
        var book = BookProject(title: "收尾资料", originalName: "book.txt", sourceHash: "fixture", units: units)
        PluginEngine.seed(&book)
        let local = Evidence(unitID: "u1", quote: units[0].text)
        book.events = (1...7).map { .init(id: "phase\($0)", name: "第\($0)个阶段", evidence: [local]) }
            + [.init(id: "parent", name: hiddenParent ? "秘密父事件" : "已有主线", evidence: [.init(unitID: hiddenParent ? "u2" : "u1", quote: hiddenParent ? units[1].text : units[0].text)]),
               .init(id: "unread", name: "未返回的同页事件", evidence: [local])]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: units[0].text, in: book)
        book.temporalKnowledge = .init(anchors: [anchor], eventMetadata: (1...7).map { (phase: Int) -> EventTemporalMetadata in
            .init(eventID: "phase\(phase)", kind: "行动", parentEventID: "parent", phaseOrder: phase, sourceAnchorIDs: [anchor.id], assertion: .explicit)
        })
        return book
    }
    private func session(_ book: BookProject, proposals: ReadingProposalToolAccess? = nil) throws -> ReadingQuerySession {
        .init(snapshot: try .freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1)), history: [], loader: nil,
              providedDocuments: [:], project: book, proposalAccess: proposals)
    }
    private func decode(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func encoded(_ book: BookProject) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(book) }

    func testActuallyReturnedPhasesSurviveClosingWithoutUnreadObjectsOrCitationGrants() async throws {
        let book = try fixture(), before = try encoded(book); var query = try session(book)
        XCTAssertNil(try query.finalEvidence(maximumBytes: 24000))
        _ = try await query.execute(name: "object_get", arguments: ["ids": (1...7).map { "phase\($0)" }], maximumBytes: 20000)
        let packed = try XCTUnwrap(query.finalEvidence(maximumBytes: 24000)), value = try decode(packed)
        let rows = try XCTUnwrap(value["retainedReadObjects"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, (1...7).map { "phase\($0)" })
        for (index, row) in rows.enumerated() {
            XCTAssertEqual((row["fields"] as? [String: String])?["phaseOrder"], String(index + 1))
            XCTAssertEqual((row["references"] as? [String: [String]])?["parentEvent"], ["parent"])
            XCTAssertNil(row["evidence"])
        }
        XCTAssertFalse(packed.contains("未返回的同页事件")); XCTAssertFalse(packed.contains(book.units[0].text))
        XCTAssertTrue(query.sourceReferences.isEmpty); XCTAssertTrue(query.sourceExcerpts.isEmpty)
        let text = try query.modelSourceText(packed)
        XCTAssertTrue(text.contains("第7个阶段")); XCTAssertTrue(text.contains("第 1 页")); XCTAssertTrue(text.contains("非原文证据"))
        XCTAssertLessThanOrEqual(text.utf8.count, packed.utf8.count); XCTAssertEqual(try encoded(book), before)
    }

    func testSameVersionNameSearchDoesNotEraseAlreadyReturnedFields() async throws {
        let book = try fixture(); var query = try session(book)
        _ = try await query.execute(name: "object_get", arguments: ["id": "phase1", "includeEvidence": false], maximumBytes: 20000)
        _ = try await query.execute(name: "objects_search", arguments: ["query": "第1个阶段"], maximumBytes: 20000)
        let value = try decode(try XCTUnwrap(query.finalEvidence(maximumBytes: 8000)))
        let row = try XCTUnwrap((value["retainedReadObjects"] as? [[String: Any]])?.first)
        XCTAssertEqual((row["fields"] as? [String: String])?["phaseOrder"], "1")
        XCTAssertEqual((row["references"] as? [String: [String]])?["parentEvent"], ["parent"])
    }

    func testClosingDoesNotRestoreHiddenParentFieldsOrEvidence() async throws {
        let book = try fixture(hiddenParent: true); var query = try session(book)
        _ = try await query.execute(name: "object_get", arguments: ["ids": ["phase1"]], maximumBytes: 20000)
        let packed = try XCTUnwrap(query.finalEvidence(maximumBytes: 8000))
        XCTAssertFalse(packed.contains("秘密父事件")); XCTAssertFalse(packed.contains("phaseOrder")); XCTAssertFalse(packed.contains("parentEvent"))
        XCTAssertFalse(packed.contains("u2")); XCTAssertTrue(query.sourceReferences.isEmpty); XCTAssertTrue(query.sourceExcerpts.isEmpty)
    }

    func testReviewedVersionInvalidatesDirectoryUntilActuallyReadAgain() async throws {
        let book = try fixture(); var updated = book; updated.events[0].name = "用户改过的阶段1"
        let fresh = updated
        let proposals = ReadingProposalToolAccess(proposalTools: [], prepare: { _, _ in Data() }, currentProject: { fresh })
        var query = try session(book, proposals: proposals)
        _ = try await query.execute(name: "object_get", arguments: ["ids": ["phase1"]], maximumBytes: 20000)
        try await query.refreshReviewedProject()
        XCTAssertNil(try query.finalEvidence(maximumBytes: 8000))
        _ = try await query.execute(name: "object_get", arguments: ["ids": ["phase1"]], maximumBytes: 20000)
        XCTAssertTrue(try XCTUnwrap(query.finalEvidence(maximumBytes: 8000)).contains("用户改过的阶段1"))
        XCTAssertTrue(query.sourceReferences.isEmpty)
    }

    func testSmallClosingBudgetsRemainBoundedAndNeverCreateCitations() async throws {
        let book = try fixture(); var original = try session(book)
        _ = try await original.execute(name: "object_get", arguments: ["ids": (1...7).map { "phase\($0)" }], maximumBytes: 20000)
        for budget in [128, 600, 1500, 4000, 24000] {
            var query = original
            if let packed = try query.finalEvidence(maximumBytes: budget) {
                XCTAssertLessThanOrEqual(packed.utf8.count, budget)
                XCTAssertLessThanOrEqual(try query.modelSourceText(packed).utf8.count, packed.utf8.count)
            }
            XCTAssertTrue(query.sourceReferences.isEmpty); XCTAssertTrue(query.sourceExcerpts.isEmpty)
        }
    }

    func testTruncatedDirectoryRemainsExplicitInReadableClosingText() async throws {
        let book = try fixture(); var query = try session(book)
        var directory = ReadingReturnedObjectDirectory()
        let row: [String: Any] = ["id": "phase1", "name": "第1个阶段", "version": "v1", "fields": ["summary": String(repeating: "已有分析", count: 100)], "sourceUnitIDs": ["u1"]]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["items": [row]]), as: UTF8.self)
        try directory.record(raw, tool: "objects_search", allowedUnits: ["u1"])
        let retained = try directory.rows(maximumBytes: 8000)
        query.returnedObjectDirectory = directory
        let payload = try XCTUnwrap(query.finalEvidence(maximumBytes: 8000))
        XCTAssertEqual(retained.values.first?["fieldsPartial"] as? Bool, true)
        let text = try query.modelSourceText(payload)
        XCTAssertTrue(text.contains("部分字段") || text.contains("fieldsPartial"))
        XCTAssertTrue(query.sourceReferences.isEmpty); XCTAssertTrue(query.sourceExcerpts.isEmpty)
    }

    func testFinalModelRequestReceivesTheReadStageFieldsAfterToolHistoryIsDropped() async throws {
        let book = try fixture(); var count = 0
        _ = try await ReadingAnswerEngine.run(question: "核对已有七个阶段", project: book,
            settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128000), documents: [:],
            context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 128000, remainingRequests: 2) { messages, _, _, final in
                count += 1
                if !final {
                    let args = String(decoding: try JSONSerialization.data(withJSONObject: ["ids": (1...7).map { "phase\($0)" }]), as: UTF8.self)
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil,
                        tool_calls: [.init(id: "read", type: "function", function: .init(name: "object_get", arguments: args))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 10)
                }
                let text = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
                XCTAssertTrue(text.contains("第7个阶段"))
                XCTAssertTrue(text.contains("phaseOrder=7") || text.contains("\"phaseOrder\":\"7\""))
                XCTAssertFalse(text.contains("资料ID：unread") || text.contains("\"id\":\"unread\""))
                return .init(message: .init(role: "assistant", content: "原文记有火攻与退走。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 10)
            }
        XCTAssertEqual(count, 2)
    }
}
