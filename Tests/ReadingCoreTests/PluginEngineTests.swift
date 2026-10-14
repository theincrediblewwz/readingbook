import Foundation
import XCTest
@testable import ReadingCore

final class PluginEngineTests: XCTestCase {
    private func project() -> BookProject {
        var value = BookProject(title: "示例书", originalName: "example.txt", sourceHash: "fixture", units: [
            SourceUnit(id: "u1", order: 0, chapter: "第一章", text: "建安十三年，周瑜在赤壁与曹操交战。赤壁记为北纬29.8度、东经113.7度。"),
            SourceUnit(id: "u2", order: 1, chapter: "第二章", text: "周瑜统率水军。公式与图示需要对照原书。", warning: "图示提取待核对")
        ])
        PluginEngine.seed(&value)
        value.documents.append(DocumentRecord(id: "user-note", title: "用户自己的理解", origin: "user"))
        return value
    }

    private func evidence(_ unit: String = "u1", _ quote: String = "周瑜在赤壁与曹操交战") -> [[String: Any]] {
        [["unitID": unit, "quote": quote]]
    }

    @discardableResult
    private func command(_ name: String, _ arguments: [String: Any], project: inout BookProject, allowed: Set<String> = ["u1"]) throws -> String {
        try PluginEngine.apply(name: name, arguments: JSONSerialization.data(withJSONObject: arguments), to: &project, allowedUnitIDs: allowed)
    }

    private func snapshot(_ project: BookProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(project)
    }

    func testMissingOrFabricatedEvidenceRejectsEntireCommand() throws {
        var value = project()
        let before = try snapshot(value)
        let good: [String: Any] = ["id": "zhou-yu", "typeID": "person", "name": "周瑜", "evidence": evidence()]
        let bad: [String: Any] = ["id": "cao-cao", "typeID": "person", "name": "曹操", "evidence": []]
        XCTAssertThrowsError(try command("cards_upsert", ["entities": [good, bad]], project: &value))
        XCTAssertEqual(try snapshot(value), before, "一个批次内先前成功的操作也不得半写入。")
        for proof in [evidence("u1", "原书没有这句话"), evidence("u1", "  "), evidence("missing", "周瑜"), evidence("u2", "周瑜统率水军")] {
            XCTAssertThrowsError(try command("cards_upsert", ["entities": [["id": "zhou-yu", "typeID": "person", "name": "周瑜", "evidence": proof]]], project: &value))
            XCTAssertEqual(try snapshot(value), before)
        }
    }
    func testKnowledgeSearchDoesNotMutateOrAdvanceCoverage() throws {
        var value = project()
        try command("cards_upsert", ["entities": [["id": "zhou-yu", "typeID": "person", "name": "周瑜", "evidence": evidence()]]], project: &value)
        let before = try snapshot(value)
        let response = try command("knowledge_search", ["query": "周瑜"], project: &value, allowed: [])
        XCTAssertTrue(response.contains("zhou-yu"))
        XCTAssertEqual(try snapshot(value), before)
    }

    func testMapAndTimelineShareOneExistingEvent() throws {
        var value = project()
        let userDocuments = value.documents
        try command("cards_upsert", ["entities": [
            ["id": "chibi", "typeID": "place", "name": "赤壁", "latitude": 29.8, "longitude": 113.7, "evidence": evidence("u1", "北纬29.8度、东经113.7度")],
            ["id": "zhou-yu", "typeID": "person", "name": "周瑜", "evidence": evidence()]
        ]], project: &value)
        try command("events_upsert", ["events": [["id": "battle-chibi", "name": "赤壁之战", "dateText": "建安十三年", "startYear": 208, "endYear": 208, "placeIDs": ["chibi"], "participantIDs": ["zhou-yu"], "evidence": evidence()]]], project: &value)
        try command("map_attach", ["eventID": "battle-chibi", "evidence": evidence()], project: &value)
        try command("timeline_attach", ["eventID": "battle-chibi", "evidence": evidence()], project: &value)
        XCTAssertEqual(value.events.count, 1)
        XCTAssertEqual(value.events.first?.id, "battle-chibi")
        XCTAssertEqual(value.events.first?.placeIDs, ["chibi"])
        XCTAssertEqual(value.events.first?.participantIDs, ["zhou-yu"])
        XCTAssertEqual(Set(value.views.map(\.kind)), Set([ComponentKind.map, .timeline]))
        XCTAssertEqual(value.events.first?.evidence.count, 1)
        XCTAssertEqual(value.documents, userDocuments, "插件投影不能改写用户文档。")
        let before = try snapshot(value)
        XCTAssertThrowsError(try command("timeline_attach", ["eventID": "unknown-event", "evidence": evidence()], project: &value))
        XCTAssertEqual(try snapshot(value), before)
    }

    func testFinishRequiresAllAllowedUnitsAndPreservesReviewWarning() throws {
        var value = project()
        let allowed: Set<String> = ["u1", "u2"]
        let before = try snapshot(value)
        XCTAssertThrowsError(try command("reading_finish", ["unitIDs": ["u1"], "markdown": "战役分析", "evidence": evidence()], project: &value, allowed: allowed))
        XCTAssertThrowsError(try command("reading_finish", ["unitIDs": ["u1", "u2"], "markdown": "战役分析", "evidence": evidence()], project: &value, allowed: allowed))
        XCTAssertEqual(try snapshot(value), before)
        let arguments: [String: Any] = ["unitIDs": ["u1", "u2"], "markdown": "周瑜参与战役并统率水军；图示需回看。", "evidence": evidence() + evidence("u2", "周瑜统率水军")]
        try command("reading_finish", arguments, project: &value, allowed: allowed)
        XCTAssertEqual(value.coverage["u1"]?.status, .completed)
        XCTAssertEqual(value.coverage["u2"]?.status, .needsReview)
        XCTAssertFalse(value.isFullyProcessed)
        XCTAssertEqual(value.insights.count, 1)
        XCTAssertEqual(value.insights[0].unitIDs, ["u1", "u2"])
        XCTAssertTrue(value.insights[0].markdown.contains("〔u2〕"))
        XCTAssertTrue(value.insights[0].markdown.contains("周瑜统率水军"))
        try command("reading_finish", arguments, project: &value, allowed: allowed)
        XCTAssertEqual(value.insights.count, 1)
        XCTAssertEqual(value.coverage["u1"]?.attempts, 1)
        XCTAssertEqual(value.coverage["u2"]?.status, .needsReview)
    }

    func testEntityRetryMergesEvidenceWithoutDuplicatingOrLosingOldInformation() throws {
        var value = project()
        let first: [String: Any] = ["entities": [["id": "zhou-yu", "typeID": "person", "name": "周瑜", "summary": "参与赤壁之战", "evidence": evidence()]]]
        try command("cards_upsert", first, project: &value)
        try command("cards_upsert", first, project: &value)
        let second: [String: Any] = ["entities": [["id": "zhou-yu", "typeID": "person", "name": "公瑾", "summary": "统率水军", "evidence": evidence("u2", "周瑜统率水军")]]]
        try command("cards_upsert", second, project: &value, allowed: ["u2"])
        try command("cards_upsert", second, project: &value, allowed: ["u2"])
        XCTAssertEqual(value.entities.count, 1)
        XCTAssertEqual(value.entities[0].name, "周瑜")
        XCTAssertEqual(value.entities[0].aliases, ["公瑾"])
        XCTAssertEqual(value.entities[0].evidence.count, 2)
        XCTAssertEqual(value.entities[0].summary, "参与赤壁之战\n\n统率水军")
    }

    func testDeclarativePluginInstallsAndConflictsNeverOverwriteDefinitions() throws {
        var value = project()
        XCTAssertTrue(value.views.isEmpty, "默认类型不会强制书籍启用人物视图。")
        let manifest = PluginManifest(id: "math-notes", name: "数学笔记", description: "定义引理卡及阅读法", types: [EntityType(id: "lemma", name: "引理")], methods: [ReadingMethod(id: "proof-first", name: "证明分析", goal: "核对条件", steps: ["记录条件", "逐步检查推理"])], views: [ViewDefinition(id: "lemma-cards", title: "引理", kind: .cards, typeIDs: ["lemma"])])
        try PluginEngine.install(manifest, into: &value)
        XCTAssertEqual(value.plugins.count, 1)
        XCTAssertTrue(value.types.contains { $0.id == "lemma" })
        XCTAssertTrue(value.views.contains { $0.id == "lemma-cards" })
        let before = try snapshot(value)
        XCTAssertThrowsError(try PluginEngine.install(manifest, into: &value))
        let conflict = PluginManifest(id: "bad-package", name: "冲突包", description: "不得覆盖", types: [EntityType(id: "new-type", name: "不应半写"), EntityType(id: "person", name: "覆盖人物")])
        XCTAssertThrowsError(try PluginEngine.install(conflict, into: &value))
        XCTAssertEqual(try snapshot(value), before)
        XCTAssertFalse(value.types.contains { $0.id == "new-type" })
    }

    func testInvalidCoordinatesChronologyDanglingIDsAndUnknownToolsAreRejected() throws {
        var value = project()
        let before = try snapshot(value)
        XCTAssertThrowsError(try command("cards_upsert", ["entities": [["id": "p", "typeID": "place", "name": "地点", "latitude": 91, "longitude": 0, "evidence": evidence()]]], project: &value))
        XCTAssertThrowsError(try command("events_upsert", ["events": [["id": "e", "name": "事件", "startYear": 209, "endYear": 208, "evidence": evidence()]]], project: &value))
        XCTAssertThrowsError(try command("events_upsert", ["events": [["id": "e", "name": "事件", "startYear": 1_000_000_000_001, "evidence": evidence()]]], project: &value))
        XCTAssertThrowsError(try command("events_upsert", ["events": [["id": "e", "name": "事件", "placeIDs": ["missing"], "evidence": evidence()]]], project: &value))
        XCTAssertThrowsError(try command("relations_link", ["relations": [["id": "r", "fromID": "missing", "toID": "also-missing", "label": "相关", "evidence": evidence()]]], project: &value))
        XCTAssertThrowsError(try command("cards_upsert", ["entities": [["id": "bad:id", "typeID": "person", "name": "非法 ID", "evidence": evidence()]]], project: &value))
        XCTAssertThrowsError(try command("documents_overwrite", ["markdown": "不可写用户文档"], project: &value))
        XCTAssertEqual(try snapshot(value), before)
    }

    func testDisablingPackBlocksNewUseButPreservesAndUpdatesHistoricalKnowledge() throws {
        var value = project()
        let method = ReadingMethod(id: "pack-method", name: "包内方法", goal: "分析材料", steps: ["逐段阅读"])
        let view = ViewDefinition(id: "pack-cards", title: "包内卡片", kind: .cards, typeIDs: ["pack-type"])
        let pack = PluginManifest(id: "optional-pack", name: "可选包", description: "用于启停测试", types: [EntityType(id: "pack-type", name: "自定义要素")], methods: [method], views: [view])
        try PluginEngine.install(pack, into: &value)
        try command("cards_upsert", ["entities": [["id": "old-item", "typeID": "pack-type", "name": "既有要素", "summary": "旧内容", "evidence": evidence()]]], project: &value)
        try PluginEngine.setEnabled(false, pluginID: pack.id, in: &value)
        XCTAssertTrue(value.types.contains { $0.id == "pack-type" })
        XCTAssertTrue(value.methods.contains { $0.id == method.id })
        XCTAssertTrue(value.views.contains { $0.id == view.id })
        XCTAssertEqual(value.entities.count, 1)
        let before = try snapshot(value)
        XCTAssertThrowsError(try command("cards_upsert", ["entities": [["id": "new-item", "typeID": "pack-type", "name": "新要素", "evidence": evidence()]]], project: &value))
        XCTAssertThrowsError(try command("reading_plan", ["methodIDs": [method.id], "rationale": "选择包内方法", "focus": []], project: &value))
        XCTAssertThrowsError(try command("methods_define", ["methods": [["id": method.id, "name": method.name, "goal": method.goal, "steps": method.steps]]], project: &value))
        XCTAssertThrowsError(try command("views_configure", ["views": [["id": view.id, "title": view.title, "kind": "cards", "typeIDs": ["pack-type"]]]], project: &value))
        XCTAssertThrowsError(try command("views_configure", ["views": [["id": "other-cards", "title": "另一视图", "kind": "cards", "typeIDs": ["pack-type"]]]], project: &value))
        XCTAssertEqual(try snapshot(value), before)
        try command("cards_upsert", ["entities": [["id": "old-item", "typeID": "pack-type", "name": "既有要素", "summary": "补充内容", "evidence": evidence()]]], project: &value)
        XCTAssertTrue(value.entities[0].summary.contains("旧内容"))
        XCTAssertTrue(value.entities[0].summary.contains("补充内容"))
        try PluginEngine.setEnabled(true, pluginID: pack.id, in: &value)
        try command("cards_upsert", ["entities": [["id": "new-item", "typeID": "pack-type", "name": "新要素", "evidence": evidence()]]], project: &value)
        try command("reading_plan", ["methodIDs": [method.id], "rationale": "重新启用后选择", "focus": []], project: &value)
        XCTAssertEqual(value.entities.count, 2)
        XCTAssertTrue(value.disabledPluginIDs.isEmpty)
    }

    func testEnableToggleIsIdempotentAndDoesNotDisableCoreTools() throws {
        var value = project()
        let pack = PluginManifest(id: "small-pack", name: "可选类型", description: "只提供一个类型", types: [EntityType(id: "extra-type", name: "额外类型")])
        try PluginEngine.install(pack, into: &value)
        try PluginEngine.setEnabled(false, pluginID: pack.id, in: &value)
        let auditCount = value.audit.count
        try PluginEngine.setEnabled(false, pluginID: pack.id, in: &value)
        XCTAssertEqual(value.disabledPluginIDs, [pack.id])
        XCTAssertEqual(value.audit.count, auditCount)
        try command("cards_upsert", ["entities": [["id": "core-person", "typeID": "person", "name": "周瑜", "evidence": evidence()]]], project: &value)
        XCTAssertEqual(value.entities.first?.id, "core-person")
        let before = try snapshot(value)
        XCTAssertThrowsError(try PluginEngine.setEnabled(false, pluginID: "not-installed", in: &value))
        XCTAssertEqual(try snapshot(value), before)
    }
}
