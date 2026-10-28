import Foundation
import XCTest
@testable import ReadingCore

final class ReadingAnalysisSchedulerTests: XCTestCase {
    private var chunks: [ReadingAnalysisChunk] {
        (0..<8).map { ReadingAnalysisChunk(id: "c\($0)", title: "第\($0 + 1)页", unitIDs: ["u\($0)"], configurationHash: "unchanged", stepIDs: ["part"]) }
    }
    private var steps: [ReadingExecutionStep] { [ReadingExecutionStep(id: "part", title: "理解")] }
    private var chapters: [String: String] { Dictionary(uniqueKeysWithValues: (0..<8).map { ("u\($0)", $0 < 4 ? "一" : "二") }) }

    func testCurrentPageComesFirstButOldestGetsEveryFourthDispatch() throws {
        let jobs = chunks
        let first = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: [], running: [], steps: steps, chapters: chapters, currentUnitID: "u6", dispatchCount: 0)
        XCTAssertEqual(first?.id, "c6")
        let next = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: [], running: ["c6"], steps: steps, chapters: chapters, currentUnitID: "u6", dispatchCount: 1)
        XCTAssertEqual(next?.id, "c7")
        let oldest = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: [], running: ["c6", "c7"], steps: steps, chapters: chapters, currentUnitID: "u6", dispatchCount: 3)
        XCTAssertEqual(oldest?.id, "c0")
        XCTAssertEqual(jobs, chunks, "调度不能修改源顺序、配置哈希或块身份")
    }

    func testChapterAndBookReviewStillWaitForTheirRealDependencies() throws {
        var jobs = chunks
        jobs[3].stepIDs.append("chapter"); jobs[7].stepIDs.append("book")
        let actions = steps + [ReadingExecutionStep(id: "chapter", title: "章末", frequency: .chapter), ReadingExecutionStep(id: "book", title: "书末", frequency: .book)]
        let blocked = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: [], running: [], steps: actions, chapters: chapters, currentUnitID: "u7", dispatchCount: 0)
        XCTAssertNotEqual(blocked?.id, "c7")
        let chapter = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: ["c0", "c1", "c2"], running: [], steps: actions, chapters: chapters, currentUnitID: "u3", dispatchCount: 0)
        XCTAssertEqual(chapter?.id, "c3")
        let allPrior = Set(jobs.dropLast().map(\.id))
        let book = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: allPrior, running: [], steps: actions, chapters: chapters, currentUnitID: "u7", dispatchCount: 0)
        XCTAssertEqual(book?.id, "c7")
    }

    func testUnknownPageUsesSourceOrderAndCompletedOrRunningJobsAreNeverRepeated() {
        let result = ReadingAnalysisScheduler.nextReadyChunk(in: chunks, completed: ["c0"], running: ["c1"], steps: steps, chapters: chapters, currentUnitID: "other-book-unit", dispatchCount: 0)
        XCTAssertEqual(result?.id, "c2")
        XCTAssertNil(ReadingAnalysisScheduler.nextReadyChunk(in: chunks, completed: Set(chunks.map(\.id)), running: [], steps: steps, chapters: chapters, currentUnitID: "u6", dispatchCount: 0))
    }

    func testLinearDependencyIndexMatchesPriorSchedulerAcrossMixedStates() {
        var jobs = chunks
        jobs[1].stepIDs = ["part", "chapter"]
        jobs[2].unitIDs = ["u2", "u5"] // A block can span chapter boundaries.
        jobs[2].stepIDs = ["chapter"]
        jobs[4].stepIDs = ["book"]
        jobs[6].stepIDs = ["chapter", "book"]
        jobs[7].unitIDs = ["u7", "unknown-unit"]
        jobs[7].stepIDs = ["chapter"]
        let actions = steps + [ReadingExecutionStep(id: "chapter", title: "章末", frequency: .chapter), ReadingExecutionStep(id: "book", title: "书末", frequency: .book)]
        var chapterMap = chapters; chapterMap["u7"] = ""
        let pages: [String?] = [nil, "u0", "u3", "u5", "unknown-unit", "outside"]
        for mask in 0..<(1 << jobs.count) {
            let completed = Set(jobs.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element.id })
            for runningMask in [0, 1, 8, 128, 170] {
                let running = Set(jobs.enumerated().compactMap { runningMask & (1 << $0.offset) == 0 ? nil : $0.element.id })
                for page in pages {
                    for dispatch in [0, 3] {
                        let expected = priorScheduler(in: jobs, completed: completed, running: running, steps: actions,
                            chapters: chapterMap, currentUnitID: page, dispatchCount: dispatch)
                        let actual = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: completed, running: running, steps: actions,
                            chapters: chapterMap, currentUnitID: page, dispatchCount: dispatch)
                        XCTAssertEqual(actual?.id, expected?.id, "完成mask=\(mask)，运行mask=\(runningMask)，当前页=\(page ?? "nil")，调度=\(dispatch)")
                    }
                }
            }
        }
    }

    /// Keep the pre-optimization algorithm as a behavioral oracle, including
    /// unknown/empty chapter treatment and every-fourth-dispatch fairness.
    private func priorScheduler(in chunks: [ReadingAnalysisChunk], completed: Set<String>, running: Set<String>,
                                steps: [ReadingExecutionStep], chapters: [String: String],
                                currentUnitID: String?, dispatchCount: Int) -> ReadingAnalysisChunk? {
        let frequencies = Dictionary(steps.map { ($0.id, $0.frequency) }, uniquingKeysWith: { _, last in last })
        let ready = chunks.enumerated().filter { index, chunk in
            guard !completed.contains(chunk.id), !running.contains(chunk.id) else { return false }
            let actions = chunk.stepIDs.compactMap { frequencies[$0] }
            let prior = chunks.prefix(index)
            if actions.contains(.book) && prior.contains(where: { !completed.contains($0.id) }) { return false }
            if actions.contains(.chapter) {
                let own = Set(chunk.unitIDs.compactMap { chapters[$0] })
                if prior.contains(where: { candidate in
                    !completed.contains(candidate.id) && candidate.unitIDs.contains { own.contains(chapters[$0] ?? "") }
                }) { return false }
            }
            return true
        }
        guard let oldest = ready.first else { return nil }
        if dispatchCount % 4 == 3 { return oldest.element }
        guard let currentUnitID, let target = chunks.firstIndex(where: { $0.unitIDs.contains(currentUnitID) }) else { return oldest.element }
        return ready.min { left, right in
            let a = abs(left.offset - target), b = abs(right.offset - target)
            if a != b { return a < b }
            if (left.offset >= target) != (right.offset >= target) { return left.offset >= target }
            return left.offset < right.offset
        }?.element
    }
}
