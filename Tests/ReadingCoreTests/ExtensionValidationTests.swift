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
        proposed.views = [ViewDefinition(id: "layers", title: "多层伴读", kind: .knowledge, rendererID: "reading.layers")]
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

    func testModelCanConfigureCurrentRenderersButCannotReviveRetiredComponents() throws {
        var value = book()
        let views: [[String: Any]] = [
            ["id": "layers", "title": "多层伴读", "kind": "knowledge", "rendererID": "reading.layers"],
            ["id": "scheme", "title": "书本方案", "kind": "workflow", "rendererID": "book.scheme"]
        ]
        _ = try PluginEngine.apply(name: "views_configure", arguments: JSONSerialization.data(withJSONObject: ["views": views]),
                                   to: &value, allowedUnitIDs: [], phase: .planning)
        XCTAssertEqual(value.views.map(\.rendererID), ["reading.layers", "book.scheme"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(value)
        for invalid in [
            ["id": "math", "title": "数学核查", "kind": "knowledge", "rendererID": "math.verify"],
            ["id": "index", "title": "原文索引", "kind": "knowledge", "rendererID": "reading.mentions"],
            ["id": "thought", "title": "思考卡", "kind": "knowledge", "rendererID": "reading.decisions"],
            ["id": "math.verify", "title": "旧入口", "kind": "knowledge"],
            ["id": "wrong", "title": "错误类型", "kind": "cards", "rendererID": "reading.layers"],
            ["id": "unknown", "title": "不存在", "kind": "knowledge", "rendererID": "native.future"]
        ] {
            XCTAssertThrowsError(try PluginEngine.apply(name: "views_configure", arguments: JSONSerialization.data(withJSONObject: ["views": [invalid]]),
                                                       to: &value, allowedUnitIDs: [], phase: .planning))
            XCTAssertEqual(try encoder.encode(value), original)
        }
    }

    func testLegacyRetiredConfigurationAndSavedNotesSurviveReplanning() throws {
        var value = book()
        let method = ReadingMethod(id: "old-math", name: "旧数学核查", goal: "旧档", steps: ["验算"],
            executions: [ReadingStepExecution(stepIndex: 0, actionID: "math.verify")])
        value.methods.append(method)
        value.plan = ReadingPlan(methodIDs: [method.id])
        value.views = [ViewDefinition(id: "old-index", title: "旧索引", kind: .knowledge, rendererID: "reading.mentions"),
                       ViewDefinition(id: "math.verify", title: "旧核查入口", kind: .knowledge)]
        value.documents = [DocumentRecord(id: "saved-math-note", title: "我主动保存的数学笔记")]
        value.mathVerifications = [try MathVerificationEngine.verify(MathVerificationRequest(input: "2 1"))]
        _ = try BookSchemeRuntime.saveTemplate(name: "旧数学方案", in: &value)
        value = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(value))
        XCTAssertNoThrow(try BookSchemeRuntime.validateStoredState(in: value))
        XCTAssertNoThrow(try ReadingLedger.validateStoredRecords(in: value))
        XCTAssertNoThrow(try MathVerificationTools.validateStoredRecords(in: value))
        XCTAssertThrowsError(try PluginEngine.requireActivePlan(in: value))
        XCTAssertFalse(PluginEngine.activeMethods(in: value).contains { $0.id == method.id })
        var proposed = value; proposed.plan = ReadingPlan(methodIDs: ["textbook"])
        var preview = try BookSchemeRuntime.stageAIProposal(from: value, proposed: proposed)
        XCTAssertTrue(preview.bookSchemes?.pending?.selection.viewIDs.isEmpty == true)
        try BookSchemeRuntime.applyPending(in: &preview)
        XCTAssertEqual(preview.methods.first { $0.id == method.id }, method)
        XCTAssertEqual(preview.views, value.views, "Retired configuration is kept as archival data, not activated or deleted.")
        XCTAssertEqual(preview.documents, value.documents)
        XCTAssertEqual(preview.mathVerifications, value.mathVerifications)
        XCTAssertEqual(preview.plan?.methodIDs, ["textbook"])
        XCTAssertNoThrow(try PluginEngine.requireActivePlan(in: preview))
    }
}
