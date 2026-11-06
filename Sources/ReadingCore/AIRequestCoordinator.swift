import Foundation

/// A user-started task, not the lifetime of a book or conversation. Finishing
/// is synchronous so delayed progress cleanup cannot keep a dead task alive.
public final class AIRequestRun: @unchecked Sendable {
    fileprivate let id = UUID()
    fileprivate let independentBudget: Bool
    private let lock = NSLock()
    private var finished = false
    fileprivate init(independentBudget: Bool = false) { self.independentBudget = independentBudget }
    public func finish() { lock.lock(); defer { lock.unlock() }; finished = true }
    fileprivate var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

/// Concurrency and foreground priority are global. Independent reader actions
/// have separate budgets; workers in one analysis can retain a shared budget.
public actor AIRequestCoordinator {
    public enum Lane: Equatable, Sendable { case foreground, background }
    private struct Budget {
        var requestLimit: Int
        var tokenLimit: Int
        var usedRequests = 0
        var usedTokens = 0
        init(settings: ProviderSettings) throws {
            tokenLimit = try ReadingTokenBudget.operationLimit(for: settings)
            requestLimit = settings.maxRequestsPerRun
        }
    }
    private struct Permit { var id: UUID; var number: Int }
    private struct Active { var lane: Lane; var reservation: Int; var budgetID: UUID? }
    private struct Waiter {
        var id: UUID
        var lane: Lane
        var reservation: Int
        var run: AIRequestRun?
        var continuation: CheckedContinuation<Permit, Error>
        var budgetID: UUID? { run?.independentBudget == true ? run?.id : nil }
    }
    private var users = 0
    private var runs: [UUID: AIRequestRun] = [:]
    private var limit = 2
    private var serial = 0
    private var sharedBudget: Budget? = try? Budget(settings: ProviderSettings())
    private var independentBudgets: [UUID: Budget] = [:]
    private var active: [UUID: Active] = [:]
    private var waiting: [Waiter] = []
    private var transport: (@Sendable (ProviderClient.Prepared) async throws -> ProviderClient.Result)?
    public init() {}
    init(transport: @escaping @Sendable (ProviderClient.Prepared) async throws -> ProviderClient.Result) { self.transport = transport }

    public func beginRun(settings: ProviderSettings, maximumConcurrency: Int) throws {
        try prepareRun(settings: settings, maximumConcurrency: maximumConcurrency)
        users += 1; drain()
    }
    public func beginManagedRun(settings: ProviderSettings, maximumConcurrency: Int, independentBudget: Bool = false) throws -> AIRequestRun {
        let budget = try Budget(settings: settings)
        try prepareRun(settings: settings, maximumConcurrency: maximumConcurrency)
        let run = AIRequestRun(independentBudget: independentBudget)
        runs[run.id] = run
        if independentBudget { independentBudgets[run.id] = budget }
        drain(); return run
    }
    private func prepareRun(settings: ProviderSettings, maximumConcurrency: Int) throws {
        let budget = try Budget(settings: settings)
        reapFinishedRuns()
        if users == 0 && runs.isEmpty && active.isEmpty && waiting.isEmpty {
            sharedBudget = budget; serial = 0
        }
        limit = min(5, max(1, maximumConcurrency))
    }
    private func reapFinishedRuns() {
        runs = runs.filter { !$0.value.isFinished }
        let held = Set(active.values.compactMap(\.budgetID) + waiting.compactMap(\.budgetID))
        independentBudgets = independentBudgets.filter { runs[$0.key] != nil || held.contains($0.key) }
    }
    public func endRun() { users = max(0, users - 1); drain() }
    public func endRun(_ run: AIRequestRun) {
        run.finish(); runs.removeValue(forKey: run.id)
        let cancelled = waiting.filter { $0.run?.id == run.id }
        waiting.removeAll { $0.run?.id == run.id }
        for item in cancelled { item.continuation.resume(throwing: CancellationError()) }
        drain(); reapFinishedRuns()
    }
    public var requestsUsed: Int { serial }
    public func configure(maximumConcurrency: Int) { limit = min(5, max(1, maximumConcurrency)); drain() }
    var queuedRequestCount: Int { waiting.count }

    func perform(_ prepared: ProviderClient.Prepared, lane: Lane, run: AIRequestRun? = nil,
                 progress: (@Sendable (ProviderStreamSnapshot) -> Void)?, onStart: @Sendable (Int) -> Void) async throws -> ProviderClient.Result {
        if let run { guard !run.isFinished, runs[run.id] === run else { throw CancellationError() } }
        let body = prepared.request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let output = (body?["max_completion_tokens"] as? Int) ?? (body?["max_tokens"] as? Int) ?? 6000
        let sum = prepared.estimatedInputTokens.addingReportingOverflow(output)
        guard !sum.overflow, prepared.estimatedInputTokens >= 0, output >= 0 else { throw ReadingError.invalid("模型请求用量估算无效。") }
        let reservation = sum.partialValue
        let id = UUID()
        let permit = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiter(id: id, lane: lane, reservation: reservation, run: run, continuation: continuation)); drain()
            }
        }, onCancel: { Task { await self.cancel(id) } })
        var beganTransport = false
        do {
            try Task.checkCancellation()
            if let run, run.isFinished { throw CancellationError() }
            onStart(permit.number)
            try Task.checkCancellation()
            beganTransport = true
            let result: ProviderClient.Result
            if let transport { result = try await transport(prepared) }
            else { result = try await ProviderClient.perform(prepared, progress: progress) }
            release(permit.id, cost: max(0, result.tokenCost))
            return result
        } catch {
            // Once transport starts, unknown usage retains the reservation.
            release(permit.id, cost: beganTransport ? reservation : 0)
            throw error
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        drain(); reapFinishedRuns()
    }
    private func budget(_ id: UUID?) -> Budget? { id.flatMap { independentBudgets[$0] } ?? (id == nil ? sharedBudget : nil) }
    private func setBudget(_ value: Budget, for id: UUID?) {
        if let id { independentBudgets[id] = value } else { sharedBudget = value }
    }
    private func release(_ id: UUID, cost: Int) {
        guard let permit = active.removeValue(forKey: id), var value = budget(permit.budgetID) else { return }
        let total = value.usedTokens.addingReportingOverflow(max(0, cost))
        value.usedTokens = total.overflow ? Int.max : total.partialValue
        setBudget(value, for: permit.budgetID)
        drain(); reapFinishedRuns()
    }
    private func drain() {
        while !waiting.isEmpty && active.count < limit {
            let backgroundCount = active.values.filter { $0.lane == .background }.count
            let order = waiting.indices.filter { waiting[$0].lane == .foreground } + waiting.indices.filter {
                waiting[$0].lane == .background && backgroundCount < max(1, limit - 1)
            }
            var blockedBudgets = Set<UUID?>()
            var admitted = false
            for index in order {
                let item = waiting[index]
                if let run = item.run, run.isFinished || runs[run.id] !== run {
                    waiting.remove(at: index).continuation.resume(throwing: CancellationError())
                    admitted = true; break
                }
                if blockedBudgets.contains(item.budgetID) { continue }
                guard var value = budget(item.budgetID), value.usedRequests < value.requestLimit,
                      item.reservation <= value.tokenLimit - value.usedTokens else {
                    waiting.remove(at: index).continuation.resume(throwing: ReadingWorkflowBudgetPause(message: "这次任务的模型请求或用量额度已用完，已有结果保留；新的提问会重新计数。"))
                    admitted = true; break
                }
                let reserved = active.values.filter { $0.budgetID == item.budgetID }.reduce(0) { $0 + $1.reservation }
                if item.reservation > value.tokenLimit - value.usedTokens - reserved {
                    // Preserve FIFO within one budget, but a blocked analysis
                    // must not prevent an independent question from starting.
                    blockedBudgets.insert(item.budgetID); continue
                }
                waiting.remove(at: index)
                value.usedRequests += 1; setBudget(value, for: item.budgetID)
                serial += 1; active[item.id] = Active(lane: item.lane, reservation: item.reservation, budgetID: item.budgetID)
                item.continuation.resume(returning: Permit(id: item.id, number: item.run?.independentBudget == true ? value.usedRequests : serial))
                admitted = true; break
            }
            if !admitted { return }
        }
    }
}
