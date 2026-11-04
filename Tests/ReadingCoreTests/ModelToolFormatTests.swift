import Foundation
import XCTest
@testable import ReadingCore

final class ModelToolFormatTests: XCTestCase {
    private func project() -> BookProject {
        BookProject(title: "合成读本", originalName: "book.txt", sourceHash: "fixture",
            units: [.init(id: "u1", order: 0, chapter: "一", page: 1, text: "刘备与关羽同行。")])
    }
    private func answer(_ text: String) -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: text, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
    }
    func testRawToolFormatGetsOneBoundedRepairAndOnlyStructuredCallsExecute() async throws {
        actor Trace { var calls: [String] = []; func add(_ name: String) { calls.append(name) } }
        let trace = Trace()
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { name, _ in
            await trace.add(name); return Data(#"{"ok":true,"status":"success","opened":true,"created":true}"#.utf8)
        })
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "理一理人物关系", project: project(), settings: .init(model: "fixture", maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 4, hostTools: host) { messages, _, _, _ in
                requests += 1
                if requests == 1 { return self.answer("<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"component_show\">\n</｜DSML｜ invoke>\n</｜DSML｜ calls>") }
                if requests == 2 {
                    XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("工具协议") == true })
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: "show", type: "function", function: .init(name: "component_show", arguments: #"{"componentID":"relations"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
                }
                return self.answer("已打开关系图谱。")
            }
        let calls = await trace.calls
        XCTAssertEqual(requests, 3); XCTAssertEqual(calls, ["component_show"])
        XCTAssertEqual(result.message.content, "已打开关系图谱。")
        XCTAssertFalse(result.message.content.contains("DSML"))
    }
    func testRepeatedToolMarkupFailsWithoutExecutingOrSavingItAsAnswer() async throws {
        var requests = 0
        do {
            _ = try await ReadingAnswerEngine.run(question: "理一理人物关系", project: project(), settings: .init(model: "fixture", maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page,
                history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 6) { _, _, _, _ in
                    requests += 1; return self.answer("<tool_call>{\"name\":\"component_show\"}</tool_call>")
                }
            XCTFail("内部调用标记不能作为回答保存")
        } catch { XCTAssertTrue(error.localizedDescription.contains("工具格式")) }
        XCTAssertEqual(requests, 2)
    }
    func testQuotedToolMarkupRemainsOrdinaryReadingContent() async throws {
        let content = "书里展示了一段协议示例：\n```text\n<tool_call>示例文字</tool_call>\n```"
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "说明这段协议示例", project: project(), settings: .init(model: "fixture", maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 1) { _, _, _, _ in requests += 1; return self.answer(content) }
        XCTAssertTrue(result.message.content.contains(content))
        XCTAssertEqual(requests, 1)
    }
}
