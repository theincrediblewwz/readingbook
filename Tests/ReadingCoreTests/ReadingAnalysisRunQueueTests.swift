import Foundation
import XCTest
@testable import ReadingCore

final class ReadingAnalysisRunQueueTests: XCTestCase {
    private var chunks: [ReadingAnalysisChunk] {
        (0..<8).map { ReadingAnalysisChunk(id: "c\($0)", title: "第\($0 + 1)页", unitIDs: ["u\($0)"], configurationHash: "same", stepIDs: ["part"]) }
    }
    private var steps: [ReadingExecutionStep] {
        [ReadingExecutionStep(id: "part", title: "理解"), ReadingExecutionStep(id: "chapter", title: "章末", frequency: .chapter),
         ReadingExecutionStep(id: "book", title: "书末", frequency: .book)]
    }
    private var chapters: [String: String] { Dictionary(uniqueKeysWithValues: (0..<8).map { ("u\($0)", $0 < 4 ? "一" : "二") }) }

    func testExactChapterBarriersStayIndependentWhenOneUnitContainsSeveralChapters() throws {
        var jobs = (0..<4).map { ReadingAnalysisChunk(id: "slice-\($0)", title: "片段", unitIDs: ["u"], configurationHash: "same", stepIDs: $0 % 2 == 0 ? ["part"] : ["chapter"]) }
        for index in jobs.indices { jobs[index].chapterID = index < 2 ? "chapter-a" : "chapter-b" }
        let legacyLabels = ["u": "整本书"]
        var queue = try ReadingAnalysisRunQueue(chunks: jobs, steps: steps, chapters: legacyLabels, completed: [])
        XCTAssertEqual(queue.next(currentUnitID: nil)?.id, "slice-0")
        XCTAssertTrue(queue.begin("slice-0"))
        XCTAssertEqual(queue.next(currentUnitID: nil)?.id, "slice-2", "另一章普通分析不被旧书名屏障阻塞。")
        XCTAssertFalse(queue.begin("slice-1"), "当前章末仍等待本章前序片段。")
        queue.markComplete("slice-0"); queue.finish("slice-0")
        XCTAssertEqual(queue.next(currentUnitID: nil)?.id, "slice-1")
        XCTAssertEqual(queue.next(currentUnitID: nil)?.id, ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: ["slice-0"], running: [], steps: steps, chapters: legacyLabels, currentUnitID: nil, dispatchCount: queue.dispatchCount)?.id)
    }

    func testRunIndexMatchesStatelessOracleAcrossMixedCanonicalStates() throws {
        var jobs = chunks
        jobs[1].stepIDs = ["part", "chapter"]; jobs[2].unitIDs = ["u2", "u5"]; jobs[2].stepIDs = ["chapter"]
        jobs[4].stepIDs = ["book"]; jobs[6].stepIDs = ["chapter", "book"]
        jobs[7].unitIDs = ["u7", "unknown-unit"]; jobs[7].stepIDs = ["chapter"]
        var chapterMap = chapters; chapterMap["u7"] = ""
        let pages: [String?] = [nil, "u0", "u3", "u5", "unknown-unit", "outside"]
        for mask in 0..<(1 << jobs.count) {
            let completed = Set(jobs.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element.id })
            for runningMask in [0, 1, 8, 128, 170] {
                let running = Set(jobs.enumerated().compactMap { runningMask & (1 << $0.offset) == 0 ? nil : $0.element.id })
                for dispatch in [0, 3] {
                    let queue = try ReadingAnalysisRunQueue(chunks: jobs, steps: steps, chapters: chapterMap,
                        completed: completed, running: running, dispatchCount: dispatch)
                    for page in pages {
                        let expected = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: completed, running: running,
                            steps: steps, chapters: chapterMap, currentUnitID: page, dispatchCount: dispatch)
                        XCTAssertEqual(queue.next(currentUnitID: page)?.id, expected?.id)
                    }
                }
            }
        }
    }

    func testOutOfOrderCompletionReceiptRequeuesAndMovingCursorPreserveFairness() throws {
        var jobs = chunks; jobs[3].stepIDs.append("chapter"); jobs[7].stepIDs.append("book")
        var queue = try ReadingAnalysisRunQueue(chunks: jobs, steps: steps, chapters: chapters, completed: [])
        var completed = Set<String>(), running = Set<String>(), attempts: [String: Int] = [:]
        for turn in 0..<100 {
            let cursor = "u\((turn * 5) % jobs.count)"
            for page in [nil, cursor, "outside"] {
                let expected = ReadingAnalysisScheduler.nextReadyChunk(in: jobs, completed: completed, running: running,
                    steps: steps, chapters: chapters, currentUnitID: page, dispatchCount: queue.dispatchCount)
                XCTAssertEqual(queue.next(currentUnitID: page)?.id, expected?.id)
            }
            if running.count < 3, let next = queue.next(currentUnitID: cursor) {
                XCTAssertTrue(queue.begin(next.id)); running.insert(next.id); attempts[next.id, default: 0] += 1
                XCTAssertFalse(queue.begin(next.id), "同一任务不能重复占用分析线")
            }
            if turn % 2 == 1 || queue.next(currentUnitID: cursor) == nil,
               let finished = turn % 4 == 1 ? running.sorted().last : running.sorted().first {
                if attempts[finished, default: 0] >= 2 || turn > 50 {
                    let slots = queue.runningCount
                    queue.markComplete(finished); completed.insert(finished)
                    queue.markComplete(finished)
                    XCTAssertEqual(queue.runningCount, slots, "终结落盘不提前释放仍运行的任务槽")
                }
                // The first success is receipt-only (or one bounded retry),
                // never evidence that a chapter/book dependency is complete.
                queue.finish(finished); running.remove(finished)
            }
            XCTAssertEqual(queue.completedCount, completed.count)
            XCTAssertEqual(queue.runningCount, running.count)
            if completed.count == jobs.count && running.isEmpty { break }
        }
        XCTAssertEqual(completed.count, jobs.count)
        XCTAssertNil(queue.next(currentUnitID: "u7"))
    }

    func testReceiptAndPartialProgressCannotReleaseReviewDependencies() throws {
        var jobs = chunks; jobs[3].stepIDs = ["chapter"]; jobs[7].stepIDs = ["book"]
        var queue = try ReadingAnalysisRunQueue(chunks: jobs, steps: steps, chapters: chapters, completed: ["c1", "c2", "c4", "c5", "c6"])
        XCTAssertEqual(queue.next(currentUnitID: "u3")?.id, "c0")
        XCTAssertTrue(queue.begin("c0")); queue.finish("c0")
        XCTAssertEqual(queue.next(currentUnitID: "u3")?.id, "c0", "回执成功后仍补同一块，章末不提前运行")
        queue.markComplete("c0")
        XCTAssertEqual(queue.next(currentUnitID: "u7")?.id, "c3")
        XCTAssertTrue(queue.begin("c3"))
        XCTAssertNil(queue.next(currentUnitID: "u7"), "运行中的章末仍算未完成依赖")
        queue.markComplete("c3")
        XCTAssertEqual(queue.next(currentUnitID: "u7")?.id, "c7")
    }

    func testEmptyQueueDuplicateIdentityAndLargeReadyIndexEdges() throws {
        let empty = try ReadingAnalysisRunQueue(chunks: [], steps: [], chapters: [:], completed: [])
        XCTAssertNil(empty.next(currentUnitID: nil)); XCTAssertEqual(empty.completedCount, 0)
        XCTAssertThrowsError(try ReadingAnalysisRunQueue(chunks: [chunks[0], chunks[0]], steps: steps, chapters: chapters, completed: []))
        let jobs = (0..<4097).map { ReadingAnalysisChunk(id: "c\($0)", title: "", unitIDs: ["u\($0)"], configurationHash: "same", stepIDs: []) }
        var queue = try ReadingAnalysisRunQueue(chunks: jobs, steps: [], chapters: [:], completed: [])
        XCTAssertEqual(queue.next(currentUnitID: "u4096")?.id, "c4096")
        XCTAssertTrue(queue.begin("c4096")); queue.markComplete("c4096"); queue.finish("c4096")
        XCTAssertEqual(queue.next(currentUnitID: "u4096")?.id, "c4095")
        XCTAssertTrue(queue.begin("c1")); XCTAssertTrue(queue.begin("c2"))
        XCTAssertEqual(queue.next(currentUnitID: "u4096")?.id, "c0", "第四次派发保留最早任务的公平性")
    }

    private func project() throws -> BookProject {
        let configuration = ReadingExecutionConfiguration(granularity: .page,
            steps: [ReadingExecutionStep(id: "part", title: "理解")])
        var book = BookProject(title: "原书", originalName: "book.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            SourceUnit(id: "u0", order: 0, chapter: "第一章", page: 1, text: "贾诩来到城中。"),
            SourceUnit(id: "u1", order: 1, chapter: "第二章", page: 2, text: "二人继续向前。")
        ])
        PluginEngine.seed(&book); book.plan = ReadingPlan(methodIDs: ["genre.history"])
        book.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: configuration), in: book, currentUnitID: "u0")
        return book
    }
    private func checkpoint(_ chunk: ReadingAnalysisChunk, in project: BookProject) -> ReadingAnalysisCheckpoint {
        ReadingAnalysisCheckpoint(id: chunk.id, unitIDs: chunk.unitIDs,
            unitHashes: project.smartReading!.unitHashes.filter { chunk.unitIDs.contains($0.key) }, configurationHash: chunk.configurationHash,
            completedStepIDs: chunk.stepIDs, markdown: "这部分讲人物相遇。",
            evidence: chunk.unitIDs.map { id in Evidence(unitID: id, quote: project.units.first { $0.id == id }!.text) }, updatedAt: Date())
    }

    func testCanonicalKnowledgeAndPartialProductsDoNotFreezeTheInitialBookOrCompleteTheChunk() throws {
        var book = try project()
        let catalog = try ReadingAnalysisRunCatalog(in: book, allowedUnitIDs: ["u0", "u1"])
        book.chats.append(ChatMessage(role: "assistant", content: "另一条对话已经保存。"))
        book.entities.append(KnowledgeEntity(id: "jia", typeID: "person", name: "贾诩", summary: "人物的新介绍。"))
        let partial = try catalog.reconcile(in: book, previouslyCompleted: [], running: [catalog.chunks[0].id], dispatchCount: 1)
        XCTAssertTrue(partial.completedIDs.isEmpty); XCTAssertNil(partial.replacementQueue)
        let completed = checkpoint(catalog.chunks[0], in: book)
        book.smartReading?.analysisCheckpoints = [completed]
        let terminal = try catalog.reconcile(in: book, previouslyCompleted: [], running: [catalog.chunks[0].id], dispatchCount: 1)
        XCTAssertEqual(terminal.newlyCompletedIDs, [catalog.chunks[0].id])
        XCTAssertEqual(book.entities.first?.summary, "人物的新介绍。")
        XCTAssertEqual(book.chats.last?.content, "另一条对话已经保存。")
    }

    func testSameCountCheckpointReplacementRebuildsAndDoesNotTrustTerminalFlagOrStamp() throws {
        var book = try project()
        book.publicationStamp = LibraryPublicationStamp(owner: UUID(), ordinal: 7)
        let stamp = book.publicationStamp
        let catalog = try ReadingAnalysisRunCatalog(in: book, allowedUnitIDs: ["u0", "u1"])
        let first = catalog.chunks[0], second = catalog.chunks[1]
        let firstCheckpoint = checkpoint(first, in: book)
        book.smartReading?.analysisCheckpoints = [firstCheckpoint]
        let before = try catalog.reconcile(in: book, previouslyCompleted: [], running: [], dispatchCount: 3)
        // Same count, different checkpoint: prefix/count/stamp shortcuts fail.
        let secondCheckpoint = checkpoint(second, in: book)
        book.smartReading?.analysisCheckpoints = [secondCheckpoint]
        let after = try catalog.reconcile(in: book, previouslyCompleted: before.completedIDs, running: [second.id], dispatchCount: 3)
        var replacement = try XCTUnwrap(after.replacementQueue)
        XCTAssertEqual(after.completedIDs, [second.id]); XCTAssertFalse(replacement.isComplete(first.id))
        XCTAssertEqual(replacement.dispatchCount, 3); XCTAssertEqual(replacement.runningCount, 1)
        XCTAssertEqual(replacement.next(currentUnitID: "u1")?.id, first.id)
        replacement.finish(second.id)
        XCTAssertEqual(replacement.completedCount, 1); XCTAssertEqual(replacement.runningCount, 0)
        XCTAssertEqual(book.publicationStamp, stamp)
        // Even ID, count and stamp all stay unchanged while completion becomes
        // invalid. A count/last-ID "append-only" shortcut would miss this.
        book.smartReading?.analysisCheckpoints?[0].completedStepIDs = []
        let edited = try catalog.reconcile(in: book, previouslyCompleted: after.completedIDs, running: [], dispatchCount: 3)
        XCTAssertTrue(edited.completedIDs.isEmpty); XCTAssertNotNil(edited.replacementQueue)
    }

    func testChangedSourceWorkLayoutAndSessionFailClosedButSchedulingKnobsStayCompatible() throws {
        let book = try project(), catalog = try ReadingAnalysisRunCatalog(in: book, allowedUnitIDs: ["u0", "u1"])
        var changed = book; changed.smartReading?.selection.execution?.maximumConcurrentRequests = 5
        changed.plan?.rationale = "重新解释调度原因。"
        XCTAssertNoThrow(try catalog.reconcile(in: changed, previouslyCompleted: [], running: [], dispatchCount: 0))
        changed = book; changed.units[0].text += "新字。"
        XCTAssertThrowsError(try catalog.reconcile(in: changed, previouslyCompleted: [], running: [], dispatchCount: 0))
        changed = book; changed.units[0].chapter = "另一个章节"
        XCTAssertThrowsError(try catalog.reconcile(in: changed, previouslyCompleted: [], running: [], dispatchCount: 0))
        changed = book; changed.plan?.focus = ["新的问题"]
        XCTAssertThrowsError(try catalog.reconcile(in: changed, previouslyCompleted: [], running: [], dispatchCount: 0))
        changed = book; changed.smartReading?.id = "another-session"
        XCTAssertThrowsError(try catalog.reconcile(in: changed, previouslyCompleted: [], running: [], dispatchCount: 0))

        var unicode = book; unicode.units[0].text = "Cafe\u{301}。"
        unicode.smartReading = try SmartReadingRuntime.freeze(book.smartReading!.selection, in: unicode, currentUnitID: "u0")
        unicode.publicationStamp = LibraryPublicationStamp(owner: UUID(), ordinal: 9)
        let unicodeCatalog = try ReadingAnalysisRunCatalog(in: unicode, allowedUnitIDs: ["u0", "u1"])
        changed = unicode; changed.units[0].text = "Caf\u{e9}。"
        XCTAssertEqual(changed.units[0].text, unicode.units[0].text)
        XCTAssertEqual(changed.publicationStamp, unicode.publicationStamp)
        XCTAssertThrowsError(try unicodeCatalog.reconcile(in: changed, previouslyCompleted: [], running: [], dispatchCount: 0), "相同String/stamp不能绕过原文原始字节哈希")
    }

    func testCancelledCanonicalPreparationDoesNotReturnAnAuthorityOrQueue() async throws {
        let book = try project(), catalog = try ReadingAnalysisRunCatalog(in: book, allowedUnitIDs: ["u0", "u1"])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try catalog.reconcile(in: book, previouslyCompleted: [], running: [], dispatchCount: 0)
        }
        do { _ = try await task.value; XCTFail("取消的核对不能交付队列") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
