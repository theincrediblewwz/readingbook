import Foundation
import ReadingCore

/// Window-owned ephemeral results; changing query/source/owner invalidates both
/// work and late completions. Stopping preserves completed batches for an
/// explicit Continue click, never automatically renews a request budget.
@MainActor final class WholeBookSearchSession: ObservableObject {
    @Published private(set) var plan: WholeBookSearchPlan?
    @Published private(set) var keywords: [String] = []
    @Published private(set) var understanding = false
    @Published private(set) var matches: [WholeBookSearchMatch] = []
    @Published private(set) var preparing = false
    @Published private(set) var running = false
    @Published private(set) var completedBatches = 0
    @Published private(set) var tokenCost = 0
    @Published private(set) var limited = false
    @Published private(set) var errorMessage = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?
    var complete: Bool { plan.map { completedBatches == $0.batches.count } ?? false }
    var completedUnits: Int { plan?.completedUnitCount(afterBatchCount: completedBatches) ?? 0 }

    func prepare(query: String, snapshot: LibrarySourceSnapshot, settings: ProviderSettings) {
        cancel(clear: true)
        let owner = generation
        preparing = true
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try WholeBookSearchPlan.prepare(query: query, snapshot: snapshot, settings: settings) }
            do {
                let plan = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == owner else { return }
                self.plan = plan; self.preparing = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == owner else { return }
                self.preparing = false; self.errorMessage = error.localizedDescription
            }
        }
    }

    func start(settings: ProviderSettings, apiKey: String, coordinator: AIRequestCoordinator, concurrency: Int, validate: (@MainActor () async throws -> Void)? = nil) {
        guard let plan, !preparing, !running, !complete else { return }
        let owner = generation, start = completedBatches
        errorMessage = ""; running = true
        task = Task { [weak self] in
            @MainActor func checkOwner() async throws {
                try Task.checkCancellation()
                guard let self, self.generation == owner else { throw CancellationError() }
                try await validate?()
                try Task.checkCancellation()
                guard self.generation == owner else { throw CancellationError() }
            }
            do {
                try await checkOwner()
                let run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: concurrency)
                defer { run.finish(); Task { await coordinator.endRun(run) } }
                try await checkOwner()
                let reader = AIReader(coordinator: coordinator, lane: .foreground)
                guard let self, self.generation == owner else { return }
                if self.keywords.isEmpty {
                    self.understanding = true
                    let intent = try await reader.prepareWholeBookSearchIntent(query: plan.query, languageProfile: plan.languageProfile, settings: settings, apiKey: apiKey)
                    guard !Task.isCancelled, self.generation == owner else { return }
                    try await checkOwner()
                    self.keywords = intent.keywords; self.tokenCost += intent.tokenCost; self.understanding = false
                }
                let keywords = self.keywords
                for batch in plan.batches.dropFirst(start) {
                    try await checkOwner()
                    let result = try await reader.searchWholeBookBatch(batch, keywords: keywords, settings: settings, apiKey: apiKey)
                    guard !Task.isCancelled, self.generation == owner else { return }
                    try await checkOwner()
                    var updated = self.matches, seen = Set(updated.map(\.id)), limited = self.limited || result.limited
                    for hit in result.matches where !seen.contains(hit.id) {
                        if updated.count < 300 { updated.append(hit); seen.insert(hit.id) }
                        else { limited = true }
                    }
                    self.matches = updated; self.limited = limited
                    self.tokenCost += result.tokenCost
                    self.completedBatches = batch.index + 1
                }
                guard self.generation == owner else { return }
                self.running = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == owner else { return }
                self.running = false; self.understanding = false; self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Cancel transport before a representable dismantles, without publishing
    /// ObservableObject changes inside the current SwiftUI update transaction.
    func invalidateWork() { generation = UUID(); task?.cancel(); task = nil }

    func cancel(clear: Bool = false) {
        invalidateWork(); running = false; preparing = false; understanding = false
        if clear { keywords = []; plan = nil; matches = []; completedBatches = 0; tokenCost = 0; limited = false; errorMessage = "" }
    }
}
