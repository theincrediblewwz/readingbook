import Foundation
import XCTest
@testable import ReadingCore

private actor CoordinatorTransportGate {
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var open = Set<String>()
    private var allOpen = false
    private(set) var started = Set<String>()
    func wait(_ name: String) async {
        started.insert(name)
        if allOpen || open.contains(name) { return }
        await withCheckedContinuation { waiters[name] = $0 }
    }
    func release(_ name: String) { open.insert(name); waiters.removeValue(forKey: name)?.resume() }
    func releaseAll() { allOpen = true; for waiter in waiters.values { waiter.resume() }; waiters.removeAll() }
}

private final class CoordinatorRequestNumbers: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ number: Int) { lock.lock(); defer { lock.unlock() }; storage.append(number) }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class AIRequestCoordinatorTests: XCTestCase {
    private var settings: ProviderSettings { ProviderSettings(model: "offline", maxRequestsPerRun: 10, maxOutputTokens: 64, contextWindowTokens: 1024) }
    private func prepared(_ name: String, input: Int = 100) throws -> ProviderClient.Prepared {
        var request = URLRequest(url: URL(string: "https://offline.invalid/" + name)!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["max_tokens": 64])
        return .init(request: request, estimatedInputTokens: input)
    }
    private func response() -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: "离线结果", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 1)
    }
    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ReadingError.invalid("离线调度未在预期时间推进。")
    }

    func testFinishedRunResetsBeforeDelayedCleanupAndCleanupCannotFinishAnotherRun() async throws {
        let result = response(), coordinator = AIRequestCoordinator(transport: { _ in result })
        var limited = settings; limited.maxRequestsPerRun = 1
        let first = try await coordinator.beginManagedRun(settings: limited, maximumConcurrency: 2)
        _ = try await coordinator.perform(prepared("first"), lane: .foreground, progress: nil, onStart: { _ in })
        first.finish()
        let next = try await coordinator.beginManagedRun(settings: limited, maximumConcurrency: 2)
        await coordinator.endRun(first)
        _ = try await coordinator.perform(prepared("next"), lane: .foreground, progress: nil, onStart: { _ in })
        await coordinator.endRun(first) // Repeated cleanup must not release `next`.
        let overlapping = try await coordinator.beginManagedRun(settings: limited, maximumConcurrency: 2)
        do {
            _ = try await coordinator.perform(prepared("overlapping"), lane: .foreground, progress: nil, onStart: { _ in })
            XCTFail("仍活跃的共享轮次不能被旧清理重置预算。")
        } catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        next.finish(); overlapping.finish()
        await coordinator.endRun(next); await coordinator.endRun(overlapping)
    }

    func testLegacyBeginAndEndStillHoldTheBudgetWhenReturnValuesAreIgnored() async throws {
        let result = response(), coordinator = AIRequestCoordinator(transport: { _ in result })
        var limited = settings; limited.maxRequestsPerRun = 1
        try await coordinator.beginRun(settings: limited, maximumConcurrency: 1)
        _ = try await coordinator.perform(prepared("legacy"), lane: .foreground, progress: nil, onStart: { _ in })
        let managed = try await coordinator.beginManagedRun(settings: limited, maximumConcurrency: 1)
        do {
            _ = try await coordinator.perform(prepared("shared"), lane: .foreground, progress: nil, onStart: { _ in })
            XCTFail("旧调用的授权轮次仍应共享已用预算。")
        } catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        managed.finish(); await coordinator.endRun(managed); await coordinator.endRun()
        try await coordinator.beginRun(settings: limited, maximumConcurrency: 1)
        _ = try await coordinator.perform(prepared("new-legacy"), lane: .foreground, progress: nil, onStart: { _ in })
        await coordinator.endRun()
    }

    func testSeveralAdmissionsKeepTheirOwnRequestNumbers() async throws {
        let gate = CoordinatorTransportGate(), result = response(), numbers = CoordinatorRequestNumbers()
        let coordinator = AIRequestCoordinator(transport: { prepared in await gate.wait(prepared.request.url!.lastPathComponent); return result })
        let run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 1)
        let one = try prepared("one"), two = try prepared("two"), three = try prepared("three")
        let first = Task { try await coordinator.perform(one, lane: .foreground, progress: nil, onStart: { numbers.append($0) }) }
        defer { first.cancel(); Task { await gate.releaseAll() }; run.finish() }
        try await waitUntil { await gate.started.contains("one") }
        let second = Task { try await coordinator.perform(two, lane: .foreground, progress: nil, onStart: { numbers.append($0) }) }
        let third = Task { try await coordinator.perform(three, lane: .foreground, progress: nil, onStart: { numbers.append($0) }) }
        defer { second.cancel(); third.cancel() }
        try await waitUntil { await coordinator.queuedRequestCount == 2 }
        await coordinator.configure(maximumConcurrency: 3)
        try await waitUntil { await gate.started.count == 3 }
        XCTAssertEqual(numbers.values.sorted(), [1, 2, 3])
        await gate.releaseAll(); _ = try await first.value; _ = try await second.value; _ = try await third.value
        await coordinator.endRun(run)
    }

    func testCancellingOversizeHeadImmediatelyStartsAWaitingRequestThatFits() async throws {
        let gate = CoordinatorTransportGate(), result = response()
        let coordinator = AIRequestCoordinator(transport: { prepared in await gate.wait(prepared.request.url!.lastPathComponent); return result })
        let run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 2)
        let firstRequest = try prepared("active", input: 500), blockedRequest = try prepared("blocked", input: 500), smallRequest = try prepared("small")
        let active = Task { try await coordinator.perform(firstRequest, lane: .foreground, progress: nil, onStart: { _ in }) }
        defer { active.cancel(); Task { await gate.releaseAll() }; run.finish() }
        try await waitUntil { await gate.started.contains("active") }
        let blocked = Task { try await coordinator.perform(blockedRequest, lane: .foreground, progress: nil, onStart: { _ in }) }
        defer { blocked.cancel() }
        try await waitUntil { await coordinator.queuedRequestCount == 1 }
        let small = Task { try await coordinator.perform(smallRequest, lane: .background, progress: nil, onStart: { _ in }) }
        defer { small.cancel() }
        try await waitUntil { await coordinator.queuedRequestCount == 2 }
        blocked.cancel()
        do { _ = try await blocked.value; XCTFail("取消的排队请求不应发送。") } catch { XCTAssertTrue(error is CancellationError) }
        try await waitUntil { await gate.started.contains("small") }
        let started = await gate.started
        XCTAssertFalse(started.contains("blocked"))
        await gate.releaseAll(); _ = try await active.value; _ = try await small.value
        await coordinator.endRun(run)
    }
}
