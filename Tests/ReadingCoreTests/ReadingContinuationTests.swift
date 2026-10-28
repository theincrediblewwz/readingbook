import Foundation
import XCTest
@testable import ReadingCore

final class ReadingContinuationTests: XCTestCase {
    private func project(pages: Int = 3, legacy: Bool = false) throws -> BookProject {
        let units = (1...pages).map { SourceUnit(id: "u\($0)", order: $0-1, chapter: "第一章", page: $0, text: "第\($0)页的完整原文。") }
        var p = BookProject(id: "book", title: "测试书", originalName: "book.pdf", sourceHash: String(repeating: "a", count: 64), units: units)
        p.methods = [ReadingMethod(id: "method", name: "基础阅读", goal: "理解原文", steps: ["说明内容"])]
        p.plan = ReadingPlan(methodIDs: ["method"], focus: ["因果"])
        let cfg = legacy ? nil : ReadingExecutionConfiguration(granularity: .page, steps: [ReadingExecutionStep(id: "understand", title: "说明内容")])
        p.smartReading = try SmartReadingRuntime.freeze(.init(scope: .wholeBook, execution: cfg), in: p, currentUnitID: "u1")
        p.smartReading?.isPlanConfirmed = true
        p.documents = [DocumentRecord(id: "note", title: "用户笔记")]
        return p
    }
    private func selection(_ p: BookProject, first: Int = 1, last: Int = 3) -> SmartReadingSelection {
        .init(scope: .pageRange, pageStart: first, pageEnd: last, execution: p.smartReading?.selection.execution)
    }
    private func save(_ work: ReadingAnalysisChunk, in p: inout BookProject) throws {
        let units = Dictionary(p.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cp = ReadingAnalysisCheckpoint(id: work.id, unitIDs: work.unitIDs,
            unitHashes: Dictionary(uniqueKeysWithValues: work.unitIDs.map { ($0, p.smartReading!.unitHashes[$0]!) }),
            configurationHash: work.configurationHash, completedStepIDs: work.stepIDs, markdown: "已有分析 "+work.id,
            evidence: work.unitIDs.map { Evidence(unitID: $0, quote: units[$0]!.text) }, updatedAt: Date(timeIntervalSince1970: 100))
        cp.scopeJob = work.scopeJob; cp.requiredComponentKinds = work.requiredComponentKinds
        let previousCheckpoints = p.smartReading?.analysisCheckpoints ?? []
        p.smartReading?.analysisCheckpoints = previousCheckpoints + [cp]
        p.insights.append(.init(id: "analysis-"+work.id, unitIDs: work.unitIDs, markdown: cp.markdown))
    }
    func testPreviewIsDeterministicAndLeavesProjectUntouched() throws {
        let p = try project(), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(p)
        let a = try ReadingContinuationRuntime.preview(selection: selection(p), in: p)
        let b = try ReadingContinuationRuntime.preview(selection: selection(p), in: p)
        XCTAssertEqual(a, b); XCTAssertEqual(a.selectedPageCount, 3); XCTAssertEqual(a.newUnitCount, 3)
        XCTAssertEqual(try encoder.encode(p), before); XCTAssertNil(p.smartReading?.continuation)
    }
    func testOverlapReusesRealProofAndPreservesNotesAndProse() throws {
        var p = try project()
        let work = try SmartReadingRuntime.analysisChunks(in: p)
        try save(work[0], in: &p); try save(work[1], in: &p)
        let prepared = try ReadingContinuationRuntime.prepare(selection: selection(p, first: 2), in: p)
        XCTAssertEqual(prepared.preview.reusedUnitCount, 1); XCTAssertEqual(prepared.preview.newUnitCount, 1)
        XCTAssertEqual(prepared.candidate.insights.map(\.markdown), p.insights.map(\.markdown))
        XCTAssertEqual(prepared.candidate.documents, p.documents)
        XCTAssertEqual(prepared.candidate.smartReading?.continuation?.baselineCheckpointIDs, [work[1].id])
        XCTAssertEqual(prepared.candidate.smartReading?.continuation?.baselineCompletedUnitIDs, ["u2"])
    }
    func testSupplementOnlyRunsNewComponentDelta() throws {
        var p = try project(pages: 1)
        let old = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: p).first); try save(old, in: &p)
        var requested = selection(p, last: 1); requested.execution?.componentKinds = [.map]
        let prepared = try ReadingContinuationRuntime.prepare(selection: requested, intent: .supplement, in: p)
        let index = ReadingAnalysisCompletionIndex(in: prepared.candidate)
        let tasks = try SmartReadingRuntime.analysisChunks(in: prepared.candidate)
        let pending = tasks.filter { !index.isComplete($0) }
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending.first?.stepIDs, [])
        XCTAssertEqual(pending.first?.requiredComponentKinds, [.map])
        XCTAssertTrue(tasks.contains { $0.id == old.id && index.isComplete($0) })
        XCTAssertNil(prepared.candidate.smartReading?.continuation?.generationID)
    }
    func testSupplementWithoutNewRequirementsHasNoModelWork() throws {
        var p = try project(pages: 1)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: p).first), in: &p)
        let view = try ReadingContinuationRuntime.preview(selection: selection(p, last: 1), intent: .supplement, in: p)
        XCTAssertFalse(view.hasWork); XCTAssertEqual(view.pendingChunkCount, 0); XCTAssertEqual(view.reusedUnitCount, 1)
    }
    func testNewStepDeltaDoesNotReplayOldStep() throws {
        var p = try project(pages: 1)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: p).first), in: &p)
        var request = selection(p, last: 1)
        request.execution?.steps.append(.init(id: "causes", title: "比较因果"))
        let prepared = try ReadingContinuationRuntime.prepare(selection: request, intent: .supplement, in: p)
        let index = ReadingAnalysisCompletionIndex(in: prepared.candidate)
        let pending = try SmartReadingRuntime.analysisChunks(in: prepared.candidate).filter { !index.isComplete($0) }
        XCTAssertEqual(pending.map(\.stepIDs), [["causes"]])
    }
    func testPartialFailureKeepsInventoryAndNextRequestResumesGap() throws {
        let original = try project()
        var p = try ReadingContinuationRuntime.prepare(selection: selection(original), in: original).candidate
        let inventory = try SmartReadingRuntime.analysisChunks(in: p)
        try save(inventory[0], in: &p)
        XCTAssertEqual(try SmartReadingRuntime.analysisChunks(in: p), inventory)
        let resumed = try ReadingContinuationRuntime.prepare(selection: selection(p), in: p)
        XCTAssertEqual(resumed.preview.reusedUnitCount, 1)
        let index = ReadingAnalysisCompletionIndex(in: resumed.candidate)
        XCTAssertEqual(try SmartReadingRuntime.analysisChunks(in: resumed.candidate).filter { !index.isComplete($0) }.count, 2)
    }
    func testRedoDoesNotActivateUntilNewActualOutputsExist() throws {
        var old = try project(pages: 1)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: old).first), in: &old)
        old.smartReading?.status = .completed
        let oldID = old.smartReading!.id, prose = old.insights.map(\.markdown)
        var p = try ReadingContinuationRuntime.prepare(selection: selection(old, last: 1), intent: .reanalyze, in: old).candidate
        XCTAssertNotNil(p.smartReading?.continuation?.generationID)
        XCTAssertEqual(p.smartReading?.continuation?.activeSessionID, oldID)
        XCTAssertThrowsError(try ReadingContinuationRuntime.completePreparedGeneration(in: &p))
        XCTAssertEqual(p.smartReading?.continuation?.activeSessionID, oldID)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: p).first), in: &p)
        try ReadingContinuationRuntime.completePreparedGeneration(in: &p)
        XCTAssertEqual(p.smartReading?.continuation?.activeSessionID, p.smartReading?.id)
        XCTAssertEqual(Array(p.insights.prefix(prose.count)).map(\.markdown), prose)
    }
    func testChangedSourceCannotReuseUnitIDAlone() throws {
        var p = try project(pages: 1)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: p).first), in: &p)
        p.units[0].text = "新的原文版本。"
        let v = try ReadingContinuationRuntime.preview(selection: selection(p, last: 1), in: p)
        XCTAssertEqual(v.reusedUnitCount, 0); XCTAssertEqual(v.incompatibleUnitCount, 1); XCTAssertTrue(v.hasWork)
    }
    func testLegacyNilContinuesWithoutConfiguredDefaultReview() throws {
        let old = try project(pages: 1, legacy: true)
        let continued = try ReadingContinuationRuntime.prepare(selection: selection(old, last: 1), in: old)
        XCTAssertNil(continued.candidate.smartReading?.selection.execution)
        XCTAssertEqual(continued.preview.newUnitCount, 1)
        let converted = try ReadingContinuationRuntime.prepare(selection: selection(old, last: 1), intent: .supplement, in: old)
        XCTAssertNotNil(converted.candidate.smartReading?.selection.execution)
        XCTAssertFalse(converted.candidate.smartReading?.selection.execution?.enabledSteps.contains { $0.frequency == .book || $0.actionID == "reading.review" } ?? true)
    }
    func testPreviewGuardRejectsNewlySavedProof() throws {
        var p = try project(pages: 1)
        let request = selection(p, last: 1)
        let shown = try ReadingContinuationRuntime.preview(selection: request, in: p)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: p).first), in: &p)
        XCTAssertThrowsError(try ReadingContinuationRuntime.prepare(selection: request, in: p, expectedPreviewFingerprint: shown.fingerprint))
    }
    func testRedoPreviewIsDeterministicPendingEvenWhenOldGenerationComplete() throws {
        var p = try project(pages: 1)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: p).first), in: &p)
        let request = selection(p, last: 1)
        let shown = try ReadingContinuationRuntime.preview(selection: request, intent: .reanalyze, in: p)
        XCTAssertTrue(shown.hasWork); XCTAssertEqual(shown.reusableChunkCount, 0)
        XCTAssertEqual(shown.pendingChunkCount, 1); XCTAssertEqual(shown.redoUnitCount, 1)
        XCTAssertEqual(shown, try ReadingContinuationRuntime.preview(selection: request, intent: .reanalyze, in: p))
        let prepared = try ReadingContinuationRuntime.prepare(selection: request, intent: .reanalyze, in: p,
            expectedPreviewFingerprint: shown.fingerprint)
        XCTAssertEqual(prepared.preview, shown)
        XCTAssertFalse(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: prepared.candidate).first).id == shown.workItems.first?.id)
    }
    func testSecondSupplementReusesSavedFirstDeltaWithoutReplayingUnderstanding() throws {
        var p = try project(pages: 1)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: p).first), in: &p)
        var request = selection(p, last: 1); request.execution?.componentKinds = [.map]
        p = try ReadingContinuationRuntime.prepare(selection: request, intent: .supplement, in: p).candidate
        let index = ReadingAnalysisCompletionIndex(in: p)
        for task in try SmartReadingRuntime.analysisChunks(in: p).filter({ !index.isComplete($0) }) { try save(task, in: &p) }
        request.execution?.componentKinds = [.map, .timeline]
        let second = try ReadingContinuationRuntime.prepare(selection: request, intent: .supplement, in: p)
        let nextIndex = ReadingAnalysisCompletionIndex(in: second.candidate)
        let pending = try SmartReadingRuntime.analysisChunks(in: second.candidate).filter { !nextIndex.isComplete($0) }
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending.first?.stepIDs, [])
        XCTAssertEqual(pending.first?.requiredComponentKinds, [.timeline])
        XCTAssertEqual(second.candidate.insights.map(\.markdown), p.insights.map(\.markdown))
    }
    func testForgedOrDuplicateInventoryCannotBecomeCompletionProof() throws {
        let old = try project(pages: 1)
        var p = try ReadingContinuationRuntime.prepare(selection: selection(old, last: 1), in: old).candidate
        var invented = try XCTUnwrap(p.smartReading?.continuation?.localWorkInventory?.first?.works.first)
        invented.id = "chunk-" + String(repeating: "b", count: 48)
        invented.configurationHash = String(repeating: "b", count: 64)
        p.smartReading?.continuation?.localWorkInventory?[0].works = [invented]
        try save(invented, in: &p)
        XCTAssertThrowsError(try SmartReadingRuntime.analysisChunks(in: p))
        invented.unitIDs = ["u1", "u1"]
        p.smartReading?.continuation?.localWorkInventory?[0].works = [invented]
        XCTAssertThrowsError(try SmartReadingRuntime.analysisChunks(in: p), "重复ID应抛错而不是Dictionary崩溃。")
    }
    func testPlanningReplacementPreservesHistoryWithoutOldInventoryOrCompletionBaseline() throws {
        var old = try project(pages: 1)
        try save(try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: old).first), in: &old)
        old.smartReading?.status = .completed
        var next = old; next.plan?.focus = ["新的侧重点"]
        next.smartReading = try SmartReadingRuntime.freeze(selection(old, last: 1), in: next, currentUnitID: "u1")
        try ReadingContinuationRuntime.preserveHistory(from: old, in: &next)
        XCTAssertEqual(next.smartReading?.continuation?.history.map(\.id), [old.smartReading!.id])
        XCTAssertEqual(next.smartReading?.continuation?.activeSessionID, old.smartReading?.id)
        XCTAssertNil(next.smartReading?.continuation?.localWorkInventory)
        XCTAssertTrue(next.smartReading?.continuation?.baselineCompletedWorkIDs.isEmpty ?? false)
        XCTAssertEqual(next.smartReading?.analysisCheckpoints?.map(\.markdown), old.smartReading?.analysisCheckpoints?.map(\.markdown))
        XCTAssertEqual(try ReadingContinuationRuntime.history(in: next).first?.checkpointCount, 1)
        XCTAssertFalse(try SmartReadingRuntime.analysisChunks(in: next).allSatisfy { ReadingAnalysisCompletionIndex(in: next).isComplete($0) })
    }
    func testHostPreparationMergeKeepsConcurrentNotesAndImmutableOldCheckpoint() throws {
        let old = try project(pages: 1)
        let prepared = try ReadingContinuationRuntime.prepare(selection: selection(old, last: 1), in: old).candidate
        var latest = old; latest.documents[0].title = "用户正在编辑的笔记"
        let merged = try AIProjectMerge.merge(base: old, result: prepared, latest: latest)
        XCTAssertEqual(merged.documents, latest.documents)
        XCTAssertEqual(merged.smartReading?.id, prepared.smartReading?.id)
        XCTAssertEqual(merged.smartReading?.continuation?.history.map(\.id), [old.smartReading!.id])
    }
    func testSameLevelChapterRangeNeverIncludesParentOrNextSibling() throws {
        let p = try project(pages: 3)
        let ranges = p.units.map { ReadingSourceRange(unitID: $0.id, startUTF16: 0, endUTF16: $0.text.utf16.count) }
        let chapters = [BookChapterRange(id: "volume", title: "卷", level: 0, ranges: ranges, isComplete: true)] + ranges.enumerated().map {
            BookChapterRange(id: "chapter-\($0.offset+1)", title: "第\($0.offset+1)章", level: 1, ranges: [$0.element], isComplete: true)
        }
        let index = BookChapterIndex(sourceFingerprint: try BookOutlineRuntime.fingerprint(in: p), chapters: chapters, segments: Array(chapters.dropFirst()))
        var request = SmartReadingSelection(scope: .chapterRange, chapterStartID: "chapter-1", chapterEndID: "chapter-2")
        XCTAssertEqual(try SmartReadingRuntime.selectedChapterRanges(request, index: index, in: p), Array(ranges.prefix(2)))
        request.chapterEndID = "volume"
        XCTAssertThrowsError(try SmartReadingRuntime.selectedChapterRanges(request, index: index, in: p))
        request.chapterStartID = "chapter-3"; request.chapterEndID = "chapter-1"
        XCTAssertThrowsError(try SmartReadingRuntime.selectedChapterRanges(request, index: index, in: p))
        request.chapterStartID = "chapter-1"; request.chapterEndID = "chapter-2"
        var incomplete = index; incomplete.chapters[2].isComplete = false
        XCTAssertThrowsError(try SmartReadingRuntime.selectedChapterRanges(request, index: incomplete, in: p))
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(request, in: p, currentUnitID: "u1"), "没有可信目录不能猜章节。")
    }
    func testOptionalContinuationDecodesExistingSessionWithoutInventedHistory() throws {
        let p = try project(pages: 1)
        let restored = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(p))
        XCTAssertNil(restored.smartReading?.continuation)
        XCTAssertNil(restored.smartReading?.selection.chapterStartID)
        XCTAssertEqual(try SmartReadingRuntime.analysisChunks(in: restored), try SmartReadingRuntime.analysisChunks(in: p))
    }
    func testModelCompletionArgumentsCannotSetGenerationOrActiveVersion() throws {
        var p = try project(pages: 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(p)
        let arguments = try JSONSerialization.data(withJSONObject: ["unitIDs": ["u1"], "completedStepIDs": ["understand"],
            "markdown": "伪完成", "evidence": [["unitID": "u1", "quote": p.units[0].text]],
            "continuation": ["generationID": "model-generation", "activeSessionID": "model-session"]])
        XCTAssertThrowsError(try SmartReadingRuntime.completeAnalysis(arguments: arguments, in: &p, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(try encoder.encode(p), before)
    }
    func testOverlapPreviewDescribesExactReusedAndFirstAnalysisPageIntervals() throws {
        var p = try project(pages: 200)
        for work in try SmartReadingRuntime.analysisChunks(in: p).prefix(100) { try save(work, in: &p) }
        let view = try ReadingContinuationRuntime.preview(selection: selection(p, first: 50, last: 200), in: p)
        XCTAssertEqual(view.reusedUnitCount, 51); XCTAssertEqual(view.newUnitCount, 100)
        let reused = try XCTUnwrap(view.detailRows.first { $0.id == "range-reused" })
        let first = try XCTUnwrap(view.detailRows.first { $0.id == "range-first" })
        XCTAssertTrue(reused.detail.contains("涉及第50–100页"))
        XCTAssertTrue(first.detail.contains("涉及第101–200页"))
        XCTAssertFalse(reused.detail.contains("50–200"))
        let disjoint = ReadingContinuationRuntime.rangeDescription(unitIDs: stride(from: 1, through: 199, by: 2).map { "u\($0)" }, in: p)
        XCTAssertTrue(disjoint.contains("第1、3、5")); XCTAssertTrue(disjoint.contains("197、199页"))
        XCTAssertFalse(disjoint.contains("1–199")); XCTAssertFalse(disjoint.contains("…"))
    }
    func testSplitPageCanAppearInReusedAndMissingWithoutWholePageCompletionClaim() throws {
        var p = try project(pages: 2)
        p.units[0].text = String(repeating: "甲阅读原文。", count: 1800)
        p.units[1].text = String(repeating: "乙继续原文。", count: 1800)
        p.units[1].page = 1
        p.smartReading = try SmartReadingRuntime.freeze(.init(scope: .wholeBook, execution: p.smartReading?.selection.execution), in: p, currentUnitID: "u1")
        let work = try SmartReadingRuntime.analysisChunks(in: p)
        XCTAssertEqual(work.count, 2, "相同页内的长原始单元分别形成有界任务。")
        try save(try XCTUnwrap(work.first), in: &p)
        let view = try ReadingContinuationRuntime.preview(selection: selection(p, last: 1), in: p)
        XCTAssertEqual(view.selectedUnitCount, 2); XCTAssertEqual(view.selectedPageCount, 1)
        XCTAssertEqual(view.reusedUnitCount, 1); XCTAssertEqual(view.newUnitCount, 1)
        for id in ["range-reused", "range-first"] {
            let detail = try XCTUnwrap(view.detailRows.first { $0.id == id }).detail
            XCTAssertTrue(detail.contains("涉及第1页（共1页，1个内容单元）"))
            XCTAssertTrue(detail.contains("不代表整页已完成")); XCTAssertTrue(detail.contains("未选片段不计为完成"))
        }
        var unpaged = p; unpaged.units[0].page = nil; unpaged.units[1].page = nil
        unpaged.units.reverse() // Ordinals follow whole-source order, not storage array order.
        let description = ReadingContinuationRuntime.rangeDescription(unitIDs: ["u2", "u2", "unknown"], in: unpaged)
        XCTAssertTrue(description.contains("全书内容单元2（共1个）"))
        XCTAssertTrue(description.contains("另有1个来源单元未匹配")); XCTAssertFalse(description.contains("第1页"))
    }
}
