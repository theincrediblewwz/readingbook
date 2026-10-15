import Foundation
import XCTest
@testable import ReadingCore

final class ReadingExperienceToolTests: XCTestCase {
    private func project(receipts: Bool = true) throws -> BookProject {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "第一章", text: "曹操屯兵。阿瞒为曹操之别称。"),
                     SourceUnit(id: "u2", order: 1, chapter: "第二章", text: "曹操引军南下。")]
        var value = BookProject(title: "历史读本", originalName: "history.md", sourceHash: "source", units: units)
        PluginEngine.seed(&value)
        value.entities = [KnowledgeEntity(id: "cao-cao", typeID: "person", name: "曹操", aliases: ["阿瞒"], evidence: [Evidence(unitID: "u1", quote: "阿瞒为曹操之别称。")])]
        if receipts {
            value.paragraphReceipts = try units.flatMap { unit in
                try ReadingLedger.paragraphs(for: unit, in: value).map {
                    ParagraphReceipt(paragraphID: $0.id, unitID: $0.unitID, unitHash: $0.unitHash, textHash: $0.textHash,
                                     utf8Start: $0.utf8Start, utf8End: $0.utf8End, summary: "逐段核对曹操的行动与别称。", startQuote: $0.startQuote, endQuote: $0.endQuote, issues: [], createdAt: Date())
                }
            }
        }
        return value
    }
    private var payload: [String: Any] {
        ["anchors": [["id": "alias", "unitID": "u1", "quote": "阿瞒"]],
         "mentions": [["targetID": "cao-cao", "anchorID": "alias"]],
         "layers": [["id": "gloss-amang", "kind": "glossary", "title": "阿瞒", "markdown": "原文说明阿瞒是曹操的别称。", "sourceAnchorIDs": ["alias"], "sourceLabel": "不可伪装成原书注释"]]]
    }
    private func apply(_ payload: [String: Any], to value: inout BookProject, allowed: Set<String> = ["u1"], phase: PluginToolPhase = .reading) throws {
        _ = try PluginEngine.apply(name: "reading_enrich", arguments: JSONSerialization.data(withJSONObject: payload), to: &value, allowedUnitIDs: allowed, phase: phase)
    }
    private func snapshot(_ value: BookProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testNativeEnrichmentIsDiscoveredAndReceiptsAndPhaseAreHostGates() throws {
        XCTAssertEqual(PluginEngine.registry.definition(named: "reading_enrich")?.pluginID, "builtin.reading-experience")
        XCTAssertTrue(PluginEngine.registry.names(for: .workflow).contains("reading_enrich"))
        XCTAssertFalse(PluginEngine.registry.names(for: .planning).contains("reading_enrich"))
        var missing = try project(receipts: false)
        let before = try snapshot(missing)
        XCTAssertThrowsError(try apply(payload, to: &missing))
        XCTAssertEqual(try snapshot(missing), before)
        var ready = try project()
        XCTAssertThrowsError(try apply(payload, to: &ready, phase: .planning))
        XCTAssertThrowsError(try apply(payload, to: &ready, allowed: []))
        XCTAssertNil(ready.readingExperience)
    }

    func testAliasesBecomeStableAnchorsAndReplayDoesNotDuplicateOrRewriteSource() throws {
        var value = try project()
        let originalUnits = value.units
        try apply(payload, to: &value)
        let first = try XCTUnwrap(value.readingExperience)
        XCTAssertEqual(first.anchors.count, 1)
        XCTAssertNotEqual(first.anchors.first?.id, "alias")
        XCTAssertEqual(first.mentions, [SourceMention(targetID: "cao-cao", anchorID: try XCTUnwrap(first.anchors.first?.id))])
        XCTAssertEqual(first.layers.first?.sourceLabel, "AI 生成 · 待核对")
        XCTAssertEqual(value.entities.map(\.id), ["cao-cao"], "称谓提及须复用同一实体。")
        XCTAssertTrue(value.coverage.values.allSatisfy { $0.status == .pending })
        XCTAssertEqual(value.units, originalUnits)
        XCTAssertTrue(value.insights.isEmpty)
        try apply(payload, to: &value)
        XCTAssertEqual(value.readingExperience, first)
        XCTAssertEqual(value.audit.filter { $0.name == "reading_enrich" }.count, 2)
        let restored = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.readingExperience, first)
        var conflict = payload
        var layers = try XCTUnwrap(conflict["layers"] as? [[String: Any]])
        layers[0]["markdown"] = "另一个内容，不能覆盖旧释义。"
        conflict["layers"] = layers
        let before = try snapshot(value)
        XCTAssertThrowsError(try apply(conflict, to: &value))
        XCTAssertEqual(try snapshot(value), before)
    }

    func testInvalidOrUnapprovedAnchorRollsBackWholeBatch() throws {
        for anchors in [
            [["id": "alias", "unitID": "u1", "quote": "不存在的词语"]],
            [["id": "alias", "unitID": "u2", "quote": "曹操"]],
            [["id": "alias", "unitID": "u1", "quote": "曹操"]]
        ] {
            var value = try project()
            var request = payload; request["anchors"] = anchors
            let before = try snapshot(value)
            XCTAssertThrowsError(try apply(request, to: &value))
            XCTAssertEqual(try snapshot(value), before)
        }
        var value = try project()
        var unknown = payload; unknown["runShell"] = "forbidden"
        XCTAssertThrowsError(try apply(unknown, to: &value))
        XCTAssertNil(value.readingExperience)
    }

    func testAlignmentRequiresRealSecondSourceInsteadOfURLOnly() throws {
        var value = try project()
        var request = payload
        request["alignments"] = [["id": "compare-one", "sourceAnchorIDs": ["alias"], "title": "比较", "markdown": "仅有一个锚点不能证明两处资料。", "status": "needs-review", "provenance": ["label": "出处标注，尚未联网核验", "url": "https://example.com/source"]]]
        XCTAssertThrowsError(try apply(request, to: &value))
        XCTAssertNil(value.readingExperience)
        let other = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "u2", quote: "曹操引军南下。", in: value)
        value.readingExperience = ReadingExperienceState(anchors: [other])
        request["alignments"] = [["id": "compare-one", "sourceAnchorIDs": ["alias", other.id], "title": "称谓与行动", "markdown": "同一对象在两个原文单元的称谓和行动。", "status": "needs-review", "provenance": ["label": "本书两处原文"]]]
        try apply(request, to: &value)
        XCTAssertEqual(value.readingExperience?.alignments.first?.status, "needs-review")
        XCTAssertEqual(value.readingExperience?.alignments.first?.sourceAnchorIDs.count, 2)
        XCTAssertNoThrow(try ReadingExperienceRuntime.validate(try XCTUnwrap(value.readingExperience), in: value))
    }

    func testEnrichmentActionNeedsActualProductOrExplicitNoChangeReason() async throws {
        var value = try project()
        value.methods = [ReadingMethod(id: "enrich", name: "多层", goal: "建立可点击理解", steps: ["创建释义"], executions: [ReadingStepExecution(stepIndex: 0, actionID: "reading.enrich")])]
        value.plan = ReadingPlan(methodIDs: ["enrich"])
        let task = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        let request = try JSONSerialization.data(withJSONObject: payload)
        let services = ReadingWorkflowServices { task, original in
            var candidate = original
            _ = try PluginEngine.apply(name: "reading_enrich", arguments: request, to: &candidate, allowedUnitIDs: ["u1"], phase: .workflow)
            ReadingWorkflowRuntime.recordTool("reading_enrich", in: &candidate, previous: original)
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID, output: ReadingWorkflowOutput(result: "已用真实工具关联阿瞒与曹操，并保存原文释义。", paragraphIDs: task.input.paragraphIDs, evidence: [Evidence(unitID: "u1", quote: "阿瞒为曹操之别称。")]), to: &candidate, allowedUnitIDs: ["u1"])
            return candidate
        }
        value = try await ReadingWorkflowRuntime.perform(task, in: value, services: services)
        XCTAssertEqual(value.workflowRuns?.first?.status, .completed)
        XCTAssertEqual(value.workflowRuns?.first?.knowledgeWriteTools, ["reading_enrich"])
        XCTAssertEqual(value.readingExperience?.layers.count, 1)
        XCTAssertNil(try ReadingWorkflowRuntime.nextTask(for: value.units[0], in: value))
        XCTAssertNoThrow(try ReadingWorkflowRuntime.validateStoredRecords(in: value))
    }

    func testIndependentPluginCannotBypassReadingLayerWriteBoundary() throws {
        let schema: [String: Any] = ["type": "function", "function": ["name": "native_layer", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]]
        let base = try project()
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: base.sourceHash, unitID: "u1", quote: "阿瞒", in: base)
        let state = ReadingExperienceState(anchors: [anchor], layers: [ReadingLayer(id: "new-layer", kind: "explanation", title: "称谓", markdown: "阿瞒为曹操之别称。", sourceAnchorIDs: [anchor.id])])
        for (phase, requiresReceipts) in [(PluginToolPhase.reading, false), (.planning, true)] {
            var registry = PluginToolRegistry()
            try registry.register(RegisteredReadingTool(pluginID: "native.fixture", schema: schema, phases: [phase], requiresReceipts: requiresReceipts) { _, candidate, _ in
                candidate.readingExperience = state
                return "不能绕过宿主边界"
            })
            var value = base
            let before = try snapshot(value)
            XCTAssertThrowsError(try registry.apply(name: "native_layer", arguments: Data("{}".utf8), to: &value, allowedUnitIDs: ["u1"], phase: phase))
            XCTAssertEqual(try snapshot(value), before)
        }
        var value = base
        try apply(payload, to: &value)
        var replacementRegistry = PluginToolRegistry()
        try replacementRegistry.register(RegisteredReadingTool(pluginID: "native.fixture", schema: schema, phases: [.reading], requiresReceipts: true) { _, candidate, _ in
            candidate.readingExperience = nil
            return "不能删除已保存层"
        })
        let before = try snapshot(value)
        XCTAssertThrowsError(try replacementRegistry.apply(name: "native_layer", arguments: Data("{}".utf8), to: &value, allowedUnitIDs: ["u1"], phase: .reading))
        XCTAssertEqual(try snapshot(value), before)
    }

    func testAIViewDeclarationSelectsRealRendererAndCannotInventCapability() throws {
        var value = try project()
        func configure(_ views: [[String: Any]]) throws {
            _ = try PluginEngine.apply(name: "views_configure", arguments: JSONSerialization.data(withJSONObject: ["views": views]), to: &value, allowedUnitIDs: [], phase: .planning)
        }
        try configure([["id": "explanations", "title": "语境释义", "kind": "knowledge", "rendererID": "reading.layers", "configuration": ["kind": "explanation"]]])
        XCTAssertEqual(value.views.first?.rendererID, "reading.layers")
        XCTAssertEqual(value.views.first?.scope, "current")
        XCTAssertEqual(value.views.first?.configuration?["kind"], "explanation")
        let before = try snapshot(value)
        XCTAssertThrowsError(try configure([["id": "fake", "title": "未实现", "kind": "knowledge", "rendererID": "imaginary.simulator"]]))
        XCTAssertEqual(try snapshot(value), before)
        XCTAssertThrowsError(try configure([["id": "explanations", "title": "改成另一渲染器", "kind": "knowledge", "rendererID": "reading.decisions"]]))
        XCTAssertEqual(try snapshot(value), before)
    }
}
