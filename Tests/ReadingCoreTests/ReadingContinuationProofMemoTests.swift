import Foundation
import XCTest
@testable import ReadingCore

final class ReadingContinuationProofMemoTests: XCTestCase {
    private func project(pages: Int = 2, saved: Bool = true) throws -> BookProject {
        let units = (1...pages).map { SourceUnit(id: "u\($0)", order: $0 - 1, chapter: "第一章", page: $0, text: "第\($0)页的原文。") }
        var p = BookProject(id: "memo-book", title: "证明隔离", originalName: "memo.pdf", sourceHash: String(repeating: "a", count: 64), units: units)
        p.methods = [.init(id: "method", name: "基础阅读", goal: "理解原文", steps: ["说明内容"])]
        p.plan = ReadingPlan(methodIDs: ["method"], focus: ["因果"])
        p.smartReading = try SmartReadingRuntime.freeze(.init(scope: .wholeBook,
            execution: .init(granularity: .page, steps: [.init(id: "understand", title: "说明内容")])), in: p, currentUnitID: "u1")
        p.smartReading?.isPlanConfirmed = true
        p.documents = [.init(id: "retained-note", title: "保留笔记")]
        if saved {
            for work in try SmartReadingRuntime.analysisChunks(in: p) { save(work, in: &p) }
        }
        return p
    }
    private func selection(_ p: BookProject) -> SmartReadingSelection {
        .init(scope: .wholeBook, execution: p.smartReading?.selection.execution)
    }
    private func save(_ work: ReadingAnalysisChunk, in p: inout BookProject) {
        let units = Dictionary(p.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cp = ReadingAnalysisCheckpoint(id: work.id, unitIDs: work.unitIDs,
            unitHashes: Dictionary(work.unitIDs.map { ($0, p.smartReading!.unitHashes[$0]!) }, uniquingKeysWith: { a, _ in a }),
            configurationHash: work.configurationHash, completedStepIDs: work.stepIDs, markdown: "保留的分析",
            evidence: work.unitIDs.map { .init(unitID: $0, quote: units[$0]!.text) }, updatedAt: Date(timeIntervalSince1970: 100))
        cp.sourceRanges = work.sourceRanges; cp.chapterID = work.chapterID
        cp.scopeJob = work.scopeJob; cp.requiredComponentKinds = work.requiredComponentKinds
        var records = p.smartReading?.analysisCheckpoints ?? []; records.append(cp); p.smartReading?.analysisCheckpoints = records
    }
    func testSameRawIDWithDifferentCompleteContractsKeepsIndependentProofKeys() throws {
        let old = try project()
        let p = try ReadingContinuationRuntime.prepare(selection: selection(old), in: old).candidate
        let expected = try SmartReadingRuntime.analysisChunks(in: p)
        var raw = try SmartReadingRuntime.unprojectedLocalAnalysisChunks(in: p)
        XCTAssertEqual(raw.count, 2)
        // rawKey is a source/requirement contract, not the raw descriptor ID.
        // Historical real checkpoints still provide two distinct output IDs.
        raw[1].id = raw[0].id
        let groups = try ReadingContinuationRuntime.projectLocalWork(raw, in: p)
        XCTAssertEqual(groups.flatMap { $0 }, expected)
        XCTAssertEqual(groups.map { $0.flatMap(\.unitIDs) }, [["u1"], ["u2"]])
    }
    func testSameIDForgedSourceCannotHitTheRawSourceDigest() throws {
        let old = try project(saved: false)
        var p = try ReadingContinuationRuntime.prepare(selection: selection(old), in: old).candidate
        var forged = try XCTUnwrap(p.smartReading?.continuation?.localWorkInventory?.first?.works.first)
        forged.unitIDs = ["u2"] // Same output ID/configuration; different source.
        p.smartReading?.continuation?.localWorkInventory?[0].works = [forged]
        XCTAssertThrowsError(try SmartReadingRuntime.analysisChunks(in: p)) { error in
            XCTAssertEqual(error.localizedDescription, "本轮分析任务超出已确认原文或步骤，已有内容保留。")
        }
    }
    func testLaterCallRevalidatesChangedSourceAndCheckpointProofs() throws {
        var p = try project()
        let first = try ReadingContinuationRuntime.prepare(selection: selection(p), in: p)
        XCTAssertEqual(first.preview.reusedUnitCount, 2)
        let notes = p.documents, prose = p.smartReading?.analysisCheckpoints?.map(\.markdown)
        p.units[0].text = "第1页的新文。" // Same ID, same UTF16 length, changed source.
        let changed = try ReadingContinuationRuntime.prepare(selection: selection(p), in: p)
        XCTAssertEqual(changed.preview.reusedUnitCount, 1)
        XCTAssertEqual(changed.preview.incompatibleUnitCount, 1)
        XCTAssertEqual(changed.candidate.documents, notes)
        XCTAssertEqual(changed.candidate.smartReading?.analysisCheckpoints?.map(\.markdown), prose)
        p.units[0].text = "第1页的原文。"
        p.smartReading?.analysisCheckpoints?[0].evidence = []
        let missing = try ReadingContinuationRuntime.prepare(selection: selection(p), in: p)
        XCTAssertEqual(missing.preview.reusedUnitCount, 1)
        XCTAssertTrue(missing.preview.hasWork)
    }
    func testSameSourceNewStepAndComponentRemainMissingAfterEarlierWarmCall() throws {
        let p = try project(pages: 1)
        XCTAssertFalse(try ReadingContinuationRuntime.prepare(selection: selection(p), in: p).preview.hasWork)
        var request = selection(p)
        request.execution?.steps.append(.init(id: "causes", title: "比较因果"))
        request.execution?.componentKinds = [.map]
        let next = try ReadingContinuationRuntime.prepare(selection: request, intent: .supplement, in: p)
        let index = ReadingAnalysisCompletionIndex(in: next.candidate)
        let pending = try SmartReadingRuntime.analysisChunks(in: next.candidate).filter { !index.isComplete($0) }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.stepIDs, ["causes"])
        XCTAssertEqual(pending.first?.requiredComponentKinds, [.map])
        XCTAssertEqual(next.candidate.documents, p.documents)
        XCTAssertEqual(next.candidate.smartReading?.analysisCheckpoints, p.smartReading?.analysisCheckpoints)
    }
    func testRedoAndChangedHistoryNeverReuseCurrentProjectionMemo() throws {
        var p = try project(pages: 1); p.smartReading?.status = .completed
        let warm = try ReadingContinuationRuntime.prepare(selection: selection(p), in: p)
        XCTAssertFalse(warm.preview.hasWork)
        let redo = try ReadingContinuationRuntime.prepare(selection: selection(p), intent: .reanalyze, in: p)
        XCTAssertTrue(redo.preview.hasWork)
        XCTAssertEqual(redo.candidate.smartReading?.continuation?.activeSessionID, p.smartReading?.id)
        XCTAssertNotNil(redo.candidate.smartReading?.continuation?.generationID)
        var request = selection(p); request.execution?.componentKinds = [.map]
        var changed = try ReadingContinuationRuntime.prepare(selection: request, intent: .supplement, in: p).candidate
        changed.smartReading?.continuation?.history[0].unitHashes["u1"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try SmartReadingRuntime.analysisChunks(in: changed))
    }
}
