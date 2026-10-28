import Foundation
import XCTest
@testable import ReadingCore

final class ReadingContinuationHistoryTests: XCTestCase {
    private func fixture(configured: Bool = true) throws -> BookProject {
        var project = BookProject(title: "离线历史测试", originalName: "history.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            SourceUnit(id: "u1", order: 0, chapter: "第一章", page: 1, text: "保留的第一段。"),
            SourceUnit(id: "u2", order: 1, chapter: "第二章", page: 2, text: "范围以外的第二段。")
        ])
        PluginEngine.seed(&project); project.plan = ReadingPlan(methodIDs: ["genre.history"])
        var selection = SmartReadingSelection(scope: .currentPage)
        if configured { selection.execution = ReadingExecutionConfiguration() }
        let old = try SmartReadingRuntime.freeze(selection, in: project, currentUnitID: "u1")
        let date = Date(timeIntervalSince1970: 1_000)
        let checkpoint = ReadingAnalysisCheckpoint(id: "old-result", unitIDs: old.unitIDs, unitHashes: old.unitHashes,
            configurationHash: "old-contract", completedStepIDs: ["understand"], markdown: "旧分析 $x^2$，不能替换。",
            evidence: [], updatedAt: date)
        let archive = ReadingContinuationArchivedSession(id: "old-session", selection: old.selection, scopeTitle: old.scopeTitle,
            unitIDs: old.unitIDs, unitHashes: old.unitHashes, sourceHash: old.sourceHash, status: .completed,
            isPlanConfirmed: true, currentUnitID: nil, updatedAt: date, lastMessage: nil,
            analysisCheckpointIDs: [checkpoint.id], chapterIndex: old.chapterIndex, sourceRanges: old.sourceRanges,
            retainedAnalysisChunks: nil, retainedAnalysisWorkHash: nil, intent: .continueMissing,
            generationIntent: .continueMissing, generationID: nil, activeGenerationID: nil, activeSessionID: nil,
            planFingerprint: nil, localWorkInventory: nil)
        var current = try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .wholeBook,
            execution: ReadingExecutionConfiguration()), in: project, currentUnitID: "u2")
        current.analysisCheckpoints = [checkpoint]
        current.continuation = ReadingContinuationMetadata(intent: .reanalyze, generationID: "new-version", history: [archive])
        project.smartReading = current
        return project
    }

    func testExactHistoricalReferencesNeverUseCurrentReplacementOrWriteProject() throws {
        var project = try fixture()
        project.smartReading?.analysisCheckpoints?.append(ReadingAnalysisCheckpoint(id: "new-result", unitIDs: ["u1"],
            unitHashes: [:], configurationHash: "new-contract", completedStepIDs: ["understand"], markdown: "新分析。", evidence: [], updatedAt: Date()))
        project.smartReading?.continuation?.history[0].analysisCheckpointIDs += ["missing-result", "old-result"]
        let before = try JSONEncoder().encode(project)
        let entries = try ReadingContinuationRuntime.history(in: project)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].checkpointCount, 1)
        XCTAssertEqual(entries[0].missingCheckpointCount, 1)
        XCTAssertTrue(entries[0].isSourceCurrent)
        let detail = try ReadingContinuationRuntime.historyDetails(sessionID: entries[0].id, in: project)
        XCTAssertEqual(detail.checkpoints.map(\.id), ["old-result"])
        XCTAssertEqual(detail.checkpoints.first?.markdown, "旧分析 $x^2$，不能替换。")
        XCTAssertEqual(detail.missingCheckpointIDs, ["missing-result"])
        XCTAssertFalse(detail.warnings.isEmpty)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(project), try encoder.encode(JSONDecoder().decode(BookProject.self, from: before)))
        XCTAssertEqual(project.smartReading?.continuation?.generationID, "new-version")
    }

    func testSameUnitIDAfterSourceOrTextChangeIsHistoricalOnlyAndKeepsProse() throws {
        let original = try fixture()
        var changedText = original; changedText.units[0].text = "同 ID 的新版原文。"
        XCTAssertFalse(try XCTUnwrap(ReadingContinuationRuntime.history(in: changedText).first).isSourceCurrent)
        let detail = try ReadingContinuationRuntime.historyDetails(sessionID: "old-session", in: changedText)
        XCTAssertEqual(detail.checkpoints.first?.markdown, "旧分析 $x^2$，不能替换。")
        XCTAssertTrue(detail.warnings.contains { $0.contains("原文版本") })
        var changedSource = original; changedSource.sourceHash = String(repeating: "b", count: 64)
        XCTAssertFalse(try XCTUnwrap(ReadingContinuationRuntime.history(in: changedSource).first).isSourceCurrent)
    }

    func testLegacyProseIsBoundedByScopeAndTimeAndNotInventedAsCompletion() throws {
        var project = try fixture(configured: false)
        project.insights = [
            ReadingInsight(id: "analysis-u1", unitIDs: ["u1"], markdown: "范围内旧内容", createdAt: Date(timeIntervalSince1970: 900)),
            ReadingInsight(id: "outside", unitIDs: ["u1", "u2"], markdown: "范围外内容", createdAt: Date(timeIntervalSince1970: 900)),
            ReadingInsight(id: "future", unitIDs: ["u1"], markdown: "后来的新内容", createdAt: Date(timeIntervalSince1970: 1_100)),
            ReadingInsight(id: "analysis-chunk-current", unitIDs: ["u1"], markdown: "别的 configured 结果", createdAt: Date(timeIntervalSince1970: 800)),
            ReadingInsight(id: "blank-u1", unitIDs: ["u1"], markdown: "空白标记", createdAt: Date(timeIntervalSince1970: 800))
        ]
        let detail = try ReadingContinuationRuntime.historyDetails(sessionID: "old-session", in: project)
        XCTAssertEqual(detail.legacyInsights.map(\.id), ["analysis-u1"])
        XCTAssertEqual(detail.entry.legacyInsightCount, 1)
        XCTAssertEqual(detail.entry.checkpointCount, 1, "旧内容不会被伪造为额外的成功检查点。")
        XCTAssertTrue(detail.warnings.contains { $0.contains("不能证明") })
    }

    func testMissingOrDuplicatedHistoryDoesNotTrapOrResolveAnotherSession() throws {
        var project = try fixture()
        let archive = try XCTUnwrap(project.smartReading?.continuation?.history.first)
        project.smartReading?.continuation?.history.append(archive)
        XCTAssertEqual(try ReadingContinuationRuntime.history(in: project).count, 1)
        XCTAssertThrowsError(try ReadingContinuationRuntime.historyDetails(sessionID: "unrelated", in: project))
        var empty = project; empty.smartReading?.continuation?.history = []
        XCTAssertTrue(try ReadingContinuationRuntime.history(in: empty).isEmpty)
    }

    func testReferencedCheckpointMustMatchArchivedUnitHashesAndExactRange() throws {
        var wrongUnit = try fixture()
        wrongUnit.smartReading?.analysisCheckpoints?[0].unitIDs = ["u2"]
        XCTAssertTrue(try ReadingContinuationRuntime.historyDetails(sessionID: "old-session", in: wrongUnit).checkpoints.isEmpty)
        var wrongHash = try fixture()
        wrongHash.smartReading?.analysisCheckpoints?[0].unitHashes["u1"] = "different-text"
        XCTAssertEqual(try ReadingContinuationRuntime.historyDetails(sessionID: "old-session", in: wrongHash).missingCheckpointIDs, ["old-result"])
        var crossesBoundary = try fixture()
        crossesBoundary.smartReading?.continuation?.history[0].sourceRanges = [ReadingSourceRange(unitID: "u1", startUTF16: 0, endUTF16: 3)]
        crossesBoundary.smartReading?.analysisCheckpoints?[0].sourceRanges = [ReadingSourceRange(unitID: "u1", startUTF16: 0, endUTF16: 6)]
        XCTAssertTrue(try ReadingContinuationRuntime.historyDetails(sessionID: "old-session", in: crossesBoundary).checkpoints.isEmpty)
        crossesBoundary.smartReading?.analysisCheckpoints?[0].sourceRanges = [ReadingSourceRange(unitID: "u1", startUTF16: 0, endUTF16: 3)]
        XCTAssertEqual(try ReadingContinuationRuntime.historyDetails(sessionID: "old-session", in: crossesBoundary).checkpoints.map(\.id), ["old-result"])
    }
}
