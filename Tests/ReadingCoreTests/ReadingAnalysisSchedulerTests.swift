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
}
