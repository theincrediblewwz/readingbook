import Foundation

/// Ending a run must be visible before its asynchronous cleanup is scheduled.
/// No deinit side effect: callers that keep using the legacy API stay explicit.
public final class AIRequestRun: @unchecked Sendable {
    fileprivate let id = UUID()
    private let lock = NSLock()
    private var finished = false
    public func finish() { lock.lock(); defer { lock.unlock() }; finished = true }
    fileprivate var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

/// One user-authorized budget shared by all lanes. Reserving the next request's
/// upper bound prevents parallel workers from spending the same remaining tokens.
public actor AIRequestCoordinator {
    public enum Lane: Equatable, Sendable { case foreground, background }
    private struct Permit { var id: UUID; var number: Int }
    private struct Waiter {
        var id: UUID
        var lane: Lane
        var reservation: Int
        var continuation: CheckedContinuation<Permit, Error>
    }
    private var users = 0
    private var runs: [UUID: AIRequestRun] = [:]
    private var limit = 2
    private var requestLimit = 100
    private var tokenLimit = 196_000
    private var usedRequests = 0
    private var usedTokens = 0
    private var active: [UUID: (Lane, Int)] = [:]
    private var waiting: [Waiter] = []
    private var transport: (@Sendable (ProviderClient.Prepared) async throws -> ProviderClient.Result)?
    public init() {}
    init(transport: @escaping @Sendable (ProviderClient.Prepared) async throws -> ProviderClient.Result) { self.transport = transport }

    public func beginRun(settings: ProviderSettings, maximumConcurrency: Int) throws {
        try prepareRun(settings: settings, maximumConcurrency: maximumConcurrency)
        users += 1; drain()
    }
    public func beginManagedRun(settings: ProviderSettings, maximumConcurrency: Int) throws -> AIRequestRun {
        try prepareRun(settings: settings, maximumConcurrency: maximumConcurrency)
        let run = AIRequestRun(); runs[run.id] = run; drain(); return run
    }
    private func prepareRun(settings: ProviderSettings, maximumConcurrency: Int) throws {
        runs = runs.filter { !$0.value.isFinished }
        if users == 0 && runs.isEmpty && active.isEmpty && waiting.isEmpty {
            let budget = try ReadingTokenBudget.operationLimit(for: settings)
            usedRequests = 0; usedTokens = 0
            requestLimit = settings.maxRequestsPerRun
            tokenLimit = budget
        }
        limit = min(5, max(1, maximumConcurrency))
    }
    public func endRun() { users = max(0, users - 1) }
    public func endRun(_ run: AIRequestRun) { run.finish(); runs.removeValue(forKey: run.id) }
    public var requestsUsed: Int { usedRequests }
    public func configure(maximumConcurrency: Int) { limit = min(5, max(1, maximumConcurrency)); drain() }
    var queuedRequestCount: Int { waiting.count }

    func perform(_ prepared: ProviderClient.Prepared, lane: Lane,
                 progress: (@Sendable (ProviderStreamSnapshot) -> Void)?, onStart: @Sendable (Int) -> Void) async throws -> ProviderClient.Result {
        let body = prepared.request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let output = (body?["max_completion_tokens"] as? Int) ?? (body?["max_tokens"] as? Int) ?? 6000
        let reservation = prepared.estimatedInputTokens + output
        let id = UUID()
        let permit = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiter(id: id, lane: lane, reservation: reservation, continuation: continuation)); drain()
            }
        }, onCancel: { Task { await self.cancel(id) } })
        var beganTransport = false
        do {
            try Task.checkCancellation()
            onStart(permit.number)
            try Task.checkCancellation()
            beganTransport = true
            let result: ProviderClient.Result
            if let transport { result = try await transport(prepared) }
            else { result = try await ProviderClient.perform(prepared, progress: progress) }
            release(permit.id, cost: max(0, result.tokenCost))
            return result
        } catch {
            // Before transport there can be no provider usage. Once entered,
            // retain the reservation unless actual usage was reported: a
            // provider may still bill a failed or cancelled transmission.
            release(permit.id, cost: beganTransport ? reservation : 0)
            throw error
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }
    private func release(_ id: UUID, cost: Int) {
        guard active.removeValue(forKey: id) != nil else { return }
        // Usage is provider-controlled, and parallel responses may each report
        // Int.max. Saturate before the next admission rather than overflowing
        // ahead of the individual reader's token-budget validation.
        let total = usedTokens.addingReportingOverflow(max(0, cost))
        usedTokens = total.overflow ? Int.max : total.partialValue
        drain()
    }
    private func drain() {
        while !waiting.isEmpty && active.count < limit {
            let backgroundCount = active.values.filter { $0.0 == .background }.count
            // Keep one lane available to a reader's question when cap > 1.
            let index = waiting.firstIndex(where: { $0.lane == .foreground }) ??
                waiting.firstIndex(where: { $0.lane == .background && backgroundCount < max(1, limit - 1) })
            guard let index else { return }
            let item = waiting.remove(at: index)
            let reserved = active.values.reduce(0) { $0 + $1.1 }
            guard usedRequests < requestLimit, item.reservation <= tokenLimit - usedTokens else {
                item.continuation.resume(throwing: ReadingWorkflowBudgetPause(message: "本轮共享请求或用量预算已到上限，已保存结果保留。")); continue
            }
            if item.reservation > tokenLimit - usedTokens - reserved { waiting.insert(item, at: index); return }
            usedRequests += 1; active[item.id] = (item.lane, item.reservation)
            item.continuation.resume(returning: Permit(id: item.id, number: usedRequests))
        }
    }
}
