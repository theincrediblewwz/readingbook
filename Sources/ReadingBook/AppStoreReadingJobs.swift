import Foundation
import ReadingCore

private struct ReadingChunkResult: Sendable {
    var chunk: ReadingAnalysisChunk
    var base: BookProject
    var result: BookProject
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
        let steps = Dictionary(uniqueKeysWithValues: configuration.steps.map { ($0.id, $0) })
        let limit = configuration.precision == .close ? 1 : max(1, aiConcurrencyLimit - 1)
        var running = Set<String>(), retries: [String: Int] = [:]
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
                let pending = chunks.enumerated().filter { !complete.contains($0.element.id) && !running.contains($0.element.id) }
                // Establish reusable identities before fanning out a new book.
                let capacity = complete.isEmpty && latest.entities.isEmpty ? 1 : limit
                for (index, chunk) in pending where running.count < capacity {
                    let frequencies = chunk.stepIDs.compactMap { steps[$0]?.frequency }
                    let prior = chunks.prefix(index)
                    if frequencies.contains(.book) && prior.contains(where: { !complete.contains($0.id) }) { continue }
                    if frequencies.contains(.chapter) {
                        let ownChapters = Set(chunk.unitIDs.compactMap { chapters[$0] })
                        if prior.contains(where: { candidate in
                            !complete.contains(candidate.id) && candidate.unitIDs.contains(where: { ownChapters.contains(chapters[$0] ?? "") })
                        }) { continue }
                    }
                    let worker = AIReader(coordinator: sharedAIRequests)
                    let handler = workerProgressHandler(progressID)
                    let base = latest
                    running.insert(chunk.id)
                    group.addTask {
                        await worker.setProgressHandler(handler)
                        let result = try await worker.readChunk(project: base, chunk: chunk, settings: settings, apiKey: apiKey)
                        return ReadingChunkResult(chunk: chunk, base: base, result: result)
                    }
                }
                if running.isEmpty {
                    guard complete.count == chunks.count else { throw ReadingError.invalid("阅读步骤的先后关系尚未满足，已保存结果保留。") }
                    break
                }
                updateAIProgressDetail(progressID, detail: "已保存 \(complete.count)/\(chunks.count) 部分 · \(running.count) 条分析线")
                guard let finished = try await group.next() else { break }
                running.remove(finished.chunk.id)
                try Task.checkCancellation()
                do {
                    let committed = try await repository.commitAIResult(base: finished.base, result: finished.result, operationID: UUID().uuidString)
                    publish(committed)
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
}
