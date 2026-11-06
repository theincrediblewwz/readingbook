import Foundation
import XCTest
@testable import ReadingCore

final class QueryPreparationTests: XCTestCase {
    private func fixture() -> BookProject {
        var book = BookProject(title: "合成范围", originalName: "book.txt", sourceHash: "fixture", units: [
            .init(id: "u1", order: 0, chapter: "一", page: 1, text: "刘备与关羽同行。"),
            .init(id: "u2", order: 1, chapter: "二", page: 2, text: "后来曹操出现。", warning: "OCR待核对")])
        PluginEngine.seed(&book)
        book.entities = [.init(id: "liu", typeID: "person", name: "刘备", evidence: [.init(unitID: "u1", quote: "刘备")]),
                         .init(id: "cao", typeID: "person", name: "曹操", evidence: [.init(unitID: "u2", quote: "曹操")])]
        book.nodes = [.init(id: "first", targetID: "liu"), .init(id: "future", targetID: "cao")]
        return book
    }

    func testFrozenEnvelopeEqualsFullEncodingAcrossJSONBoundaries() throws {
        let book = fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: book, context: nil)
        let proposals = ReadingProposalToolAccess(proposalTools: ReadingQueryToolCatalog.proposalNames, prepare: { _, _ in Data("{}".utf8) })
        let tools = ReadingQueryToolCatalog.schemas(snapshot: snapshot, host: nil, proposals: proposals)
        let examples: [[[String: Any]]] = [[], [["role": "user", "content": "中/英\\\"文\n🙂 e\u{301}\t"]],
            [["role": "assistant", "content": NSNull(), "tool_calls": [["id": "q", "function": ["name": "source_read", "arguments": "{\"id\":\"u1\"}"]]]]],
            [["role": "tool", "content": String(repeating: "原文🙂/\\\n", count: 4096), "tool_call_id": "q"]]]
        for model in ["offline", " 中文模型 \n", "deepseek-flash"] {
            for definitions in [[], tools] {
                let envelope = try QueryBudget.Envelope(tools: definitions, model: model)
                for messages in examples {
                    for include in [true, false] {
                        XCTAssertEqual(try envelope.inputBytes(messages, includingTools: include),
                            try QueryBudget.inputBytes(messages, tools: include ? definitions : [], model: model))
                    }
                }
            }
        }
    }

    func testEnvelopeStillRejectsInvalidJSONBeforeAnyTransport() throws {
        XCTAssertThrowsError(try QueryBudget.Envelope(tools: [["invalid": Double.nan]], model: "offline"))
        let envelope = try QueryBudget.Envelope(tools: [], model: "offline")
        XCTAssertThrowsError(try envelope.inputBytes([["content": Double.infinity]]))
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try ProviderClient.prepare(messages: [["role": "user", "content": invalid]], tools: [], settings: .init(model: "offline"), apiKey: "", remainingTokens: 100_000))
            XCTAssertThrowsError(try ProviderClient.prepare(messages: [["role": "user", "content": "test"]], tools: [["invalid": invalid]], settings: .init(model: "offline"), apiKey: "", remainingTokens: 100_000))
        }
    }

    func testMetadataKeepsDeclaredFieldsAndCannotWidenGraph() async throws {
        let book = fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let metadata = try await session.execute(name: "book_schema_get", arguments: [:], maximumBytes: 100_000)
        let metadataObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
        let sections = try XCTUnwrap(metadataObject["sections"] as? [String: Int])
        XCTAssertEqual(sections["types"], book.types.count)
        XCTAssertEqual(sections["graph"], 2, "声明计数不是读取后文对象的授权")
        for section in ["types", "methods", "workflowActions", "views", "profile", "operations", "graph"] {
            let arguments: [String: Any] = ["section": section, "limit": 20]
            let actual = try await session.execute(name: "book_schema_get", arguments: arguments, maximumBytes: 100_000)
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(actual.utf8)) as? [String: Any])
            XCTAssertEqual(row["ok"] as? Bool, true)
            if section == "graph" { XCTAssertFalse(actual.contains("future")); XCTAssertTrue(actual.contains("first")) }
        }
        let first = try await session.execute(name: "object_get", arguments: ["id": "liu"], maximumBytes: 100_000)
        XCTAssertTrue(first.contains("刘备"))
        do { _ = try await session.execute(name: "object_get", arguments: ["id": "cao"], maximumBytes: 100_000); XCTFail("目录查询不能打开后文对象") }
        catch { XCTAssertFalse(error is CancellationError) }
    }

    func testCapabilityDiscoveryStillReportsExactGrantedNamesAndSchema() async throws {
        let book = fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        let proposals = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in Data("{}".utf8) })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, proposalAccess: proposals)
        let returned = try await session.execute(name: "capabilities_list", arguments: [:], maximumBytes: 100_000)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(returned.utf8)) as? [String: Any])
        let expected = ReadingQueryToolCatalog.schemas(snapshot: snapshot, host: nil, proposals: proposals).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(value["tools"] as? [String], expected)
        XCTAssertEqual(value["writes"] as? String, "host_controlled_proposals")
        let detail = try await session.execute(name: "capabilities_list", arguments: ["schemaFor": "knowledge"], maximumBytes: 100_000)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(object["referenceGuide"] as? [String: Any])).isEqual(to: ReadingProposalSchemas.referenceGuide(in: book)))
        session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        do { _ = try await session.execute(name: "capabilities_list", arguments: ["schemaFor": "knowledge"], maximumBytes: 100_000); XCTFail("未授权提案时仍应拒绝") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未授予")) }
    }

    func testCoveragePaginationKeepsOriginalWarningsAndOrder() async throws {
        let book = fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: book, context: nil)
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let arguments: [String: Any] = ["offset": 1, "limit": 1]
        let expected = try session.page(snapshot.unitIDs.map { id in ["id": id, "status": book.coverage[id]?.status.rawValue ?? "pending", "warning": book.units.first { $0.id == id }?.warning as Any? ?? NSNull()] as [String: Any] }, arguments, 100_000)
        let actual = try await session.execute(name: "reading_coverage_get", arguments: arguments, maximumBytes: 100_000)
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(expected.contains("OCR待核对"))
    }

    func testMetadataDoesNotRetainProjectAfterHostRefresh() async throws {
        let book = fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        _ = try await session.execute(name: "book_schema_get", arguments: ["section": "views"], maximumBytes: 100_000)
        var updated = book
        updated.entities[0].summary = "读者修正的刘备介绍"
        session.project = updated
        let current = try await session.execute(name: "object_get", arguments: ["id": "liu"], maximumBytes: 100_000)
        XCTAssertTrue(current.contains("读者修正的刘备介绍"), "精简目录准备不应引入跨回执的知识缓存")
    }

    func testFunctionalHeaderDistinguishesUnsharedNotesFromMissingLocalNotes() async throws {
        var book = fixture()
        book.documents = [.init(id: "private", title: "本地私有笔记", evidence: [.init(unitID: "u1", quote: "刘备")])]
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "看看当前页", project: book,
            settings: .init(model: "offline", maxRequestsPerRun: 2, maxOutputTokens: 512, contextWindowTokens: 128_000),
            documents: ["private": "这段私有内容没有分享"], context: .init(unitID: "u1", page: 1), scope: .page,
            history: [], memory: nil, memoryEnabled: false, documentIDs: [], loader: nil,
            operationLimit: 128_000, remainingRequests: 2, preferences: .init(interaction: .functional)) { messages, tools, _, _ in
                requests += 1
                let text = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
                XCTAssertTrue(text.contains("已分享笔记0篇"))
                XCTAssertTrue(text.contains("不能由0推出不存在"))
                XCTAssertFalse(text.contains("本地私有笔记"))
                XCTAssertFalse(text.contains("这段私有内容没有分享"))
                XCTAssertFalse(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "document_read" })
                return .init(message: .init(role: "assistant", content: "刘备与关羽同行。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(result.diagnostics.disclosure.contains("已分享笔记0/0篇"))
    }
}
