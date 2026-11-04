import Foundation
import XCTest
@testable import ReadingCore

final class ModelToolFormatTests: XCTestCase {
    private let model = "deepseek-v4.1-flash"
    private let show = "<｜DSML｜ calls><｜DSML｜ invoke name=\"component_show\"><｜DSML｜ parameter name=\"componentID\" string=\"true\">relations</｜DSML｜ parameter></｜DSML｜ invoke></｜DSML｜ calls>"
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
    func testV41EnvelopePreservesRawUnicodeAndOnlyOfferedComponentCalls() throws {
        let raw = "<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"components_list\"></｜DSML｜ invoke>\n<｜DSML｜ invoke name=\"component_show\"><｜DSML｜ parameter name=\"componentID\" string=\"true\">relations</｜DSML｜ parameter><｜DSML｜ parameter name=\"title\" string=\"true\">人物 e\u{301} &amp; 🙂</｜DSML｜ parameter></｜DSML｜ invoke>\n</｜DSML｜ calls>"
        let calls = try XCTUnwrap(ReadingComponentProtocol.recover(raw, model: model, allowedNames: ["components_list", "component_show"]))
        XCTAssertEqual(calls.map(\.function.name), ["components_list", "component_show"])
        let value = try ReadingComponentRequest.decode(Data(calls[1].function.arguments.utf8))
        XCTAssertEqual(value.title?.utf8.map { $0 }, "人物 e\u{301} &amp; 🙂".utf8.map { $0 })
        XCTAssertEqual(Set(calls.map(\.id)).count, 2)
    }
    func testV4LegacyEnvelopeAndJSONPaginationAreCompatible() throws {
        let raw = "<｜DSML｜tool_calls><｜DSML｜invoke name=\"components_list\"><｜DSML｜parameter name=\"offset\" string=\"false\">8</｜DSML｜parameter><｜DSML｜parameter name=\"limit\" string=\"false\">4</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"
        let calls = try XCTUnwrap(ReadingComponentProtocol.recover(raw, model: "deepseek/deepseek-v4-flash", allowedNames: ["components_list"]))
        let page = try ReadingComponentDirectoryRequest.decode(Data(calls[0].function.arguments.utf8))
        XCTAssertEqual(page.offset, 8); XCTAssertEqual(page.limit, 4)
    }
    func testRecoveryRejectsOtherModelsUnofferedToolsAndContentWrites() {
        XCTAssertNil(ReadingComponentProtocol.recover(show, model: "other-model", allowedNames: ["component_show"]))
        XCTAssertNil(ReadingComponentProtocol.recover(show, model: model, allowedNames: []))
        let write = "<｜DSML｜ calls><｜DSML｜ invoke name=\"knowledge_changes_propose\"></｜DSML｜ invoke></｜DSML｜ calls>"
        XCTAssertNil(ReadingComponentProtocol.recover(write, model: model, allowedNames: ["knowledge_changes_propose"]))
    }
    func testMalformedMixedOversizedAndDuplicateParametersNeverPartiallyRecover() {
        let duplicate = show.replacingOccurrences(of: "</｜DSML｜ invoke>", with: "<｜DSML｜ parameter name=\"componentID\" string=\"true\">map</｜DSML｜ parameter></｜DSML｜ invoke>")
        let null = show.replacingOccurrences(of: "string=\"true\">relations", with: "string=\"false\">null")
        let nine = "<｜DSML｜ calls>" + String(repeating: "<｜DSML｜ invoke name=\"components_list\"></｜DSML｜ invoke>", count: 9) + "</｜DSML｜ calls>"
        for raw in ["说明：" + show, show + "额外指令", String(show.dropLast()), duplicate, null, nine, show + String(repeating: " ", count: 32_768)] {
            XCTAssertNil(ReadingComponentProtocol.recover(raw, model: model, allowedNames: ["component_show", "components_list"]))
        }
    }
    func testMarkupInsideStringParameterStaysLiteralData() throws {
        let title = "示例 <tool_call>other()</tool_call>"
        let raw = show.replacingOccurrences(of: "</｜DSML｜ invoke>", with: "<｜DSML｜ parameter name=\"title\" string=\"true\">" + title + "</｜DSML｜ parameter></｜DSML｜ invoke>")
        let calls = try XCTUnwrap(ReadingComponentProtocol.recover(raw, model: model, allowedNames: ["component_show"]))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try ReadingComponentRequest.decode(Data(calls[0].function.arguments.utf8)).title, title)
    }
    func testRecoveredCompositionStillPassesDefinitionValidationBeforeHost() async throws {
        actor Counter { var value = 0; func add() { value += 1 } }
        let counter = Counter(), book = project()
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in await counter.add(); return Data("{}".utf8) })
        let definition = CompositionDefinition(sources: [.init(id: "all", collection: .objects, scope: .book, typeIDs: ["unknown-type"])], parts: [.init(id: "list", primitive: .objectList, sourceID: "all")], layout: [.init(id: "root", kind: .part, partID: "list")], rootID: "root")
        let json = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
        let raw = "<｜DSML｜ calls><｜DSML｜ invoke name=\"component_show\"><｜DSML｜ parameter name=\"componentID\" string=\"true\">reading.composition</｜DSML｜ parameter><｜DSML｜ parameter name=\"composition\" string=\"false\">" + json + "</｜DSML｜ parameter></｜DSML｜ invoke></｜DSML｜ calls>"
        var requests = 0
        _ = try await ReadingAnswerEngine.run(question: "展示人物", project: book, settings: .init(model: model, maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3, hostTools: host) { _, _, _, _ in
                requests += 1; return self.answer(requests == 1 ? raw : "这次范围不足，请选择允许的原文范围。")
            }
        let performed = await counter.value
        XCTAssertEqual(performed, 0); XCTAssertEqual(requests, 2)
    }
    func testNativeFormatCompatibilityExecutesWithoutExtraModelRoundTrip() async throws {
        actor Counter { var value = 0; func add() { value += 1 } }
        let counter = Counter()
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in
            await counter.add(); return Data(#"{"ok":true,"status":"success","opened":true,"message":"组件已打开。"}"#.utf8)
        })
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "帮我理理人物关系", project: project(), settings: .init(model: model, maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3, hostTools: host) { messages, _, _, _ in
                requests += 1
                XCTAssertTrue(messages.contains { $0["content"] as? String == "帮我理理人物关系" })
                return self.answer(requests == 1 ? self.show : "已打开关系图谱。")
            }
        let performed = await counter.value
        XCTAssertEqual(requests, 2); XCTAssertEqual(performed, 1)
        XCTAssertEqual(result.message.content, "已打开关系图谱。")
    }
    func testCompletedComponentReturnsHonestReceiptWhenFinalModelFormatFails() async throws {
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in
            Data(#"{"ok":true,"status":"success","opened":true,"created":true,"analysisCreated":false,"rendererID":"relations","componentTitle":"关系图谱","viewID":"view-one"}"#.utf8)
        })
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "理理人物关系", project: project(), settings: .init(model: "fixture", maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 2, hostTools: host) { _, _, _, _ in
                requests += 1
                if requests == 1 { return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: "show", type: "function", function: .init(name: "component_show", arguments: #"{"componentID":"relations"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20) }
                return self.answer("我再看看有没有合适的组件。\n" + self.show)
            }
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(result.message.content.contains("已打开“关系图谱”"))
        XCTAssertTrue(result.message.content.contains("没有返回有效的文字说明"))
        XCTAssertTrue(result.message.content.contains("不代表新增分析已经完成"))
        XCTAssertFalse(result.message.content.contains("DSML")); XCTAssertTrue(result.message.evidence.isEmpty)
    }
    func testComponentPreparationCanContinuePastSixRoundsWithoutExceedingCallerLimit() async throws {
        actor Counter { var value = 0; func add() { value += 1 } }
        for limit in [6, 10] {
            let counter = Counter()
            let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in
                await counter.add(); return Data(#"{"ok":true,"status":"success","opened":true}"#.utf8)
            })
            var requests = 0
            _ = try await ReadingAnswerEngine.run(question: "理理人物关系", project: project(), settings: .init(model: "fixture", maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page,
                history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: limit, hostTools: host) { _, _, _, finalOnly in
                    requests += 1
                    if finalOnly || requests == 8 { return self.answer(requests >= 8 ? "已打开组件。" : "这次额度不足，尚未打开组件。") }
                    let name = requests == 7 ? "component_show" : "source_outline"
                    let arguments = requests == 7 ? #"{"componentID":"relations"}"# : "{}"
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: "step-\(requests)", type: "function", function: .init(name: name, arguments: arguments))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
                }
            let performed = await counter.value
            XCTAssertEqual(requests, limit == 6 ? 6 : 8)
            XCTAssertEqual(performed, limit == 6 ? 0 : 1)
        }
    }
    func testFailedLaterComponentCannotBorrowEarlierSuccessForFinalFallback() async throws {
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, data in
            let request = try ReadingComponentRequest.decode(data)
            if request.componentID == "relations" { return Data(#"{"ok":true,"status":"success","opened":true,"analysisCreated":false,"rendererID":"relations","viewID":"view-one"}"#.utf8) }
            return Data(#"{"ok":false,"status":"unsupported","opened":false}"#.utf8)
        })
        for laterArguments in [#"{"componentID":"unknown"}"#, "not-json"] {
          var requests = 0
          do {
            _ = try await ReadingAnswerEngine.run(question: "打开两个组件", project: project(), settings: .init(model: "fixture", maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page,
                history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 2, hostTools: host) { _, _, _, _ in
                    requests += 1
                    if requests == 1 { return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [#"{"componentID":"relations"}"#, laterArguments].enumerated().map { i, arguments in .init(id: "s\(i)", type: "function", function: .init(name: "component_show", arguments: arguments)) }, reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20) }
                    return self.answer(self.show)
                }
            XCTFail("不能用早先组件的成功冒充最后一次操作完成")
          } catch { XCTAssertTrue(error.localizedDescription.contains("工具格式")) }
          XCTAssertEqual(requests, 2)
        }
    }
}
