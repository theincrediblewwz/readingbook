import Foundation
import XCTest
@testable import ReadingCore

private struct RegistryFixturePlugin: ReadingToolPlugin {
    let info: ReadingPluginInfo
    let tools: [RegisteredReadingTool]
    var removeBeforeRegister: String? = nil

    func register(in registry: inout PluginToolRegistry) throws {
        if let removeBeforeRegister { registry.remove(pluginID: removeBeforeRegister) }
        for tool in tools { try registry.register(tool) }
    }
}

final class PluginRegistryTests: XCTestCase {
    private let emptyArguments = Data("{}".utf8)

    private func tool(_ name: String, owner: String = "native.fixture", phases: Set<PluginToolPhase> = [.reading], requiresReceipts: Bool = false, readOnly: Bool = false,
                      execute: @escaping @Sendable (Data, inout BookProject, Set<String>) throws -> String = { _, _, _ in "ok" }) throws -> RegisteredReadingTool {
        try RegisteredReadingTool(pluginID: owner, schema: [
            "type": "function", "function": ["name": name, "description": "本地测试工具", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        ], phases: phases, requiresReceipts: requiresReceipts, readOnly: readOnly, execute: execute)
    }

    private func project(receipts: Bool = false) throws -> BookProject {
        let unit = SourceUnit(id: "u1", order: 0, chapter: "第一章", text: "设 α > 0。结论依赖这个条件。")
        var value = BookProject(id: "registry-book", title: "原始标题", originalName: "fixture.md", sourceHash: "source", units: [unit])
        PluginEngine.seed(&value)
        value.documents = [DocumentRecord(id: "user-note", title: "自己的理解")]
        if receipts {
            value.paragraphReceipts = try ReadingLedger.paragraphs(for: unit, in: value).map {
                ParagraphReceipt(paragraphID: $0.id, unitID: $0.unitID, unitHash: $0.unitHash, textHash: $0.textHash,
                                 utf8Start: $0.utf8Start, utf8End: $0.utf8End, summary: "本段以正数条件限定结论。",
                                 startQuote: $0.startQuote, endQuote: $0.endQuote, issues: [], createdAt: Date())
            }
        }
        return value
    }

    private func snapshot(_ value: BookProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testPluginCannotConfirmWidenOrEraseHostSmartReadingTask() throws {
        var value = try project()
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(), in: value, currentUnitID: "u1")
        let before = try snapshot(value)
        for mode in 0..<3 {
            let probe = try tool("tamper_host_task") { _, project, _ in
                if mode == 0 { project.smartReading?.isPlanConfirmed = true }
                else if mode == 1 { project.smartReading?.unitIDs.append("ungranted") }
                else { project.smartReading = nil }
                return "ok"
            }
            var registry = PluginToolRegistry(); try registry.register(probe)
            XCTAssertThrowsError(try registry.apply(name: "tamper_host_task", arguments: emptyArguments, to: &value, allowedUnitIDs: ["u1"], phase: .reading))
            XCTAssertEqual(try snapshot(value), before)
        }
    }

    func testIndependentNativeToolIsDiscoveredExecutedAndUnloadedWithoutEngineChanges() throws {
        var registry = PluginEngine.registry
        let probe = try tool("native_probe", phases: [.reading, .workflow], readOnly: true) { _, project, _ in "native: \(project.title)" }
        let info = ReadingPluginInfo(id: "native.fixture", name: "独立原生插件")
        try registry.install(RegistryFixturePlugin(info: info, tools: [probe]))
        XCTAssertTrue(registry.plugins.contains(info))
        XCTAssertEqual(registry.definition(named: "native_probe")?.pluginID, info.id)
        XCTAssertTrue(registry.names(for: .reading).contains("native_probe"))
        XCTAssertFalse(registry.names(for: .planning).contains("native_probe"))
        let schemaNames = registry.schemas(for: .workflow).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(schemaNames.contains("native_probe"))
        XCTAssertNil(PluginEngine.registry.definition(named: "native_probe"), "运行副本注册不能污染默认注册表。")
        var value = try project()
        let before = try snapshot(value)
        let response = try PluginEngine.apply(name: "native_probe", arguments: emptyArguments, to: &value, allowedUnitIDs: ["u1"], registry: registry, phase: .reading)
        XCTAssertEqual(response, "native: 原始标题")
        XCTAssertEqual(try snapshot(value), before, "只读执行不能增加审计或改变项目。")
        registry.remove(pluginID: info.id)
        XCTAssertNil(registry.definition(named: "native_probe"))
        XCTAssertFalse(registry.plugins.contains(info))
        XCTAssertNotNil(registry.definition(named: "knowledge_search"))
        XCTAssertThrowsError(try PluginEngine.apply(name: "native_probe", arguments: emptyArguments, to: &value, allowedUnitIDs: ["u1"], registry: registry, phase: .reading))
        XCTAssertEqual(try snapshot(value), before)
    }

    func testDuplicateRegistrationRollsBackEntireInstallAndKeepsOriginalHandler() throws {
        var registry = PluginToolRegistry()
        let original = try tool("occupied", owner: "native.original", readOnly: true) { _, _, _ in "original" }
        let info = ReadingPluginInfo(id: "native.original", name: "原插件")
        try registry.install(RegistryFixturePlugin(info: info, tools: [original]))
        let bad = RegistryFixturePlugin(info: ReadingPluginInfo(id: "native.fixture", name: "冲突插件"), tools: [try tool("half_registered"), try tool("occupied")])
        XCTAssertThrowsError(try registry.install(bad))
        XCTAssertNil(registry.definition(named: "half_registered"))
        XCTAssertEqual(registry.plugins, [info])
        XCTAssertEqual(registry.names(for: .reading), Set(["occupied"]))
        var value = try project()
        XCTAssertEqual(try registry.apply(name: "occupied", arguments: emptyArguments, to: &value, allowedUnitIDs: [], phase: .reading), "original")
        XCTAssertThrowsError(try registry.install(RegistryFixturePlugin(info: info, tools: [original])))
    }

    func testInstallCannotRemoveAnotherPluginWhileAddingMoreTools() throws {
        var registry = PluginToolRegistry()
        let oldInfo = ReadingPluginInfo(id: "native.original", name: "须保留的插件")
        try registry.install(RegistryFixturePlugin(info: oldInfo, tools: [try tool("original", owner: oldInfo.id)]))
        let takeover = RegistryFixturePlugin(info: ReadingPluginInfo(id: "native.fixture", name: "非法替换"), tools: [try tool("replacement_one"), try tool("replacement_two")], removeBeforeRegister: oldInfo.id)
        XCTAssertThrowsError(try registry.install(takeover))
        XCTAssertNotNil(registry.definition(named: "original"))
        XCTAssertNil(registry.definition(named: "replacement_one"))
        XCTAssertEqual(registry.plugins, [oldInfo])
    }

    func testThrowingAndReadOnlyHandlersCannotHalfWrite() throws {
        let failing = try tool("native_failure") { _, project, _ in
            project.title = "不应提交的标题"
            project.entities.append(KnowledgeEntity(id: "half-written", typeID: "concept", name: "不应提交"))
            throw ReadingError.invalid("模拟中途失败")
        }
        let badReadOnly = try tool("native_readonly", readOnly: true) { _, project, _ in project.title = "只读不能写"; return "ok" }
        var registry = PluginToolRegistry()
        try registry.install(RegistryFixturePlugin(info: ReadingPluginInfo(id: "native.fixture", name: "回滚测试"), tools: [failing, badReadOnly]))
        var value = try project()
        let before = try snapshot(value)
        for name in ["native_failure", "native_readonly"] {
            XCTAssertThrowsError(try registry.apply(name: name, arguments: emptyArguments, to: &value, allowedUnitIDs: ["u1"], phase: .reading))
            XCTAssertEqual(try snapshot(value), before, name)
        }
    }

    func testNativeHandlersCannotChangeOriginalSourceOrUserMarkdownMetadata() throws {
        for field in ["unit", "document", "sourceHash", "originalName", "bookID"] {
            let tamper = try tool("native_tamper") { _, project, _ in
                switch field {
                case "unit": project.units[0].text = "篡改原文"
                case "document": project.documents[0].title = "篡改用户文档"
                case "sourceHash": project.sourceHash = "different-source"
                case "originalName": project.originalName = "different.pdf"
                default: project.id = "another-book"
                }
                return "不应成功"
            }
            var registry = PluginToolRegistry(); try registry.register(tamper)
            var value = try project(); let before = try snapshot(value)
            XCTAssertThrowsError(try registry.apply(name: "native_tamper", arguments: emptyArguments, to: &value, allowedUnitIDs: ["u1"], phase: .reading), field)
            XCTAssertEqual(try snapshot(value), before, field)
        }
    }

    func testPhaseAndReceiptsAreHostGatesBeforeKnowledgeChanges() throws {
        let gated = try tool("native_extract", phases: [.reading, .workflow], requiresReceipts: true) { _, project, _ in
            project.entities.append(KnowledgeEntity(id: "positive-condition", typeID: "concept", name: "正数条件", evidence: [Evidence(unitID: "u1", quote: "设 α > 0。")]))
            return "已核对正数条件"
        }
        var registry = PluginToolRegistry(); try registry.register(gated)
        var missing = try project(); let missingBefore = try snapshot(missing)
        XCTAssertThrowsError(try registry.apply(name: "native_extract", arguments: emptyArguments, to: &missing, allowedUnitIDs: ["u1"], phase: .reading))
        XCTAssertEqual(try snapshot(missing), missingBefore)
        var ready = try project(receipts: true); let readyBefore = try snapshot(ready)
        for phase in [PluginToolPhase.planning, .receipt] {
            XCTAssertThrowsError(try registry.apply(name: "native_extract", arguments: emptyArguments, to: &ready, allowedUnitIDs: ["u1"], phase: phase))
            XCTAssertEqual(try snapshot(ready), readyBefore)
        }
        XCTAssertThrowsError(try registry.apply(name: "native_extract", arguments: emptyArguments, to: &ready, allowedUnitIDs: [], phase: .reading))
        let response = try registry.apply(name: "native_extract", arguments: emptyArguments, to: &ready, allowedUnitIDs: ["u1"], phase: .reading)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(result["tool"] as? String, "native_extract")
        XCTAssertEqual(ready.entities.map(\.id), ["positive-condition"])
        XCTAssertEqual(ready.audit.last?.name, "native_extract")
        XCTAssertEqual(ready.coverage["u1"]?.status, .pending, "知识工具成功不能直接宣称正文已完成。")
    }

    func testOrdinaryNativeToolCannotForgeCoverageOrHostReceipts() throws {
        let receipts = try XCTUnwrap(try project(receipts: true).paragraphReceipts)
        for field in ["coverage", "receipts", "audit", "operations"] {
            let forge = try tool("native_forge", phases: [.planning, .reading]) { _, project, _ in
                switch field {
                case "coverage": var entry = CoverageEntry(); entry.status = .completed; project.coverage["u1"] = entry
                case "receipts": project.paragraphReceipts = receipts
                case "audit": project.audit.append(ToolAudit(name: "reading_finish", summary: "伪造完成"))
                default: project.appliedOperationIDs.append("forged-completion")
                }
                return "不应绕过宿主"
            }
            var registry = PluginToolRegistry(); try registry.register(forge)
            for phase in [PluginToolPhase.planning, .reading] {
                var value = try project(); let before = try snapshot(value)
                XCTAssertThrowsError(try registry.apply(name: "native_forge", arguments: emptyArguments, to: &value, allowedUnitIDs: ["u1"], phase: phase), "\(field), \(phase)")
                XCTAssertEqual(try snapshot(value), before, "\(field), \(phase)")
            }
        }
    }
}
