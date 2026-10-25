import Foundation
import ReadingCore

private struct ReadingChunkResult: Sendable {
    var chunk: ReadingAnalysisChunk
    var base: BookProject
    var result: BookProject?
    var hasPublishedCompletion = false
    var failure: String? = nil
    var cancelled = false
    var conflict = false
}

private final class ReadingPublicationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var saved = false
    func record(_ complete: Bool) { lock.lock(); defer { lock.unlock() }; saved = saved || complete }
    var isSaved: Bool { lock.lock(); defer { lock.unlock() }; return saved }
}

@MainActor extension AppStore {
    /// Separate readers own their own contexts and cancellation state. Only the
    /// repository actor commits, always rebasing on the latest persisted book.
    func runConfiguredReading(bookID: String, sessionID: String, allowedUnitIDs: Set<String>,
                              settings: ProviderSettings, apiKey: String, progressID: UUID) async throws {
        guard let initial = book, let configuration = initial.smartReading?.selection.execution else { return }
        let chunkTask = Task.detached(priority: .utility) { try SmartReadingRuntime.analysisChunks(in: initial, allowedUnitIDs: allowedUnitIDs) }
        let chunks = try await withTaskCancellationHandler(operation: { try await chunkTask.value }, onCancel: { chunkTask.cancel() })
        let chapters = Dictionary(uniqueKeysWithValues: initial.units.map { ($0.id, $0.chapter) })
        let limit = configuration.precision == .close ? 1 : max(1, aiConcurrencyLimit - 1)
        var running = Set<String>(), retries: [String: Int] = [:]
        var dispatchedCount = 0
        try await withThrowingTaskGroup(of: ReadingChunkResult.self) { group in
            while true {
                try Task.checkCancellation()
                guard let latest = book, latest.id == bookID, latest.smartReading?.id == sessionID else { throw CancellationError() }
                let checkpoints = Dictionary((latest.smartReading?.analysisCheckpoints ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                let complete = Set(chunks.filter { chunk in
                    guard let checkpoint = checkpoints[chunk.id] else { return false }
                    return checkpoint.unitIDs == chunk.unitIDs && checkpoint.configurationHash == chunk.configurationHash &&
                        Set(checkpoint.completedStepIDs) == Set(chunk.stepIDs) && chunk.unitIDs.allSatisfy { checkpoint.unitHashes[$0] == latest.smartReading?.unitHashes[$0] }
                }.map(\.id))
                // Begin with one identity writer for a new book, then fan out.
                let capacity = complete.isEmpty && latest.entities.isEmpty ? 1 : limit
                while running.count < capacity, let chunk = ReadingAnalysisScheduler.nextReadyChunk(in: chunks, completed: complete, running: running,
                    steps: configuration.steps, chapters: chapters, currentUnitID: selectedUnitID, dispatchCount: dispatchedCount) {
                    let worker = AIReader(coordinator: sharedAIRequests)
                    let handler = workerProgressHandler(progressID)
                    let publisher = readingPublicationHandler(bookID: bookID, sessionID: sessionID, progressID: progressID)
                    let publication = ReadingPublicationCompletion()
                    let base = latest, priorityUnitID = selectedUnitID
                    running.insert(chunk.id); dispatchedCount += 1
                    group.addTask {
                        await worker.setProgressHandler(handler)
                        await worker.setPublicationHandler { batch in
                            try await publisher(batch)
                            publication.record(batch.isAnalysisComplete)
                        }
                        do {
                            let result = try await worker.readChunk(project: base, chunk: chunk, settings: settings, apiKey: apiKey, priorityUnitID: priorityUnitID)
                            return ReadingChunkResult(chunk: chunk, base: base, result: result, hasPublishedCompletion: publication.isSaved)
                        } catch {
                            let message = String(error.localizedDescription.prefix(2000))
                            return ReadingChunkResult(chunk: chunk, base: base, result: nil, failure: message,
                                cancelled: Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled,
                                conflict: message.contains("另一条任务") || message.contains("并行保存"))
                        }
                    }
                }
                if running.isEmpty {
                    guard complete.count == chunks.count else { throw ReadingError.invalid("阅读步骤的先后关系尚未满足，已保存结果保留。") }
                    break
                }
                updateAIProgressDetail(progressID, detail: "已完成 \(complete.count)/\(chunks.count) 部分 · \(running.count) 条分析线")
                guard let finished = try await group.next() else { break }
                running.remove(finished.chunk.id)
                try Task.checkCancellation()
                if let failure = finished.failure {
                    if finished.cancelled { throw CancellationError() }
                    if finished.conflict, retries[finished.chunk.id, default: 0] < 1 {
                        retries[finished.chunk.id, default: 0] += 1; continue
                    }
                    throw ReadingError.invalid(failure)
                }
                guard let result = finished.result else { throw ReadingError.invalid("本部分没有返回有效结果，已保存内容保留。") }
                do {
                    // A terminal response batch is already persisted and shown.
                    // Reapplying its full, older worker snapshot can conflict
                    // with a newer worker's valid changes to the same object.
                    // Exact receipt batches still use their original caller commit.
                    if !finished.hasPublishedCompletion {
                        let committed = try await repository.commitAIResult(base: finished.base, result: result, operationID: UUID().uuidString, expectedReadingSessionID: sessionID)
                        publish(committed)
                    }
                    requestsUsed = await sharedAIRequests.requestsUsed
                    activeReadingUnitID = finished.chunk.unitIDs.first
                } catch {
                    // One bounded retry reads the just-committed state, so local
                    // identities/facts are reused instead of overwriting them.
                    if error.localizedDescription.contains("另一条任务") || error.localizedDescription.contains("并行保存") {
                        let attempts = retries[finished.chunk.id, default: 0]
                        if attempts < 1 { retries[finished.chunk.id] = attempts + 1; continue }
                    }
                    throw error
                }
            }
        }
    }

    func readingPublicationHandler(bookID: String, sessionID: String, progressID: UUID) -> AIReadingPublicationHandler {
        let owner = repository, root = libraryRootURL
        return { [weak self] publication in
            let saved = try await owner.commitAIResult(base: publication.before, result: publication.after,
                operationID: publication.operationID, expectedReadingSessionID: sessionID)
            await self?.publishReadingBatch(saved, root: root, bookID: bookID, sessionID: sessionID, firstUnitID: publication.unitIDs.first)
        }
    }

    private func publishReadingBatch(_ saved: BookProject, root: URL, bookID: String, sessionID: String, firstUnitID: String?) {
        guard libraryRootURL == root, self.bookID == bookID, book?.smartReading?.id == sessionID else { return }
        publish(saved); activeReadingUnitID = firstUnitID
    }
}
