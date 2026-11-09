import Foundation
import XCTest
@testable import ReadingCore

final class ReadingCitationRepairTests: XCTestCase {
    private func book() -> BookProject {
        BookProject(title: "出处标记合成回归", originalName: "book.txt", sourceHash: "citation-repair", units: [
            .init(id: "u1", order: 0, chapter: "本章", page: 1, text: "火起，曹操退走。"),
            .init(id: "u2", order: 1, chapter: "本章", page: 2, text: "張遼指向烏林。"),
            .init(id: "u3", order: 2, chapter: "后文", page: 3, text: "未提供的后文秘密。")])
    }
    private func session() throws -> ReadingQuerySession {
        let value = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: value)
        var query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: value)
        query.sourceExcerpts = value.units.prefix(2).map { ($0.id, $0.text) }
        return query
    }
    func testCompoundMarksSeparateOnlyWrittenIDsAndStillValidateEachSource() throws {
        let value = ReadingAnswerEngine.normalizedCitationDelimiters("原文［unit：u1、unit:u2］。后接[unit:u1, u2]。")
        XCTAssertEqual(value, "原文[unit:u1][unit:u2]。后接[unit:u1][unit:u2]。")
        XCTAssertEqual(try ReadingAnswerEngine.citations(value, session: session()).map(\.unitID), ["u1", "u2"])
        XCTAssertThrowsError(try ReadingAnswerEngine.citations(ReadingAnswerEngine.normalizedCitationDelimiters("[unit:u1、u3]"), session: session()))
        XCTAssertEqual(ReadingAnswerEngine.normalizedCitationDelimiters("[unit:u1-u2]"), "[unit:u1-u2]")
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("[unit:u1-u2]", session: session()))
    }
    func testNoPrefixGuessingMixedKindsOrArbitraryTextNormalization() throws {
        for value in ["[unit:u1、doc:note]", "[unit:u1、]", "[unit:u1 至 u2]", "[unit:u1、原文]", "普通［说明］"] {
            XCTAssertEqual(ReadingAnswerEngine.normalizedCitationDelimiters(value), value)
        }
        let value = ReadingAnswerEngine.normalizedCitationDelimiters("[unit:u1、2]")
        XCTAssertEqual(value, "[unit:u1][unit:2]")
        XCTAssertThrowsError(try ReadingAnswerEngine.citations(value, session: session()))
    }
    func testRepairGuideNamesMissingIDsWithoutSearchingHiddenBookText() throws {
        let query = try session(), raw = try ReadingAnswerEngine.citationRepairGuide("[unit:u1][unit:u3][doc:private-note]", session: query)
        let guide = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual((guide["invalidCitationMarks"] as? [[String: String]])?.map { $0["id"]! }, ["u3", "private-note"])
        XCTAssertEqual((guide["suppliedCitationIDs"] as? [String: [String]])?["unit"], ["u1", "u2"])
        XCTAssertFalse(raw.contains("后文秘密")); XCTAssertFalse(raw.contains("火起"))
        XCTAssertEqual(query.sourceExcerpts.count, 2)
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("[unit:u3]", session: query))
    }
    func testRepairGuideIsBoundedAndExplicitWhenIDsAreTruncated() throws {
        var query = try session(); query.sourceExcerpts = (0..<100).map { ("unit-\($0)", "实际提供片段") }
        let guide = try ReadingAnswerEngine.citationRepairGuide((0..<100).map { "[unit:missing-\($0)]" }.joined(), session: query)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(guide.utf8)) as? [String: Any])
        XCTAssertEqual((raw["invalidCitationMarks"] as? [[String: String]])?.count, 12)
        XCTAssertEqual((raw["suppliedCitationIDs"] as? [String: [String]])?["unit"]?.count, 64)
        XCTAssertEqual((raw["suppliedIDsTruncated"] as? [String: Bool])?["unit"], true)
        XCTAssertLessThan(guide.utf8.count, 9000)
    }
    func testEngineRepairsOnlyWithExactFinalSuppliedIDsAndReadableDraft() async throws {
        let value = book(); var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "这一页讲什么", project: value, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128000), documents: [:],
            context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 128000, remainingRequests: 4) { messages, _, _, _ in
                requests += 1
                if requests == 2 {
                    let guide = try XCTUnwrap(messages.first(where: { ($0["content"] as? String)?.hasPrefix("软件核对结果") == true })?["content"] as? String)
                    XCTAssertTrue(guide.contains("u3")); XCTAssertTrue(guide.contains("suppliedCitationIDs")); XCTAssertFalse(guide.contains("后文秘密"))
                    let draft = try XCTUnwrap(messages.first(where: { ($0["content"] as? String)?.hasPrefix("待修正的回答草稿") == true })?["content"] as? String)
                    XCTAssertTrue(draft.contains("先解释\n再引用")); XCTAssertFalse(draft.contains("\\n")); XCTAssertFalse(draft.contains("\"draft\""))
                }
                return .init(message: .init(role: "assistant", content: requests == 1 ? "先解释\n再引用[unit:u1、unit:u3]" : "火起后退走。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        XCTAssertEqual(requests, 2); XCTAssertEqual(result.message.evidence.map(\.unitID), ["u1"])
        XCTAssertFalse(result.message.content.contains("u3"))
    }
    func testValidCompoundMarksNeedNoExtraModelRequest() async throws {
        let value = book(); var context = ReadingContext(unitID: "u1", page: 1); context.queryRange = .init(pageStart: 1, pageEnd: 2)
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "解释这两页", project: value, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128000), documents: [:],
            context: context, scope: .range, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 128000, remainingRequests: 4) { _, _, _, _ in
                requests += 1
                return .init(message: .init(role: "assistant", content: "火起后退向烏林。［unit：u1、unit:u2］", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        XCTAssertEqual(requests, 1); XCTAssertEqual(result.message.evidence.map(\.unitID), ["u1", "u2"])
        XCTAssertTrue(result.message.content.contains("[unit:u1][unit:u2]"))
    }
    func testFunctionalRangeRepairsFromToolReadWithoutInitialPreload() async throws {
        let value = book(); var context = ReadingContext(unitID: "u1", page: 1); context.queryRange = .init(pageStart: 1, pageEnd: 2)
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "解释所选范围", project: value,
            settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128000), documents: [:], context: context,
            scope: .range, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 128000, remainingRequests: 4, preferences: .init(interaction: .functional)) { messages, tools, _, finalOnly in
                requests += 1
                if requests == 1 {
                    XCTAssertFalse(messages.contains { ($0["content"] as? String)?.contains("火起，曹操退走。") == true })
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                        .init(id: "read", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u1"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
                }
                if requests == 3 {
                    XCTAssertTrue(finalOnly); XCTAssertTrue(tools.isEmpty)
                    let text = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
                    XCTAssertTrue(text.contains("火起，曹操退走。")); XCTAssertFalse(text.contains("后文秘密"))
                    XCTAssertTrue(text.contains("invalidCitationMarks")); XCTAssertTrue(text.contains("u2"))
                }
                return .init(message: .init(role: "assistant", content: requests == 2 ? "火起后退走。[unit:u1][unit:u2]" : "火起后退走。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        XCTAssertEqual(requests, 3); XCTAssertEqual(result.message.evidence.map(\.unitID), ["u1"])
    }
    func testToolReadCorrectionStillHonorsTaskRequestLimit() async throws {
        let value = book(); var context = ReadingContext(unitID: "u1", page: 1); context.queryRange = .init(pageStart: 1, pageEnd: 2)
        var requests = 0
        do {
            _ = try await ReadingAnswerEngine.run(question: "解释所选范围", project: value,
                settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128000), documents: [:], context: context,
                scope: .range, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
                operationLimit: 128000, remainingRequests: 2, preferences: .init(interaction: .functional)) { _, _, _, _ in
                    requests += 1
                    if requests == 1 {
                        return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                            .init(id: "read", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u1"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
                    }
                    return .init(message: .init(role: "assistant", content: "未提供的正文。[unit:u2]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
                }
            XCTFail("Request budget must not be bypassed for a correction")
        } catch { XCTAssertTrue(error.localizedDescription.contains("引用")) }
        XCTAssertEqual(requests, 2)
    }
}
