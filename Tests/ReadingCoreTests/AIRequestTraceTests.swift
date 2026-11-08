import Foundation
import XCTest
@testable import ReadingCore

final class AIRequestTraceTests: XCTestCase {
    func testPreparedTraceContainsActualTextAndArgumentsWithoutTransportSecretsOrReasoning() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "只根据原文回答。"],
            ["role": "user", "content": "請問將軍，為何在此長歎？"],
            ["role": "assistant", "content": NSNull(), "reasoning_content": "PRIVATE_REASONING_NOT_FOR_DETAILS",
             "tool_calls": [["id": "c1", "type": "function", "function": ["name": "source_read", "arguments": "{\"id\":\"p104\"}"]]]],
            ["role": "tool", "tool_call_id": "c1", "content": "真实原文\n第二行"]]
        let prepared = try ProviderClient.prepare(messages: messages, tools: [], settings: ProviderSettings(model: "fixture"),
            apiKey: "PRIVATE_HEADER_KEY", remainingTokens: 128_000)
        let trace = try XCTUnwrap(AIRequestTrace.capture(prepared))
        XCTAssertEqual(trace.messages.map(\.role), ["system", "user", "assistant", "tool"])
        XCTAssertEqual(trace.messages[1].content.text, "請問將軍，為何在此長歎？")
        XCTAssertTrue(trace.messages[2].content.text.contains("p104"))
        XCTAssertEqual(trace.messages[3].content.text, "真实原文\n第二行")
        let displayed = trace.messages.map { $0.content.text }.joined()
        XCTAssertFalse(displayed.contains("PRIVATE_HEADER_KEY"))
        XCTAssertFalse(displayed.contains("PRIVATE_REASONING"))
        XCTAssertFalse(displayed.contains("Authorization"))
        XCTAssertEqual(trace.omittedMessages, 0)
    }

    func testImageDataIsNotRetainedButActualTextPartsAre() throws {
        let prepared = try ProviderClient.prepare(messages: [["role": "user", "content": [
            ["type": "text", "text": "查看这张页面。"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,PRIVATE_IMAGE_BYTES"]]]]],
            tools: [], settings: ProviderSettings(model: "fixture"), apiKey: "", remainingTokens: 128_000)
        let trace = try XCTUnwrap(AIRequestTrace.capture(prepared))
        XCTAssertTrue(trace.messages[0].content.text.contains("查看这张页面。"))
        XCTAssertTrue(trace.messages[0].content.text.contains("附有图片"))
        XCTAssertFalse(trace.messages[0].content.text.contains("PRIVATE_IMAGE_BYTES"))
    }

    func testTraceBoundsPreserveWholeCharactersAndDeclareOmissions() throws {
        let text = "中文👨‍👩‍👧‍👦后文"
        let slice = AITraceText(text, maximumBytes: 7)
        XCTAssertEqual(slice.text, "中文")
        XCTAssertEqual(slice.originalBytes, text.utf8.count)
        XCTAssertTrue(slice.isPartial)
        XCTAssertEqual(AITraceText(text, maximumBytes: 0).text, "")
        let prepared = try ProviderClient.prepare(messages: [["role": "user", "content": String(repeating: "字", count: 40)],
            ["role": "tool", "content": "后面的实际文字"]], tools: [], settings: ProviderSettings(model: "fixture"), apiKey: "", remainingTokens: 128_000)
        let trace = try XCTUnwrap(AIRequestTrace.capture(prepared, maximumBytes: 20))
        XCTAssertLessThanOrEqual(trace.retainedBytes, 20)
        XCTAssertTrue(trace.messages[0].content.isPartial)
        XCTAssertEqual(trace.omittedMessages, 0, "还有2字节时可以保留下一条的空片段，但必须标明截断")
        XCTAssertTrue(trace.messages[1].content.isPartial)
        let none = try XCTUnwrap(AIRequestTrace.capture(prepared, maximumBytes: 0))
        XCTAssertEqual(none.omittedMessages, 2)
        XCTAssertTrue(none.messages.isEmpty)
    }

    func testSourceTraceUsesReturnedLocatorTextAndContinuationInsteadOfReReadingBook() {
        let raw = #"{"id":"unit-000104","locator":"第 104 页 · 行 1–22","text":"請問將軍，為何在此長歎？","offset":0,"nextOffset":14,"totalCharacters":50}"#
        let trace = AIToolTrace(arguments: #"{"id":"unit-000104"}"#, result: raw)
        XCTAssertEqual(trace.result.text, raw)
        XCTAssertEqual(trace.fragments.first?.title, "第 104 页 · 行 1–22")
        XCTAssertEqual(trace.fragments.first?.text, "請問將軍，為何在此長歎？")
        XCTAssertTrue(trace.fragments.first?.detail.contains("后面还有正文") == true)
        XCTAssertFalse(trace.result.isPartial)
    }

    func testSearchTraceDistinguishesHitsFromFullReadsAndKeepsEachPage() {
        let raw = #"{"hits":[{"id":"a","locator":"第 602 页","snippet":"周瑜…"},{"id":"b","locator":"第 607 页","snippet":"孔明…"}]}"#
        let trace = AIToolTrace(arguments: #"{"keywords":["周瑜"]}"#, result: raw)
        XCTAssertEqual(trace.fragments.map(\.title), ["第 602 页", "第 607 页"])
        XCTAssertEqual(trace.fragments.map(\.text), ["周瑜…", "孔明…"])
        XCTAssertTrue(trace.fragments.allSatisfy { $0.detail.contains("并非整页") })
        XCTAssertTrue(AIToolTrace(arguments: "{}", result: #"{"ok":false,"error":"不在范围内"}"#).fragments.isEmpty)
        XCTAssertTrue(AIToolTrace(arguments: "{}", result: String(repeating: "x", count: 40_000)).result.isPartial)
    }

    func testReadToolProgressIncludesActualReturnedEvidenceAndFailedAttempt() async throws {
        let book = BookProject(id: "trace", title: "过程", originalName: "source.pdf", sourceHash: "hash",
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", page: 104, text: "請問將軍，為何在此長歎？")])
        let events = TraceEventRecorder(), calls = TraceRequestCounter()
        let result = try await ReadingAnswerEngine.run(question: "讲解这句", project: book, settings: ProviderSettings(),
            documents: [:], context: nil, scope: .book, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 4, progress: { events.append($0) }) { _, _, _, _ in
                let number = await calls.next()
                if number == 1 {
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                        .init(id: "read", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u1"}"#)),
                        .init(id: "bad", type: "function", function: .init(name: "source_read", arguments: #"{"id":"outside"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 100)
                }
                return .init(message: .init(role: "assistant", content: "这句是在问为何长叹。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
            }
        XCTAssertEqual(result.message.evidence.map(\.unitID), ["u1"])
        let completed = events.values().filter { $0.phase == .toolCompleted }
        XCTAssertEqual(completed.count, 2, "失败不能重复发出完成事件")
        XCTAssertEqual(completed.map(\.toolSucceeded), [true, false])
        XCTAssertEqual(completed[0].toolTrace?.fragments.first?.text, book.units[0].text)
        XCTAssertTrue(completed[1].toolTrace?.result.text.contains("冻结范围") == true)
    }

    func testAIReaderCapturesActualPreparedRequestsIncludingReturnedSource() async throws {
        let book = BookProject(id: "trace-reader", title: "过程", originalName: "source.pdf", sourceHash: "hash",
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", page: 104, text: "請問將軍，為何在此長歎？")])
        let events = TraceEventRecorder(), calls = TraceRequestCounter()
        let reader = AIReader(transport: { _ in
            if await calls.next() == 1 {
                return .init(message: .init(role: "assistant", content: nil, refusal: nil,
                    tool_calls: [.init(id: "read", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u1"}"#))],
                    reasoning_content: "PRIVATE_REASONING_NOT_FOR_DETAILS"), finishReason: "tool_calls", tokenCost: 100)
            }
            return .init(message: .init(role: "assistant", content: "这句在问为何长叹。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
        })
        await reader.setProgressHandler { events.append($0) }
        _ = try await reader.answer(question: "为何长叹", project: book,
            settings: .init(baseURL: "http://127.0.0.1/offline", model: "offline", maxRequestsPerRun: 4, maxOutputTokens: 1000, contextWindowTokens: 128_000),
            apiKey: "PRIVATE_HEADER_KEY", queryScope: .book, memoryEnabled: false)
        let started = events.values().filter { $0.phase == .waitingForResponse }
        XCTAssertEqual(started.count, 2)
        XCTAssertTrue(started.allSatisfy { $0.requestTrace != nil })
        let texts = started.compactMap(\.requestTrace).flatMap(\.messages).map { $0.content.text }.joined()
        XCTAssertTrue(texts.contains("請問將軍，為何在此長歎？"))
        XCTAssertFalse(texts.contains("PRIVATE_HEADER_KEY"))
        XCTAssertFalse(texts.contains("PRIVATE_REASONING"))
        XCTAssertEqual(events.values().filter { $0.phase == .requestCompleted }.count, 2)
        let responses = events.values().filter { $0.phase == .requestCompleted }.compactMap(\.responseTrace)
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses[0].toolCalls.map(\.name), ["source_read"])
        XCTAssertTrue(responses[1].content?.text.contains("这句在问为何长叹") == true)
        XCTAssertFalse(String(reflecting: responses).contains("PRIVATE_REASONING"))
        XCTAssertFalse(String(reflecting: responses).contains("PRIVATE_HEADER_KEY"))
    }
    func testPublicResponseRetainsTextToolsAndTruncationWithoutPrivateReasoning() throws {
        let result = ProviderClient.Result(message: .init(role: "assistant", content: "公开的回答", refusal: nil,
            tool_calls: [.init(id: "call-one", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u1"}"#))],
            reasoning_content: "PRIVATE_REASONING_NOT_FOR_UI"), finishReason: "length", tokenCost: 10)
        let trace = AIResponseTrace.capture(result)
        XCTAssertEqual(trace.content?.text, "公开的回答")
        XCTAssertEqual(trace.toolCalls.first?.arguments.text, #"{"id":"u1"}"#)
        XCTAssertEqual(trace.finishReason, "length"); XCTAssertEqual(trace.omittedToolCalls, 0)
        XCTAssertFalse(String(reflecting: trace).contains("PRIVATE_REASONING"))
    }
    func testLongResponsesAndManyToolCallsHaveAnExplicitRetentionBoundary() throws {
        let calls = (0..<80).map { ProviderClient.ToolCall(id: "call-\($0)", type: "function", function: .init(name: "source_read", arguments: String(repeating: "长参数", count: 20000))) }
        let response = ProviderClient.Result(message: .init(role: "assistant", content: String(repeating: "长回答", count: 30000), refusal: nil, tool_calls: calls, reasoning_content: nil), finishReason: "tool_calls", tokenCost: 10)
        for cap in [0, 128, 262144] {
            let trace = AIResponseTrace.capture(response, maximumBytes: cap)
            XCTAssertLessThanOrEqual(trace.retainedBytes, cap)
            XCTAssertLessThanOrEqual(trace.toolCalls.count, 32)
            XCTAssertEqual(trace.toolCalls.count + trace.omittedToolCalls, 80)
            XCTAssertTrue(trace.content?.isPartial == true)
        }
        let refusal = AIResponseTrace.capture(.init(message: .init(role: "assistant", content: nil, refusal: "暂不能回答", tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 10))
        XCTAssertNil(refusal.content); XCTAssertEqual(refusal.refusal?.text, "暂不能回答")
    }
}

private final class TraceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AIProgressEvent] = []
    func append(_ event: AIProgressEvent) { lock.lock(); events.append(event); lock.unlock() }
    func values() -> [AIProgressEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
private actor TraceRequestCounter { private var value = 0; func next() -> Int { value += 1; return value } }
