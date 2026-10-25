import Foundation

/// One user-authorized budget shared by all lanes. Reserving the next request's
/// upper bound prevents parallel workers from spending the same remaining tokens.
public actor AIRequestCoordinator {
    public enum Lane: Equatable, Sendable { case foreground, background }
    private struct Waiter {
        var id: UUID
        var lane: Lane
        var reservation: Int
        var continuation: CheckedContinuation<UUID, Error>
    }
    private var users = 0
    private var limit = 2
    private var requestLimit = 100
    private var tokenLimit = 196_000
    private var usedRequests = 0
    private var usedTokens = 0
    private var active: [UUID: (Lane, Int)] = [:]
    private var waiting: [Waiter] = []
    public init() {}

    public func beginRun(settings: ProviderSettings, maximumConcurrency: Int) throws {
        if users == 0 && active.isEmpty {
            usedRequests = 0; usedTokens = 0
            requestLimit = settings.maxRequestsPerRun
            tokenLimit = try ReadingTokenBudget.operationLimit(for: settings)
        }
        limit = min(5, max(1, maximumConcurrency))
        users += 1; drain()
    }
    public func endRun() { users = max(0, users - 1) }
    public var requestsUsed: Int { usedRequests }
    public func configure(maximumConcurrency: Int) { limit = min(5, max(1, maximumConcurrency)); drain() }

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
        do {
            try Task.checkCancellation()
            onStart(usedRequests)
            let result = try await ProviderClient.perform(prepared, progress: progress)
            release(permit, cost: max(0, result.tokenCost))
            return result
        } catch {
            // Providers may bill requests cancelled after transmission. Retain
            // the reservation if the transport did not report actual usage.
            release(permit, cost: reservation)
            throw error
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release(_ id: UUID, cost: Int) {
        guard active.removeValue(forKey: id) != nil else { return }
        usedTokens += cost; drain()
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
            item.continuation.resume(returning: item.id)
        }
    }
}
