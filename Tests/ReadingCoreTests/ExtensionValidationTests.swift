import Foundation
import XCTest
@testable import ReadingCore

final class ExtensionValidationTests: XCTestCase {
    private func book() -> BookProject {
        var value = BookProject(title: "代数", originalName: "a.md", sourceHash: "source",
                                units: [SourceUnit(id: "p1", order: 0, chapter: "第一章", text: "设方程 2x=1。")])
        PluginEngine.seed(&value)
        value.plan = ReadingPlan(methodIDs: ["textbook"], rationale: "教材精读", focus: [])
        return value
    }

    func testLegacyNilExtensionsAndValidManualMathTrashRemainLoadable() throws {
        var value = book()
        XCTAssertNoThrow(try MathVerificationTools.validateStoredRecords(in: value))
        XCTAssertNoThrow(try BookSchemeRuntime.validateStoredState(in: value))
        var record = try MathVerificationEngine.verify(MathVerificationRequest(input: "2 1"))
        record.deletedAt = Date()
        value.mathVerifications = [record]
        XCTAssertNoThrow(try MathVerificationTools.validateStoredRecords(in: value))
        value.mathVerifications?[0].solution?.particular = ["99"]
        XCTAssertThrowsError(try MathVerificationTools.validateStoredRecords(in: value), "Trash must not bypass deterministic result validation.")
    }

    func testStandaloneAIRecordIsRecomputedAndCannotForgeWorkflowOwnership() throws {
        var value = book()
        let request = MathVerificationRequest(input: "设方程 2x=1。", matrix: [["2", "1"]],
            evidence: [Evidence(unitID: "p1", quote: "设方程 2x=1。")], origin: .aiStructured)
        let record = try MathVerificationEngine.verify(request)
        value.mathVerifications = [record]
        XCTAssertNoThrow(try MathVerificationTools.validateStoredRecords(in: value))
        value.mathVerifications?[0].workflowStepID = "missing-step"; value.mathVerifications?[0].workflowAttempt = 1
        XCTAssertThrowsError(try MathVerificationTools.validateStoredRecords(in: value))
        value.mathVerifications = [record, record]
        XCTAssertThrowsError(try MathVerificationTools.validateStoredRecords(in: value), "Duplicate IDs must not enter history pickers.")
        value.mathVerifications = [record]; value.units[0].text = "已替换的原文"
        XCTAssertThrowsError(try MathVerificationTools.validateStoredRecords(in: value))
    }

    func testManualMathEvidenceAndHostBindingAreValidated() throws {
        var value = book()
        var record = try MathVerificationEngine.verify(MathVerificationRequest(input: "2 1",
            evidence: [Evidence(unitID: "p1", quote: "设方程")]))
        value.mathVerifications = [record]
        XCTAssertNoThrow(try MathVerificationTools.validateStoredRecords(in: value))
        value.mathVerifications?[0].request.evidence = [Evidence(unitID: "p1", quote: "不存在的原句")]
        XCTAssertThrowsError(try MathVerificationTools.validateStoredRecords(in: value))
        record.workflowStepID = "pretend-run"; record.workflowAttempt = 1
        value.mathVerifications = [record]
        XCTAssertThrowsError(try MathVerificationTools.validateStoredRecords(in: value))
    }

    func testMathCacheRequiresExactRecordAndRechecksLiveSourceOnEverySave() throws {
        var value = book()
        let record = try MathVerificationEngine.verify(MathVerificationRequest(input: "2 1",
            evidence: [Evidence(unitID: "p1", quote: "设方程")]))
        value.mathVerifications = [record]
        var cache = MathVerificationValidationCache()
        try MathVerificationTools.validateStoredRecords(in: value, cache: &cache)
        XCTAssertNoThrow(try MathVerificationTools.validateStoredRecords(in: value, cache: &cache))
        var bad = value; bad.mathVerifications?[0].solution?.particular = ["99"]
        XCTAssertThrowsError(try MathVerificationTools.validateStoredRecords(in: bad, cache: &cache))
        bad = value; bad.units[0].text = "已改变的内容"
        XCTAssertThrowsError(try MathVerificationTools.validateStoredRecords(in: bad, cache: &cache), "A record cache never certifies current source content.")
        XCTAssertNoThrow(try MathVerificationTools.validateStoredRecords(in: value, cache: &cache), "Rejected changes must not poison validated records.")
    }

    func testStaleSchemeAndLaterConfigurationConflictCanBeLoadedAndDiscarded() throws {
        let original = book()
        var proposed = original
        proposed.views = [ViewDefinition(id: "math", title: "数学核查", kind: .knowledge, rendererID: "math.verify")]
        var value = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed)
        value.units[0].text += "新增文字"; value.views = [ViewDefinition(id: "later", title: "后来添加", kind: .cards)]
        XCTAssertNoThrow(try BookSchemeRuntime.validateStoredState(in: value))
        XCTAssertThrowsError(try BookSchemeRuntime.applyPending(in: &value))
        BookSchemeRuntime.discardPending(in: &value)
        XCTAssertNil(value.bookSchemes?.pending)
        XCTAssertEqual(value.views.map(\.id), ["later"])
    }

    func testSchemeRejectsDanglingSelectionAndDuplicateHistoryWithoutDiscardingUnknownPluginMetadata() throws {
        let original = book()
        var proposed = original
        proposed.views = [ViewDefinition(id: "future", title: "以后安装的组件", kind: .knowledge, rendererID: "native.future")]
        var value = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed)
        XCTAssertNoThrow(try BookSchemeRuntime.validateStoredState(in: value))
        value.bookSchemes?.pending?.selection.typeIDs.insert("missing-type")
        XCTAssertThrowsError(try BookSchemeRuntime.validateStoredState(in: value))
        value = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed)
        let pending = try XCTUnwrap(value.bookSchemes?.pending)
        let revision = BookSchemeRevision(proposal: pending, after: pending.proposed)
        value.bookSchemes?.pending = nil; value.bookSchemes?.history = [revision, revision]
        XCTAssertThrowsError(try BookSchemeRuntime.validateStoredState(in: value))
    }

    func testSchemeHistoricalUnknownActionAndDisabledPlanAreArchivalData() throws {
        var value = book()
        let method = ReadingMethod(id: "native-method", name: "原生扩展", goal: "保留扩展", steps: ["自定义处理"],
            executions: [ReadingStepExecution(stepIndex: 0, actionID: "native.future")])
        value.methods.append(method)
        value.plugins = [PluginManifest(id: "optional", name: "原生扩展", description: "历史声明", methods: [method])]
        value.disabledPluginIDs = ["optional"]; value.plan = ReadingPlan(methodIDs: [method.id])
        _ = try BookSchemeRuntime.saveTemplate(name: "历史方案", in: &value)
        XCTAssertNoThrow(try BookSchemeRuntime.validateStoredState(in: value))
        value.bookSchemes?.templates[0].configuration.disabledPluginIDs.append("nonexistent-pack")
        XCTAssertThrowsError(try BookSchemeRuntime.validateStoredState(in: value))
    }

    func testModelCanConfigureRealMathAndSchemeRenderersButNotUnknownOrMismatchedKinds() throws {
        var value = book()
        let views: [[String: Any]] = [
            ["id": "math", "title": "数学核查", "kind": "knowledge", "rendererID": "math.verify"],
            ["id": "scheme", "title": "书本方案", "kind": "workflow", "rendererID": "book.scheme"]
        ]
        _ = try PluginEngine.apply(name: "views_configure", arguments: JSONSerialization.data(withJSONObject: ["views": views]),
                                   to: &value, allowedUnitIDs: [], phase: .planning)
        XCTAssertEqual(value.views.map(\.rendererID), ["math.verify", "book.scheme"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(value)
        for invalid in [
            ["id": "wrong", "title": "错误类型", "kind": "cards", "rendererID": "math.verify"],
            ["id": "unknown", "title": "不存在", "kind": "knowledge", "rendererID": "native.future"]
        ] {
            XCTAssertThrowsError(try PluginEngine.apply(name: "views_configure", arguments: JSONSerialization.data(withJSONObject: ["views": [invalid]]),
                                                       to: &value, allowedUnitIDs: [], phase: .planning))
            XCTAssertEqual(try encoder.encode(value), original)
        }
    }
}
