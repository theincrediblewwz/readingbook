import Foundation
import XCTest
@testable import ReadingCore

final class OnDemandRangeTests: XCTestCase {
    private func fixture() -> BookProject {
        BookProject(title: "范围阅读", originalName: "range.txt", sourceHash: "range-source", units: [
            .init(id: "u1", order: 0, chapter: "一", page: 1, text: "刘备在甲地。"),
            .init(id: "u2", order: 1, chapter: "二", page: 2, text: "曹操在乙地。"),
            .init(id: "u3", order: 2, chapter: "三", page: 3, text: "范围外秘密。")])
    }
    private func response(_ content: String) -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: content, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
    }
    func testOnDemandReferenceBindsExactReturnedTextAndUsesRealLineBreaks() async throws {
        var book = fixture(); book.units[0].text = "甲行。\n乙行。\n未读秘密。"
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let raw = try await session.execute(name: "source_read", arguments: ["id": "u1", "length": 8], maximumBytes: 8000)
        let body = try session.modelSourceReadText(raw)
        XCTAssertTrue(body.contains("甲行。\n乙行。\n")); XCTAssertTrue(body.contains("节选")); XCTAssertFalse(body.contains("\\n"))
        XCTAssertTrue(body.contains("后续起点：8")); XCTAssertFalse(body.contains("未读秘密"))
        XCTAssertLessThanOrEqual(body.utf8.count, raw.utf8.count)
        let payload = Data(#"{"batch":{"knowledge":{"anchors":[{"clientID":"a","sourceRef":"u1"}]}}}"#.utf8)
        let expanded = try session.resolveSourceReferences(in: payload)
        let value = try JSONSerialization.jsonObject(with: expanded) as? [String: Any]
        let row = ((value?["batch"] as? [String: Any])?["knowledge"] as? [String: Any])?["anchors"] as? [[String: String]]
        XCTAssertEqual(row?.first?["quote"], "甲行。\n乙行。\n")
        let more = try await session.execute(name: "source_read", arguments: ["id": "u1", "offset": 8, "length": 2], maximumBytes: 8000)
        let second = try session.modelSourceReadText(more)
        XCTAssertTrue(second.contains("整理引用编号：source-")); XCTAssertFalse(second.contains("秘密"))
        XCTAssertEqual(session.sourceReferences["u1"]?.quote, "甲行。\n乙行。\n", "同一页的后续片段不能偷换已签发编号")
        XCTAssertEqual(session.sourceReferences[try session.sourceReferenceID(unitID: "u1", text: "未读")]?.quote, "未读")
        let forged = #"{"ok":true,"id":"u1","text":"未提供的原文","offset":0,"nextOffset":null}"#
        XCTAssertThrowsError(try session.modelSourceReadText(forged))
        let end = try await session.execute(name: "source_read", arguments: ["id": "u1", "offset": book.units[0].text.count], maximumBytes: 8000)
        XCTAssertEqual(try session.modelSourceReadText(end), end, "读到末尾只保留定位回执，不签发空引文或中断任务")
    }
    func testFunctionalRangeReadsOnlyWhatItNeedsAndRetainsTheOriginalBoundary() async throws {
        let book = fixture()
        var context = ReadingContext(unitID: "u1", page: 1); context.queryRange = .init(pageStart: 1, pageEnd: 2)
        var calls = 0
        let result = try await ReadingAnswerEngine.run(question: "核对曹操所在位置", project: book,
            settings: .init(model: "offline", maxOutputTokens: 1000, contextWindowTokens: 128000), documents: [:], context: context,
            scope: .range, history: [], memory: nil, memoryEnabled: false, documentIDs: [], loader: nil,
            operationLimit: 128000, remainingRequests: 3, preferences: .init(interaction: .functional)) { messages, _, _, _ in
                calls += 1
                let body = messages.compactMap { $0["content"] as? String }.joined()
                XCTAssertFalse(body.contains(book.units[2].text))
                if calls == 1 {
                    XCTAssertFalse(body.contains(book.units[0].text)); XCTAssertFalse(body.contains(book.units[1].text))
                    XCTAssertTrue(body.contains("本次可读取原文2单元"))
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                        .init(id: "allowed", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u2"}"#)),
                        .init(id: "denied", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u3"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
                }
                XCTAssertTrue(body.contains(book.units[1].text)); XCTAssertFalse(body.contains(book.units[0].text))
                let denied = messages.first { $0["tool_call_id"] as? String == "denied" }?["content"] as? String ?? ""
                XCTAssertTrue(denied.contains("error"))
                return self.response("曹操在乙地。[unit:u2]")
            }
        XCTAssertEqual(calls, 2); XCTAssertEqual(result.message.evidence.map(\.unitID), ["u2"])
        XCTAssertEqual(result.diagnostics.sourceReadIDs, ["u2"])
    }
    func testReadingOnlyRangeStillReceivesItsChosenTextImmediately() async throws {
        let book = fixture()
        var context = ReadingContext(unitID: "u1", page: 1); context.queryRange = .init(pageStart: 1, pageEnd: 2)
        let result = try await ReadingAnswerEngine.run(question: "读这两页", project: book,
            settings: .init(model: "offline", maxOutputTokens: 1000, contextWindowTokens: 128000), documents: [:], context: context,
            scope: .range, history: [], memory: nil, memoryEnabled: false, documentIDs: [], loader: nil,
            operationLimit: 128000, remainingRequests: 1) { messages, _, _, _ in
                let body = messages.compactMap { $0["content"] as? String }.joined()
                XCTAssertTrue(body.contains(book.units[0].text)); XCTAssertTrue(body.contains(book.units[1].text)); XCTAssertFalse(body.contains(book.units[2].text))
                return self.response("两页分别提到刘备与曹操。[unit:u1][unit:u2]")
            }
        XCTAssertEqual(result.diagnostics.sourceReadIDs, ["u1", "u2"])
        XCTAssertEqual(result.diagnostics.toolCalls, 0)
    }
}
