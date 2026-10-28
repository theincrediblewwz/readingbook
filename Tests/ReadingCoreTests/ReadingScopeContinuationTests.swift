import Foundation
import XCTest
@testable import ReadingCore

final class ReadingScopeContinuationTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let units = (1...200).map { SourceUnit(id: "p\($0)", order: $0 - 1, chapter: "合成章", page: $0, text: "合成第\($0)页，甲在此阅读。") }
        var value = BookProject(id: "scope-regression", title: "合成范围", originalName: "synthetic.pdf",
                                sourceHash: String(repeating: "b", count: 64), units: units)
        PluginEngine.seed(&value)
        value.plan = ReadingPlan(methodIDs: ["genre.history"])
        let execution = ReadingExecutionConfiguration(granularity: .page, steps: [
            ReadingExecutionStep(id: "part", title: "本页分析"),
            ReadingExecutionStep(id: "review", title: "本轮回顾", actionID: "reading.review", frequency: .book)
        ])
        value.smartReading = try SmartReadingRuntime.freeze(.init(scope: .pageRange, pageStart: 50, pageEnd: 200, execution: execution),
                                                           in: value, currentUnitID: "p50")
        return value
    }

    private func complete(_ chunk: ReadingAnalysisChunk, in project: inout BookProject) throws {
        let session = try XCTUnwrap(project.smartReading)
        let allowed = Set(chunk.unitIDs)
        let grant = ReadingAnalysisAuthority.Grant(bookID: project.id, sessionID: session.id, sourceHash: project.sourceHash,
            chunk: chunk, unitHashes: session.unitHashes.filter { allowed.contains($0.key) })
        let arguments = try JSONSerialization.data(withJSONObject: ["unitIDs": chunk.unitIDs, "completedStepIDs": chunk.stepIDs,
            "markdown": "合成分析：" + chunk.title, "evidence": chunk.unitIDs.map { id in
                ["unitID": id, "quote": project.units.first { $0.id == id }!.text]
            }])
        try ReadingAnalysisAuthority.$current.withValue(grant) {
            _ = try SmartReadingRuntime.completeAnalysis(arguments: arguments, in: &project, allowedUnitIDs: allowed)
        }
    }
    private func finishCurrentWork(in project: inout BookProject) throws {
        while true {
            let chunks = try SmartReadingRuntime.analysisChunks(in: project)
            let completion = ReadingAnalysisCompletionIndex(in: project)
            guard let next = chunks.first(where: { !completion.isComplete($0) }) else { return }
            XCTAssertTrue(try SmartReadingRuntime.analysisDependenciesComplete(next, in: project))
            try complete(next, in: &project)
        }
    }

    func testWidenedScopeWithSameEndDoesNotReuseOldBookReview() throws {
        var value = try fixture()
        try finishCurrentWork(in: &value)
        let oldLast = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).last)
        let originalCheckpoints = try XCTUnwrap(value.smartReading?.analysisCheckpoints)
        let originalInsights = value.insights
        var next = try SmartReadingRuntime.freeze(.init(scope: .wholeBook, execution: value.smartReading?.selection.execution),
                                                  in: value, currentUnitID: "p1")
        next.analysisCheckpoints = originalCheckpoints; value.smartReading = next
        let widened = try SmartReadingRuntime.analysisChunks(in: value)
        let newLast = try XCTUnwrap(widened.last)
        XCTAssertEqual(oldLast.unitIDs, newLast.unitIDs)
        XCTAssertFalse(SmartReadingRuntime.isChunkComplete(newLast, in: value), "旧50–200回顾不能代表新的1–200回顾。")
        XCTAssertNotEqual(oldLast.id, newLast.id)
        XCTAssertEqual(widened.filter { !SmartReadingRuntime.isChunkComplete($0, in: value) }.count, 50,
                       "49个新增局部分析及1个范围回顾待做；已完成局部来源仍可复用。")
        XCTAssertEqual(value.smartReading?.analysisCheckpoints, originalCheckpoints)
        XCTAssertEqual(value.insights.map(\.id), originalInsights.map(\.id))
        XCTAssertEqual(value.insights.map(\.markdown), originalInsights.map(\.markdown))
    }

    func testScopeReviewWaitsForEverySavedLocalDependencyIncludingItsCarrier() throws {
        var value = try fixture()
        let initial = try SmartReadingRuntime.analysisChunks(in: value)
        let review = try XCTUnwrap(initial.last)
        XCTAssertEqual(review.scopeJob?.kind, .book)
        XCTAssertFalse(try SmartReadingRuntime.analysisDependenciesComplete(review, in: value))
        XCTAssertThrowsError(try complete(review, in: &value))
        let local = initial.filter { $0.scopeJob == nil }
        for chunk in local.dropLast() { try complete(chunk, in: &value) }
        let catalog = try ReadingAnalysisRunCatalog(in: value, allowedUnitIDs: Set(value.smartReading!.unitIDs))
        var queue = try catalog.makeQueue(completed: catalog.initialCompletedIDs)
        let terminalLocal = try XCTUnwrap(local.last)
        XCTAssertEqual(queue.next(currentUnitID: "p200")?.id, terminalLocal.id)
        XCTAssertTrue(queue.begin(terminalLocal.id))
        XCTAssertNil(queue.next(currentUnitID: "p200"), "回顾不能和尚未保存的末页局部任务同批启动。")
        try complete(terminalLocal, in: &value)
        let readyReview = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).last)
        XCTAssertTrue(try SmartReadingRuntime.analysisDependenciesComplete(readyReview, in: value))
        XCTAssertNotEqual(review.id, readyReview.id, "pending不能充当已保存依赖版本。")
        try complete(readyReview, in: &value)
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(readyReview, in: value))
    }

    func testUpstreamVersionChangeInvalidatesOnlyTheScopeReview() throws {
        var value = try fixture(); try finishCurrentWork(in: &value)
        let oldChunks = try SmartReadingRuntime.analysisChunks(in: value)
        let oldReview = try XCTUnwrap(oldChunks.last)
        let oldCheckpoints = value.smartReading!.analysisCheckpoints!
        let firstLocal = try XCTUnwrap(oldChunks.first)
        let index = try XCTUnwrap(value.smartReading?.analysisCheckpoints?.firstIndex { $0.id == firstLocal.id })
        value.smartReading?.analysisCheckpoints?[index].markdown += "\n新的已保存上游版本。"
        let current = try SmartReadingRuntime.analysisChunks(in: value)
        let newReview = try XCTUnwrap(current.last)
        XCTAssertNotEqual(oldReview.id, newReview.id)
        XCTAssertFalse(SmartReadingRuntime.isChunkComplete(newReview, in: value))
        XCTAssertTrue(current.filter { $0.scopeJob == nil }.allSatisfy { SmartReadingRuntime.isChunkComplete($0, in: value) })
        XCTAssertTrue(value.smartReading!.analysisCheckpoints!.contains { $0.id == oldReview.id })
        XCTAssertEqual(value.smartReading!.analysisCheckpoints!.count, oldCheckpoints.count)
        XCTAssertEqual(try SmartReadingRuntime.completedLocalUnitIDs(in: value).count, 151)
    }

    func testNoEnabledScopeStepAddsNoScopeTask() throws {
        var value = try fixture()
        value.smartReading?.selection.execution?.steps.removeAll { $0.frequency != .chunk }
        let chunks = try SmartReadingRuntime.analysisChunks(in: value)
        XCTAssertEqual(chunks.count, 151)
        XCTAssertTrue(chunks.allSatisfy { $0.scopeJob == nil })
    }

    func testLegacyCompositeCanProveLocalContractButNotNewScopeReview() throws {
        var value = try fixture()
        let raw = try SmartReadingRuntime.rawAnalysisChunks(in: value, allowedUnitIDs: nil)
        let last = try XCTUnwrap(raw.last)
        let session = try XCTUnwrap(value.smartReading)
        let checkpoint = ReadingAnalysisCheckpoint(id: last.id, unitIDs: last.unitIDs,
            unitHashes: session.unitHashes.filter { last.unitIDs.contains($0.key) }, configurationHash: last.configurationHash,
            completedStepIDs: last.stepIDs, markdown: "旧复合输出原样保留，不拆成虚构独立文本。",
            evidence: last.unitIDs.map { id in Evidence(unitID: id, quote: value.units.first { $0.id == id }!.text) }, updatedAt: Date())
        value.smartReading?.analysisCheckpoints = [checkpoint]
        let current = try SmartReadingRuntime.analysisChunks(in: value)
        let local = try XCTUnwrap(current.first { $0.scopeJob == nil && $0.unitIDs == last.unitIDs })
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(local, in: value))
        XCTAssertEqual(SmartReadingRuntime.compatibleCompletionCheckpointIDs(for: local, in: value), [checkpoint.id])
        XCTAssertFalse(SmartReadingRuntime.isChunkComplete(try XCTUnwrap(current.last), in: value))
        XCTAssertEqual(value.smartReading?.analysisCheckpoints, [checkpoint])
    }

    func testScopeAdmissionDoesNotInvokeTransportBeforeDependenciesAreSaved() async throws {
        let value = try fixture(), counter = ScopeRequestCounter()
        let reader = AIReader(transport: { _ in await counter.increment(); throw ReadingError.invalid("unexpected transport") })
        let job = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).last)
        do {
            _ = try await reader.readChunk(project: value, chunk: job, settings: ProviderSettings(), apiKey: "")
            XCTFail("未完成依赖不能启动范围回顾")
        } catch { XCTAssertTrue(error.localizedDescription.contains("前序分析")) }
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
    }

    func testScopeStorageRoundTripAndMalformedDependencyRejection() throws {
        var value = try fixture(); try finishCurrentWork(in: &value)
        let decoded = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(value))
        XCTAssertNoThrow(try SmartReadingRuntime.validateStoredState(in: decoded))
        let chunks = try SmartReadingRuntime.analysisChunks(in: decoded)
        XCTAssertTrue(chunks.allSatisfy { SmartReadingRuntime.isChunkComplete($0, in: decoded) })
        let scope = try XCTUnwrap(value.smartReading?.analysisCheckpoints?.firstIndex { $0.scopeJob != nil })
        value.smartReading?.analysisCheckpoints?[scope].scopeJob?.dependencyIDs = ["forged-id"]
        XCTAssertThrowsError(try SmartReadingRuntime.validateStoredState(in: value))
    }

    func testLocalGrantCannotSneakScopeStepsIntoSameBatch() throws {
        var value = try fixture()
        let oldStyleComposite = try XCTUnwrap(SmartReadingRuntime.rawAnalysisChunks(in: value, allowedUnitIDs: nil).last)
        XCTAssertTrue(oldStyleComposite.stepIDs.contains("review"))
        XCTAssertNil(oldStyleComposite.scopeJob)
        XCTAssertThrowsError(try complete(oldStyleComposite, in: &value))
        XCTAssertTrue((value.smartReading?.analysisCheckpoints ?? []).isEmpty)
    }

    func testChangedUpstreamSourceRejectsScopeBeforeTransport() async throws {
        var value = try fixture(); try finishCurrentWork(in: &value)
        let scope = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).last)
        value.units[49].text += "所选范围内的前序源发生变化。"
        let counter = ScopeRequestCounter()
        let reader = AIReader(transport: { _ in await counter.increment(); throw ReadingError.invalid("unexpected transport") })
        do {
            _ = try await reader.readChunk(project: value, chunk: scope, settings: ProviderSettings(), apiKey: "")
            XCTFail("过期原文不能复用范围回顾或发送新请求")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("变化") || error.localizedDescription.contains("改变"))
        }
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
    }
    func testCompletionIndexRejectsForgedOrDuplicateCheckpointProof() throws {
        var value = try fixture()
        let local = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).first)
        try complete(local, in: &value)
        let genuine = try XCTUnwrap(value.smartReading?.analysisCheckpoints?.first)
        let invalid: [(inout ReadingAnalysisCheckpoint) -> Void] = [
            { $0.markdown = " \n" }, { $0.unitHashes = [:] }, { $0.evidence = [] },
            { $0.completedStepIDs = ["part", "part"] },
            { $0.evidence = [Evidence(unitID: "p50", quote: "这不是原书中的任何连续文字")] }
        ]
        for mutate in invalid {
            var forged = genuine; mutate(&forged)
            value.smartReading?.analysisCheckpoints = [forged]
            XCTAssertFalse(ReadingAnalysisCompletionIndex(in: value).isComplete(local))
        }
        value.smartReading?.analysisCheckpoints = [genuine, genuine]
        XCTAssertFalse(ReadingAnalysisCompletionIndex(in: value).isComplete(local))
    }
}

private actor ScopeRequestCounter {
    var calls = 0
    func increment() { calls += 1 }
}
