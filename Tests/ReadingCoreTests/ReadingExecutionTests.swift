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
    private func completion(_ chunk: ReadingAnalysisChunk, in project: BookProject) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["unitIDs": chunk.unitIDs, "completedStepIDs": chunk.stepIDs,
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
}
