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
    @Published private(set) var activeBatchNumber = 0
    @Published private(set) var requestProgress: AIProgressEvent?
    private var generation = UUID()
    private var progressOperation = UUID()
    private var task: Task<Void, Never>?
    var complete: Bool { plan.map { completedBatches == $0.batches.count } ?? false }
    var completedUnits: Int { plan?.completedUnitCount(afterBatchCount: completedBatches) ?? 0 }
    var statusDescription: String {
        if preparing { return "正在准备本书原文…" }
        if understanding { return "AI 正在理解你的意思…" }
        if running {
            let batch = "第\(activeBatchNumber)/\(plan?.batches.count ?? 0)批"
            guard let progress = requestProgress else { return activeBatchNumber > 0 ? "正在准备\(batch)原文…" : "正在安排模型请求…" }
            switch progress.phase {
            case .waitingForResponse: return "\(batch)请求中 · 等待模型响应"
            case .reasoning: return "\(batch)模型思考中 · 已返回\(progress.reasoningCharacters ?? 0)字"
            case .answering: return "\(batch)正在返回结果 · \(progress.answerCharacters ?? 0)字"
            case .receiving, .receivingTools: return "\(batch)服务已响应 · 正在接收"
            case .requestCompleted: return "\(batch)已返回 · 正在核对原文"
            default: return "正在准备\(batch)请求…"
            }
        }
        if complete { return "AI 已查完可读原文 · \(matches.count)处" }
        if activeBatchNumber > 0 || !keywords.isEmpty { return "已暂停 · 完成\(completedBatches)/\(plan?.batches.count ?? 0)批" }
        return plan == nil ? "AI 阅读全文" : "先理解意图，再阅读全文"
    }

    private func observe(_ reader: AIReader, owner: UUID) async {
        let operation = UUID(); progressOperation = operation; requestProgress = nil
        await reader.setProgressHandler { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == owner, self.progressOperation == operation, self.running else { return }
                self.requestProgress = event
            }
        }
    }

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
                    await self.observe(reader, owner: owner)
                    let intent = try await reader.prepareWholeBookSearchIntent(query: plan.query, languageProfile: plan.languageProfile, settings: settings, apiKey: apiKey)
                    guard !Task.isCancelled, self.generation == owner else { return }
                    try await checkOwner()
                    self.keywords = intent.keywords; self.tokenCost += intent.tokenCost; self.understanding = false
                }
                let keywords = self.keywords
                for batch in plan.batches.dropFirst(start) {
                    try await checkOwner()
                    self.activeBatchNumber = batch.index + 1
                    await self.observe(reader, owner: owner)
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
        requestProgress = nil; progressOperation = UUID()
        if clear { keywords = []; plan = nil; matches = []; completedBatches = 0; tokenCost = 0; limited = false; errorMessage = ""; activeBatchNumber = 0 }
    }
}
