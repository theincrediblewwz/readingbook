import Foundation
import XCTest
@testable import ReadingCore

final class ReadingExecutionTests: XCTestCase {
    private func project(_ configuration: ReadingExecutionConfiguration = .init(granularity: .page)) throws -> BookProject {
        var value = BookProject(title: "阅读配置", originalName: "book.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            SourceUnit(id: "u1", order: 0, chapter: "第一章", page: 1, text: "甲先来到城中。"),
            SourceUnit(id: "u2", order: 1, chapter: "第一章", page: 1, text: "乙在这里相迎。"),
            SourceUnit(id: "u3", order: 2, chapter: "第一章", page: 2, text: "二人继续向前。"),
            SourceUnit(id: "u4", order: 3, chapter: "第二章", page: 3, text: "新的一章开始。")
        ])
        PluginEngine.seed(&value)
        value.plan = ReadingPlan(methodIDs: ["genre.history"])
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: configuration), in: value, currentUnitID: "u1")
        return value
    }
    private func grant(_ chunk: ReadingAnalysisChunk, in project: BookProject) throws -> ReadingAnalysisAuthority.Grant {
        let session = try XCTUnwrap(project.smartReading)
        return ReadingAnalysisAuthority.Grant(bookID: project.id, sessionID: session.id, sourceHash: project.sourceHash,
            chunk: chunk, unitHashes: session.unitHashes.filter { chunk.unitIDs.contains($0.key) })
    }
    private func completion(_ chunk: ReadingAnalysisChunk, in project: BookProject, noChangesReasons: [String: String]? = nil) throws -> Data {
        let configuration = project.smartReading?.selection.execution
        var defaults: [String: String] = [:]
        for step in configuration?.enabledSteps ?? [] where chunk.stepIDs.contains(step.id) && ["facts.extract", "reading.enrich"].contains(step.actionID) { defaults["step:" + step.id] = "该测试原文没有本步需要补充的内容。" }
        for kind in configuration?.componentKinds ?? [] { defaults["component:" + kind.rawValue] = "该测试原文没有可靠的适用数据。" }
        return try JSONSerialization.data(withJSONObject: ["unitIDs": chunk.unitIDs, "completedStepIDs": chunk.stepIDs,
            "noChangesReasons": noChangesReasons ?? defaults,
            "markdown": "这一部分写两人相遇，故事继续向前。", "evidence": chunk.unitIDs.map { id in
                ["unitID": id, "quote": project.units.first(where: { $0.id == id })!.text]
            }])
    }

    func testOlderSelectionsRetainStrictReceiptSemantics() throws {
        let data = Data(#"{"scope":"wholeBook","preferredMethodIDs":[]}"#.utf8)
        let old = try JSONDecoder().decode(SmartReadingSelection.self, from: data)
        XCTAssertNil(old.execution)
        var value = try project()
        value.smartReading = try SmartReadingRuntime.freeze(old, in: value, currentUnitID: "u1")
        XCTAssertTrue(try SmartReadingRuntime.analysisChunks(in: value).isEmpty)
        XCTAssertThrowsError(try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: ["u1"], in: value))
    }

    func testGranularityPreservesOriginalUnitsAndStepFrequencies() throws {
        var configuration = ReadingExecutionConfiguration(granularity: .page, steps: [
            ReadingExecutionStep(id: "part", title: "讲清内容"),
            ReadingExecutionStep(id: "chapter", title: "章末回顾", frequency: .chapter),
            ReadingExecutionStep(id: "book", title: "本轮回顾", frequency: .book)
        ])
        var value = try project(configuration)
        let chunks = try SmartReadingRuntime.analysisChunks(in: value)
        XCTAssertEqual(chunks.map(\.unitIDs), [["u1", "u2"], ["u3"], ["u4"]])
        XCTAssertEqual(chunks.map(\.stepIDs), [["part"], ["part", "chapter"], ["part", "chapter", "book"]])
        configuration.granularity = .chapter
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: configuration), in: value, currentUnitID: "u1")
        XCTAssertEqual(try SmartReadingRuntime.analysisChunks(in: value).map(\.unitIDs), [["u1", "u2", "u3"], ["u4"]])
        XCTAssertEqual(value.units.map(\.id), ["u1", "u2", "u3", "u4"])
    }

    func testLargeChaptersAreBoundedWithoutRewritingSourceAnchors() throws {
        var value = try project(.init(granularity: .chapter))
        value.units = (0..<29).map { SourceUnit(id: "p\($0)", order: $0, chapter: "长章", page: $0 + 1, text: String(repeating: "文", count: 2200)) }
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: .init(granularity: .chapter)), in: value, currentUnitID: "p0")
        let chunks = try SmartReadingRuntime.analysisChunks(in: value)
        XCTAssertTrue(chunks.allSatisfy { $0.unitIDs.count <= 12 })
        XCTAssertTrue(chunks.allSatisfy { chunk in value.units.filter { chunk.unitIDs.contains($0.id) }.reduce(0, { $0 + $1.text.count }) <= 20_000 })
        XCTAssertEqual(chunks.flatMap(\.unitIDs), value.units.map(\.id))
    }

    func testStandardCompletionAddsOnlyAnalysisAndKeepsReceiptCoverageSeparate() throws {
        var value = try project()
        let original = value
        let chunk = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value))
        let authorization = try grant(chunk, in: value)
        let arguments = try completion(chunk, in: value)
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            _ = try PluginEngine.registry.apply(name: "reading_analysis", arguments: arguments, to: &value, allowedUnitIDs: Set(chunk.unitIDs), phase: .reading)
        }
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(chunk, in: value))
        XCTAssertEqual(value.smartReading?.analysisCheckpoints?.count, 1)
        XCTAssertEqual(value.insights.count, original.insights.count + 1)
        XCTAssertEqual(value.paragraphReceipts, original.paragraphReceipts)
        XCTAssertEqual(value.units, original.units)
        XCTAssertEqual(value.documents, original.documents)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(value.coverage), try encoder.encode(original.coverage))
        XCTAssertNoThrow(try SmartReadingRuntime.validateStoredState(in: value))
        XCTAssertEqual(try SmartReadingRuntime.nextAnalysisChunk(in: value)?.unitIDs, ["u3"])
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            _ = try PluginEngine.registry.apply(name: "reading_analysis", arguments: arguments, to: &value, allowedUnitIDs: Set(chunk.unitIDs), phase: .reading)
        }
        XCTAssertEqual(value.smartReading?.analysisCheckpoints?.count, 1, "重复回调不应复制产物。")
        XCTAssertEqual(value.insights.count, original.insights.count + 1)
    }

    func testAuthorityCannotBeGrantedByStoredModeOrWidenedToAnotherChunk() throws {
        let value = try project()
        let chunk = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value))
        XCTAssertThrowsError(try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: Set(chunk.unitIDs), in: value))
        try ReadingAnalysisAuthority.$current.withValue(grant(chunk, in: value)) {
            XCTAssertNoThrow(try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: Set(chunk.unitIDs), in: value))
            XCTAssertThrowsError(try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: ["u1", "u2", "u3"], in: value))
            var changed = value; changed.units[0].text += "被改写。"
            XCTAssertThrowsError(try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: Set(chunk.unitIDs), in: changed))
            var foreign = value; foreign.smartReading?.id = "other-session"
            XCTAssertThrowsError(try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: Set(chunk.unitIDs), in: foreign))
        }
    }

    func testCloseReadingStillRequiresRealReceipts() throws {
        let value = try project(.init(precision: .close, granularity: .page))
        let chunk = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value))
        try ReadingAnalysisAuthority.$current.withValue(grant(chunk, in: value)) {
            XCTAssertThrowsError(try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: Set(chunk.unitIDs), in: value))
        }
    }

    func testTemporalKnowledgeUsesExactStandardGrantAndCannotUseStoredModeAlone() throws {
        var value = try project()
        let quote = value.units[0].text
        let evidence = [Evidence(unitID: "u1", quote: quote)]
        value.entities = [KnowledgeEntity(id: "person-a", typeID: "person", name: "甲", evidence: evidence),
                          KnowledgeEntity(id: "city", typeID: "place", name: "城中", evidence: evidence)]
        let chunk = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value))
        let changes = ControlledKnowledgeChanges(anchors: [ProposedSourceAnchor(clientID: "a", unitID: "u1", quote: quote)],
            presences: [EntityPresence(id: "presence", entityID: "person-a", placeID: "city", action: "来到城中", sourceAnchorIDs: ["a"], assertion: .explicit)])
        let arguments = try JSONEncoder().encode(changes)
        var unauthorized = value
        XCTAssertThrowsError(try PluginEngine.apply(name: "knowledge_temporal", arguments: arguments, to: &unauthorized,
            allowedUnitIDs: Set(chunk.unitIDs), phase: .reading))
        XCTAssertNil(unauthorized.temporalKnowledge)
        let authorization = try grant(chunk, in: value)
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            _ = try PluginEngine.apply(name: "knowledge_temporal", arguments: arguments, to: &value,
                allowedUnitIDs: Set(chunk.unitIDs), phase: .reading)
        }
        XCTAssertEqual(value.temporalKnowledge?.presences.count, 1)
        XCTAssertTrue((value.paragraphReceipts ?? []).isEmpty)
        XCTAssertTrue((value.smartReading?.analysisCheckpoints ?? []).isEmpty, "组件产物不提前冒充本部分分析完成。")
    }

    func testNewScopeKeepsOldAnalysisButChangedConfigurationNeedsNewWork() throws {
        var value = try project()
        let chunk = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value))
        let authorization = try grant(chunk, in: value)
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            _ = try SmartReadingRuntime.completeAnalysis(arguments: completion(chunk, in: value), in: &value, allowedUnitIDs: Set(chunk.unitIDs))
        }
        let saved = value.smartReading?.analysisCheckpoints
        var configuration = ReadingExecutionConfiguration(granularity: .chapter)
        configuration.steps.removeAll { $0.id == "review" }
        var next = try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .currentChapter, execution: configuration), in: value, currentUnitID: "u1")
        next.analysisCheckpoints = saved; value.smartReading = next
        XCTAssertEqual(value.smartReading?.analysisCheckpoints, saved)
        XCTAssertEqual(value.insights.count, 1)
        XCTAssertNotNil(try SmartReadingRuntime.nextAnalysisChunk(in: value))
        XCTAssertNoThrow(try SmartReadingRuntime.validateStoredState(in: value))
    }

    func testConfigurationBoundsAndRequestedComponentsDoNotCreateFacts() throws {
        var configuration = ReadingExecutionConfiguration(componentKinds: [.map, .timeline, .mindmap])
        var value = try project(configuration)
        let source = value.units, entities = value.entities, events = value.events
        configuration.configureRequestedViews(in: &value)
        configuration.configureRequestedViews(in: &value)
        for kind in configuration.componentKinds { XCTAssertEqual(value.views.filter { $0.kind == kind }.count, 1) }
        XCTAssertEqual(value.units, source); XCTAssertEqual(value.entities, entities); XCTAssertEqual(value.events, events)
        configuration.maximumConcurrentRequests = 6; XCTAssertThrowsError(try configuration.validate())
        configuration.maximumConcurrentRequests = 1
        configuration.steps = configuration.steps.map { var step = $0; step.enabled = false; return step }
        XCTAssertNoThrow(try configuration.validate(), "附加步骤可全部关闭；基础阅读始终存在。")
        configuration.steps = []
        XCTAssertNoThrow(try configuration.validate())
    }

    private func reviewProject() throws -> (BookProject, [ReadingAnalysisChunk]) {
        let configuration = ReadingExecutionConfiguration(granularity: .page, steps: [
            ReadingExecutionStep(id: "part", title: "阅读内容"),
            ReadingExecutionStep(id: "chapter", title: "章末回顾", frequency: .chapter),
            ReadingExecutionStep(id: "book", title: "本轮回顾", frequency: .book)
        ])
        var value = try project(configuration)
        let chunks = try SmartReadingRuntime.analysisChunks(in: value)
        let hashes = value.smartReading!.unitHashes, units = value.units
        value.smartReading?.analysisCheckpoints = chunks.map { chunk in
            ReadingAnalysisCheckpoint(id: chunk.id, unitIDs: chunk.unitIDs,
                unitHashes: hashes.filter { chunk.unitIDs.contains($0.key) },
                configurationHash: chunk.configurationHash, completedStepIDs: chunk.stepIDs,
                markdown: "这部分已保存的分析：" + chunk.title,
                evidence: chunk.unitIDs.map { id in Evidence(unitID: id, quote: units.first { $0.id == id }!.text) }, updatedAt: Date())
        }
        return (value, chunks)
    }
    private func reviewCall(_ name: String, _ arguments: [String: Any], chunk: ReadingAnalysisChunk, project: inout BookProject) throws -> Data {
        let authorization = try grant(chunk, in: project)
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let output = try ReadingAnalysisAuthority.$current.withValue(authorization) {
            try PluginEngine.registry.apply(name: name, arguments: data, to: &project, allowedUnitIDs: Set(chunk.unitIDs), phase: .reading)
        }
        return Data(output.utf8)
    }

    func testReviewRetrievalIsReadOnlyAndRejectsFutureOrOtherChapter() throws {
        var (value, chunks) = try reviewProject()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(value)
        let result = try reviewCall("analysis_outline", ["scope": "chapter", "limit": 80], chunk: chunks[1], project: &value)
        let outline = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(outline["total"] as? Int, 1)
        let rows = try XCTUnwrap(outline["items"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["id"] as? String, chunks[0].id)
        XCTAssertNil(rows.first?["markdown"], "目录不能冒充读取分析正文。")
        let text = try reviewCall("analysis_read", ["scope": "chapter", "checkpointIDs": [chunks[0].id]], chunk: chunks[1], project: &value)
        XCTAssertTrue(String(decoding: text, as: UTF8.self).contains("derived_saved_analysis"))
        XCTAssertThrowsError(try reviewCall("analysis_read", ["scope": "chapter", "checkpointIDs": [chunks[2].id]], chunk: chunks[1], project: &value), "未来产物不能越阅读位置泄漏。")
        XCTAssertThrowsError(try reviewCall("analysis_read", ["scope": "chapter", "checkpointIDs": [chunks[0].id]], chunk: chunks[2], project: &value), "章末只能读本章前序。")
        XCTAssertThrowsError(try reviewCall("analysis_outline", ["scope": "book"], chunk: chunks[1], project: &value), "未启用本轮结束步骤不能扩大为全书回顾。")
        XCTAssertEqual(try encoder.encode(value), before, "读取不改变产物、审计、笔记或覆盖。")
    }

    func testReviewRetrievalRejectsOldScopeAndChangedPriorSource() throws {
        var (value, chunks) = try reviewProject()
        let sourceCheckpoint = chunks[0].id
        value.units[0].text += "发生变化。"
        XCTAssertThrowsError(try reviewCall("analysis_read", ["scope": "book", "checkpointIDs": [sourceCheckpoint]], chunk: chunks[2], project: &value))
        (value, chunks) = try reviewProject()
        let old = value.smartReading?.analysisCheckpoints
        let configuration = try XCTUnwrap(value.smartReading?.selection.execution)
        var selected = try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .pageRange, pageStart: 2, pageEnd: 3, execution: configuration), in: value, currentUnitID: "u3")
        selected.analysisCheckpoints = old; value.smartReading = selected
        let final = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).last)
        XCTAssertThrowsError(try reviewCall("analysis_read", ["scope": "book", "checkpointIDs": [sourceCheckpoint]], chunk: final, project: &value), "原文虽在前面，也不能读取新范围之外的旧成果。")
        var denied = value
        XCTAssertThrowsError(try PluginEngine.registry.apply(name: "analysis_outline", arguments: Data(#"{"scope":"book"}"#.utf8), to: &denied, allowedUnitIDs: Set(final.unitIDs), phase: .reading))
    }

    func testReviewRetrievalCapsPageCountAndTotalReadBytes() throws {
        var (value, chunks) = try reviewProject()
        value.smartReading?.analysisCheckpoints?[0].markdown = String(repeating: "已有分析内容。", count: 2000)
        let output = try reviewCall("analysis_read", ["scope": "book", "checkpointIDs": [chunks[0].id]], chunk: chunks[2], project: &value)
        XCTAssertLessThanOrEqual(output.count, 12 * 1024)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let items = try XCTUnwrap(decoded["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["truncated"] as? Bool, true)
        XCTAssertThrowsError(try reviewCall("analysis_outline", ["scope": "book", "limit": 81], chunk: chunks[2], project: &value))
        let page = try reviewCall("analysis_outline", ["scope": "book", "offset": 1, "limit": 1], chunk: chunks[2], project: &value)
        let pageValue = try XCTUnwrap(JSONSerialization.jsonObject(with: page) as? [String: Any])
        XCTAssertEqual((pageValue["items"] as? [[String: Any]])?.count, 1)
        XCTAssertThrowsError(try reviewCall("analysis_read", ["scope": "book", "checkpointIDs": Array(repeating: chunks[0].id, count: 4)], chunk: chunks[2], project: &value))
    }

    func testSchedulingAndRationaleChangesReuseAnalysisButWorkChangesInvalidateIt() throws {
        var value = try project(.init(granularity: .page, maximumConcurrentRequests: 1))
        value.plan?.recommendedParallelism = 1; value.plan?.rationale = "先选一个合适的方法。"
        let first = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value))
        let authorization = try grant(first, in: value)
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            _ = try SmartReadingRuntime.completeAnalysis(arguments: completion(first, in: value), in: &value, allowedUnitIDs: Set(first.unitIDs))
        }
        value.smartReading?.selection.execution?.maximumConcurrentRequests = 5
        value.plan?.recommendedParallelism = 4; value.plan?.rationale = "相同方法换一种说明。"
        let rescheduled = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).first)
        XCTAssertEqual(rescheduled, first)
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(rescheduled, in: value))
        XCTAssertEqual(try SmartReadingRuntime.nextAnalysisChunk(in: value)?.unitIDs, ["u3"])
        var changed = value
        changed.smartReading?.selection.execution?.steps[0].title += "并比较前后的因果变化"
        let newWork = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: changed).first)
        XCTAssertNotEqual(newWork.id, first.id)
        XCTAssertFalse(SmartReadingRuntime.isChunkComplete(newWork, in: changed))
        changed = value; changed.plan?.focus = ["新的关注问题"]
        XCTAssertNotEqual(try SmartReadingRuntime.analysisChunks(in: changed).first?.id, first.id)
        XCTAssertEqual(value.smartReading?.analysisCheckpoints?.count, 1, "不改写旧检查点或旧分析。")
    }

    func testLegacyAnalysisMatchesOnlyProvableSameWorkAcrossSchedulingCaps() throws {
        var value = try project(.init(granularity: .page, steps: [ReadingExecutionStep(id: "base", title: "阅读这一部分")], maximumConcurrentRequests: 1))
        // A prior checkpoint cannot prove it used newly supplied method goals.
        for index in value.methods.indices where value.plan?.methodIDs.contains(value.methods[index].id) == true { value.methods[index].goal = "" }
        value.plan?.recommendedParallelism = 2; value.plan?.rationale = "旧版方案说明。"
        let first = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).first)
        let session = try XCTUnwrap(value.smartReading), configuration = try XCTUnwrap(session.selection.execution)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacy = try BookImporter.sha256(Data(try configuration.fingerprint().utf8) + encoder.encode(value.plan))
        let sourceKey = first.unitIDs.map { $0 + ":" + session.unitHashes[$0]! }.joined(separator: "|")
        let legacyID = "chunk-" + String(try BookImporter.sha256(Data((value.sourceHash + "|" + legacy + "|" + sourceKey).utf8)).prefix(48))
        let checkpoint = ReadingAnalysisCheckpoint(id: legacyID, unitIDs: first.unitIDs,
            unitHashes: session.unitHashes.filter { first.unitIDs.contains($0.key) }, configurationHash: legacy,
            completedStepIDs: first.stepIDs, markdown: "旧版已经保存的内容。",
            evidence: first.unitIDs.map { id in Evidence(unitID: id, quote: value.units.first { $0.id == id }!.text) }, updatedAt: Date())
        value.smartReading?.analysisCheckpoints = [checkpoint]
        value.smartReading?.selection.execution?.maximumConcurrentRequests = 5; value.plan?.recommendedParallelism = 4
        let compatible = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).first)
        XCTAssertEqual(compatible.id, legacyID); XCTAssertEqual(compatible.configurationHash, legacy)
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(compatible, in: value))
        var changed = value; changed.smartReading?.selection.execution?.steps[0].title = "不同的实际工作"
        XCTAssertNotEqual(try SmartReadingRuntime.analysisChunks(in: changed).first?.id, legacyID)
        changed = value; changed.plan?.focus = ["新增阅读目标"]
        XCTAssertNotEqual(try SmartReadingRuntime.analysisChunks(in: changed).first?.id, legacyID)
        changed = value; changed.plan?.rationale = "无法证明是哪一份历史说明。"
        XCTAssertNotEqual(try SmartReadingRuntime.analysisChunks(in: changed).first?.id, legacyID, "不猜测未保存的旧定义来强行复用。")
        XCTAssertEqual(value.smartReading?.analysisCheckpoints, [checkpoint])
    }

    func testCurrentPageAndChapterSelectionsNoticeCursorLeavingFrozenManifest() throws {
        var value = try project()
        let page = SmartReadingSelection(scope: .currentPage, execution: .init())
        value.smartReading = try SmartReadingRuntime.freeze(page, in: value, currentUnitID: "u1")
        XCTAssertTrue(SmartReadingRuntime.selectionMatchesFrozenContext(page, in: value, currentUnitID: "u2"), "同一页拆成多个源单元时仍是原范围。")
        XCTAssertFalse(SmartReadingRuntime.selectionMatchesFrozenContext(page, in: value, currentUnitID: "u3"), "翻到新页再选当前页应重新冻结，而非继续旧页。")
        let chapter = SmartReadingSelection(scope: .currentChapter, execution: .init())
        value.smartReading = try SmartReadingRuntime.freeze(chapter, in: value, currentUnitID: "u1")
        XCTAssertTrue(SmartReadingRuntime.selectionMatchesFrozenContext(chapter, in: value, currentUnitID: "u3"))
        XCTAssertFalse(SmartReadingRuntime.selectionMatchesFrozenContext(chapter, in: value, currentUnitID: "u4"))
        XCTAssertEqual(value.smartReading?.unitIDs, ["u1", "u2", "u3"], "移动光标不能偷偷改变正在执行的旧范围。")
        let whole = SmartReadingSelection(execution: .init())
        value.smartReading = try SmartReadingRuntime.freeze(whole, in: value, currentUnitID: "u1")
        XCTAssertTrue(SmartReadingRuntime.selectionMatchesFrozenContext(whole, in: value, currentUnitID: "u4"))
    }

    func testConfiguredProductsCannotBeClaimedByCompletionIDsAlone() throws {
        var value = try project(.init(granularity: .page, componentKinds: [.map, .mindmap]))
        let chunk = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value)), authorization = try grant(chunk, in: value)
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            XCTAssertThrowsError(try SmartReadingRuntime.completeAnalysis(arguments: completion(chunk, in: value, noChangesReasons: [:]), in: &value, allowedUnitIDs: Set(chunk.unitIDs)))
        }
        XCTAssertTrue((value.smartReading?.analysisCheckpoints ?? []).isEmpty)
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            _ = try SmartReadingRuntime.completeAnalysis(arguments: completion(chunk, in: value), in: &value, allowedUnitIDs: Set(chunk.unitIDs))
        }
        let checkpoint = try XCTUnwrap(value.smartReading?.analysisCheckpoints?.first)
        XCTAssertNotNil(checkpoint.noChangesReasons?["component:map"])
        let notes = SmartReadingRuntime.analysisCheckpointNotes(checkpoint, in: value)
        XCTAssertTrue(notes.contains { $0.hasPrefix("地图：") })
        XCTAssertFalse(notes.contains { $0.contains("step:") || $0.contains("component:") })
        XCTAssertTrue(value.entities.isEmpty); XCTAssertTrue(value.nodes.isEmpty)
    }

    func testRealReusedProductsAndHostCitationCheckNeedNoFabricatedOutput() throws {
        let configuration = ReadingExecutionConfiguration(granularity: .page, componentKinds: [.cards], steps: [
            ReadingExecutionStep(id: "facts", title: "整理要素", actionID: "facts.extract"),
            ReadingExecutionStep(id: "citations", title: "核对引用", actionID: "citations.verify")
        ])
        var value = try project(configuration)
        value.entities = [KnowledgeEntity(id: "a", typeID: "person", name: "甲", evidence: [Evidence(unitID: "u1", quote: value.units[0].text)])]
        let chunk = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value)), authorization = try grant(chunk, in: value)
        var broken = value
        broken.relations = [KnowledgeRelation(id: "broken", fromID: "a", toID: "missing", label: "失效关联", evidence: [Evidence(unitID: "u1", quote: value.units[0].text)])]
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            XCTAssertThrowsError(try SmartReadingRuntime.completeAnalysis(arguments: completion(chunk, in: broken, noChangesReasons: [:]), in: &broken, allowedUnitIDs: Set(chunk.unitIDs)))
            _ = try SmartReadingRuntime.completeAnalysis(arguments: completion(chunk, in: value, noChangesReasons: [:]), in: &value, allowedUnitIDs: Set(chunk.unitIDs))
        }
        let checkpoint = try XCTUnwrap(value.smartReading?.analysisCheckpoints?.first)
        XCTAssertTrue(checkpoint.hostCitationSummary?.contains("宿主核对") == true)
        XCTAssertTrue(checkpoint.noChangesReasons == nil || checkpoint.noChangesReasons?.isEmpty == true)
        XCTAssertEqual(value.entities.count, 1, "复用不重建对象或伪造新产物。")
        XCTAssertTrue((value.paragraphReceipts ?? []).isEmpty, "宿主引文核验不等于逐段回执。")
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: completion(chunk, in: value)) as? [String: Any])
        forged["hostCitationSummary"] = "模型自报全部核验通过"
        let forgedData = try JSONSerialization.data(withJSONObject: forged)
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            XCTAssertThrowsError(try SmartReadingRuntime.completeAnalysis(arguments: forgedData, in: &value, allowedUnitIDs: Set(chunk.unitIDs)))
        }
    }

    func testRemovedOptionalStepsStayRemovedAndMethodGoalIsPartOfActualWork() throws {
        var value = try project(.init(granularity: .page, steps: []))
        let chunk = try XCTUnwrap(SmartReadingRuntime.nextAnalysisChunk(in: value)), authorization = try grant(chunk, in: value)
        try ReadingAnalysisAuthority.$current.withValue(authorization) {
            _ = try SmartReadingRuntime.completeAnalysis(arguments: completion(chunk, in: value, noChangesReasons: [:]), in: &value, allowedUnitIDs: Set(chunk.unitIDs))
        }
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(chunk, in: value))
        let index = try XCTUnwrap(value.methods.firstIndex { value.plan?.methodIDs.contains($0.id) == true })
        value.methods[index].goal += "新增一个真正的阅读方向。"
        XCTAssertNotEqual(try SmartReadingRuntime.analysisChunks(in: value).first?.id, chunk.id)
        XCTAssertEqual(value.smartReading?.analysisCheckpoints?.count, 1)
    }
}
