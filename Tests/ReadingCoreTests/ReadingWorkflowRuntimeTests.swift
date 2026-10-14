import Foundation
import XCTest
@testable import ReadingCore

final class ReadingWorkflowRuntimeTests: XCTestCase {
    func testExecutableMathDeclarationImportsWithDefaultBindingOptions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: root.appendingPathComponent("Examples/math-plugin.json")))
        var value = try project()
        try PluginEngine.install(manifest, into: &value)
        let method = try XCTUnwrap(value.methods.first { $0.id == "example-math-reading" })
        XCTAssertEqual(method.executions?.count, method.steps.count)
        XCTAssertTrue(method.executions?.allSatisfy { $0.configuration.isEmpty && $0.maxAttempts == 3 } == true)
        XCTAssertEqual(method.executions?.last?.actionID, "citations.verify")
        XCTAssertNoThrow(try ReadingWorkflowRuntime.validate(method: method))
        let restored = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.methods, value.methods)
    }

    private func project(withReceipts: Bool = true, executions: [ReadingStepExecution]? = nil, steps: [String] = ["提取条件", "复核引用"]) throws -> BookProject {
        let unit = SourceUnit(id: "u1", order: 0, chapter: "第一章", text: "设 α > 0。\n\n结论依赖这个条件。\n")
        var project = BookProject(title: "测试", originalName: "test.md", sourceHash: "source", units: [unit])
        project.methods = [ReadingMethod(id: "m1", name: "精读", goal: "逐步核对", steps: steps, executions: executions)]
        project.types = [EntityType(id: "concept", name: "概念")]
        project.plan = ReadingPlan(methodIDs: ["m1"])
        if withReceipts {
            project.paragraphReceipts = try ReadingLedger.paragraphs(for: unit, in: project).map {
                ParagraphReceipt(paragraphID: $0.id, unitID: $0.unitID, unitHash: $0.unitHash, textHash: $0.textHash,
                                 utf8Start: $0.utf8Start, utf8End: $0.utf8End, summary: "原文给出正数条件与依赖。",
                                 startQuote: $0.startQuote, endQuote: $0.endQuote, issues: [], createdAt: Date())
            }
        }
        return project
    }

    private var successfulModel: ReadingWorkflowServices {
        ReadingWorkflowServices { task, value in
            var candidate = value
            let output = ReadingWorkflowOutput(result: "本步核对 α > 0，结论以此为条件。", paragraphIDs: task.input.paragraphIDs,
                                               evidence: [Evidence(unitID: "u1", quote: "设 α > 0。")], noChangesReason: "此测试只核对已有条件，无新增知识对象。")
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID, output: output, to: &candidate, allowedUnitIDs: ["u1"])
            return candidate
        }
    }

    func testReceiptsRemainMandatoryAndBindingsMustCoverEveryStep() throws {
        let minimal = try JSONDecoder().decode(ReadingStepExecution.self, from: Data(#"{"stepIndex":0,"actionID":"ai.analyze"}"#.utf8))
        XCTAssertEqual(minimal.configuration, [:]); XCTAssertEqual(minimal.maxAttempts, 3)
        let missing = try project(withReceipts: false)
        XCTAssertThrowsError(try ReadingWorkflowRuntime.nextTask(for: missing.units[0], in: missing))
        let method = ReadingMethod(id: "bad", name: "错误", goal: "检查", steps: ["一", "二"], executions: [ReadingStepExecution(stepIndex: 0, actionID: "ai.analyze")])
        XCTAssertThrowsError(try ReadingWorkflowRuntime.validate(method: method))
        let unknown = ReadingMethod(id: "unknown", name: "错误", goal: "检查", steps: ["一"], executions: [ReadingStepExecution(stepIndex: 0, actionID: "shell.execute")])
        XCTAssertThrowsError(try ReadingWorkflowRuntime.validate(method: unknown))
    }

    func testOneActionCheckpointRoundTripsAndResumeDoesNotReplayIt() async throws {
        var value = try project(executions: [ReadingStepExecution(stepIndex: 0, actionID: "facts.extract"), ReadingStepExecution(stepIndex: 1, actionID: "citations.verify")])
        let first = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        XCTAssertEqual(first.action.id, "facts.extract")
        value = try await ReadingWorkflowRuntime.perform(first, in: value, services: successfulModel)
        XCTAssertEqual(value.workflowRuns?.count, 1)
        XCTAssertEqual(value.workflowRuns?.first?.status, .completed)
        XCTAssertEqual(value.coverage["u1"]?.status, nil, "一步成功不等于整页完成。")
        XCTAssertThrowsError(try ReadingWorkflowRuntime.requireComplete(unitIDs: ["u1"], in: value))
        let decoded = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.workflowRuns, value.workflowRuns)
        let second = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: decoded.units[0], in: decoded))
        XCTAssertNotEqual(first.requirement.stepID, second.requirement.stepID)
        XCTAssertEqual(second.action.id, "citations.verify")
        let noModel = ReadingWorkflowServices { _, _ in XCTFail("引用核验必须本地执行。"); throw ReadingError.invalid("unexpected model call") }
        value = try await ReadingWorkflowRuntime.perform(second, in: decoded, services: noModel)
        XCTAssertEqual(value.workflowRuns?.count, 2)
        XCTAssertEqual(value.workflowRuns?.first?.attempts, 1)
        XCTAssertEqual(value.workflowRuns?.last?.toolNames, ["citations.verify"])
        XCTAssertNil(try ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        XCTAssertNoThrow(try ReadingWorkflowRuntime.requireComplete(unitIDs: ["u1"], in: value))
        XCTAssertNoThrow(try ReadingLedger.validateStoredRecords(in: value))
    }

    func testFailureRollsBackActionAndPersistsRetryUntilExplicitLimitReset() async throws {
        var value = try project(executions: [ReadingStepExecution(stepIndex: 0, actionID: "facts.extract", maxAttempts: 1)], steps: ["提取"])
        let first = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        let failing = ReadingWorkflowServices { _, original in
            var candidate = original
            candidate.entities.append(KnowledgeEntity(id: "half-written", typeID: "concept", name: "不应提交"))
            throw ReadingError.invalid("模拟服务失败")
        }
        value = try await ReadingWorkflowRuntime.perform(first, in: value, services: failing)
        XCTAssertTrue(value.entities.isEmpty)
        XCTAssertNil(value.readingStepResults)
        XCTAssertEqual(value.workflowRuns?.first?.status, .failed)
        XCTAssertEqual(value.workflowRuns?.first?.attempts, 1)
        XCTAssertNotNil(ReadingWorkflowRuntime.failureMessage(in: value, unitID: "u1"))
        do {
            _ = try await ReadingWorkflowRuntime.perform(first, in: value, services: successfulModel)
            XCTFail("超过上限不能发送执行请求。")
        } catch { XCTAssertTrue(error.localizedDescription.contains("重试上限")) }
        try ReadingWorkflowRuntime.resetRetry(stepID: first.requirement.stepID, in: &value)
        value = try await ReadingWorkflowRuntime.perform(first, in: value, services: successfulModel)
        XCTAssertEqual(value.workflowRuns?.first?.status, .completed)
        XCTAssertNil(ReadingWorkflowRuntime.failureMessage(in: value))
    }

    func testAddedMethodRemainsPendingAndTamperedInputCannotLoad() async throws {
        var value = try project(steps: ["分析"])
        let first = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        value = try await ReadingWorkflowRuntime.perform(first, in: value, services: successfulModel)
        value.methods.append(ReadingMethod(id: "later", name: "复盘", goal: "核查", steps: ["检查遗漏"], executions: [ReadingStepExecution(stepIndex: 0, actionID: "reading.review")]))
        value.plan?.methodIDs.append("later")
        let next = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        XCTAssertEqual(next.requirement.methodID, "later")
        XCTAssertThrowsError(try ReadingWorkflowRuntime.requireComplete(unitIDs: ["u1"], in: value))
        var damaged = value
        damaged.workflowRuns?[0].input.instruction = "跳过后续步骤"
        XCTAssertThrowsError(try ReadingLedger.validateStoredRecords(in: damaged))
    }

    func testExtractionNeedsActualWriteOrExplicitNoChangesAndVerificationChecksQuotes() async throws {
        var value = try project(executions: [ReadingStepExecution(stepIndex: 0, actionID: "facts.extract"), ReadingStepExecution(stepIndex: 1, actionID: "citations.verify")])
        let first = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        let pretend = ReadingWorkflowServices { task, original in
            var candidate = original
            let output = ReadingWorkflowOutput(result: "声称已创建，但没有调用写入。", paragraphIDs: task.input.paragraphIDs, evidence: [Evidence(unitID: "u1", quote: "设 α > 0。")])
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID, output: output, to: &candidate, allowedUnitIDs: ["u1"])
            return candidate
        }
        value = try await ReadingWorkflowRuntime.perform(first, in: value, services: pretend)
        XCTAssertEqual(value.workflowRuns?.first?.status, .failed)
        XCTAssertNil(value.readingStepResults)
        let actualWrite = ReadingWorkflowServices { task, original in
            var candidate = original
            candidate.entities.append(KnowledgeEntity(id: "positive", typeID: "concept", name: "正数条件", evidence: [Evidence(unitID: "u1", quote: "设 α > 0。")]))
            ReadingWorkflowRuntime.recordTool("custom_fact_writer", in: &candidate, previous: original)
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID,
                output: ReadingWorkflowOutput(result: "已实际保存正数条件。", paragraphIDs: task.input.paragraphIDs, evidence: [Evidence(unitID: "u1", quote: "设 α > 0。")]),
                to: &candidate, allowedUnitIDs: ["u1"])
            return candidate
        }
        value = try await ReadingWorkflowRuntime.perform(first, in: value, services: actualWrite)
        XCTAssertEqual(value.workflowRuns?.first?.knowledgeWriteTools, ["custom_fact_writer"])
        value.entities[0].evidence[0].quote = "原文不存在的引文"
        let verification = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        value = try await ReadingWorkflowRuntime.perform(verification, in: value, services: successfulModel)
        XCTAssertEqual(value.workflowRuns?.last?.status, .failed)
        XCTAssertTrue(value.workflowRuns?.last?.error?.contains("引用核验失败") ?? false)
    }

    func testLegacyMethodEncodingAndCompletedBookDoNotGainInventedRuns() throws {
        let raw = Data(#"{"id":"legacy","name":"旧方法","goal":"核对","steps":["复述"]}"#.utf8)
        let legacy = try JSONDecoder().decode(ReadingMethod.self, from: raw)
        XCTAssertNil(legacy.executions)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let old = try JSONSerialization.data(withJSONObject: ["id": "legacy", "name": "旧方法", "goal": "核对", "steps": ["复述"]], options: [.sortedKeys])
        XCTAssertEqual(try encoder.encode(legacy), old, "旧方法编码不应新增nil字段导致历史methodHash改变。")
        var value = try project(withReceipts: false)
        var entry = CoverageEntry(); entry.status = .completed; value.coverage["u1"] = entry
        let decoded = try JSONDecoder().decode(BookProject.self, from: encoder.encode(value))
        XCTAssertNil(decoded.workflowRuns)
        XCTAssertNil(decoded.paragraphReceipts)
        XCTAssertNoThrow(try ReadingLedger.validateStoredRecords(in: decoded))
        XCTAssertNoThrow(try ReadingWorkflowRuntime.requireComplete(unitIDs: ["u1"], in: decoded))
    }

    func testRegisteredLocalActionExecutesThroughSameRuntimeAndUnknownArchiveStaysReadable() async throws {
        var value = try project(executions: [ReadingStepExecution(stepIndex: 0, actionID: "example.local-count")], steps: ["本地核对正文字符数"])
        var registry = ReadingWorkflowActionRegistry.builtIn
        let action = ReadingWorkflowAction(descriptor: ReadingWorkflowActionDescriptor(id: "example.local-count", title: "本地字符核对", detail: "对原文执行确定性字符计数。")) { task, original, _ in
            var candidate = original
            let text = try XCTUnwrap(original.units.first { $0.id == task.requirement.unitID }).text
            let output = ReadingWorkflowOutput(result: "宿主实际核对正文，共 \(text.count) 个字符。", paragraphIDs: task.input.paragraphIDs,
                                               evidence: [Evidence(unitID: task.requirement.unitID, quote: "设 α > 0。")])
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID, output: output, to: &candidate, allowedUnitIDs: [task.requirement.unitID])
            return candidate
        }
        try registry.register(action)
        XCTAssertThrowsError(try registry.register(action))
        XCTAssertThrowsError(try ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        let task = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value, registry: registry))
        let noModel = ReadingWorkflowServices { _, _ in XCTFail("本地注册动作不得调用模型。"); throw ReadingError.invalid("unexpected model call") }
        value = try await ReadingWorkflowRuntime.perform(task, in: value, services: noModel, registry: registry)
        XCTAssertEqual(value.workflowRuns?.first?.status, .completed)
        XCTAssertTrue(value.workflowRuns?.first?.output?.result.contains("\(value.units[0].text.count)") ?? false)
        XCTAssertNil(try ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value, registry: registry))
        XCTAssertNoThrow(try ReadingWorkflowRuntime.requireComplete(unitIDs: ["u1"], in: value, registry: registry))
        let archive = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(value))
        XCTAssertNoThrow(try ReadingLedger.validateStoredRecords(in: archive), "未加载扩展时仍可读取完整历史记录。")
        XCTAssertThrowsError(try ReadingWorkflowRuntime.requireComplete(unitIDs: ["u1"], in: archive), "未加载动作不能被宿主当成新的执行终态。")
    }

    func testBudgetPauseSavesCheckpointWithoutConsumingFailureAttempts() async throws {
        var value = try project(executions: [ReadingStepExecution(stepIndex: 0, actionID: "ai.analyze", maxAttempts: 1)], steps: ["分析"])
        let task = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        let exhausted = ReadingWorkflowServices { _, _ in throw ReadingWorkflowBudgetPause(message: "本轮请求预算用尽") }
        value = try await ReadingWorkflowRuntime.perform(task, in: value, services: exhausted)
        XCTAssertEqual(value.workflowRuns?.first?.status, .failed)
        XCTAssertEqual(value.workflowRuns?.first?.attempts, 0)
        XCTAssertNotNil(ReadingWorkflowRuntime.failureMessage(in: value))
        XCTAssertNoThrow(try ReadingLedger.validateStoredRecords(in: value))
        value = try await ReadingWorkflowRuntime.perform(task, in: value, services: successfulModel)
        XCTAssertEqual(value.workflowRuns?.first?.status, .completed)
        XCTAssertEqual(value.workflowRuns?.first?.attempts, 1)
    }
}
