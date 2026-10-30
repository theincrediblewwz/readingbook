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
    private func response(tokenCost: Int = 1) -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: "离线结果", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: tokenCost)
    }
    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ReadingError.invalid("离线调度未在预期时间推进。")
    }

    func testCancellationFromStartCallbackDoesNotEnterTransportOrConsumeTokenReservation() async throws {
        let gate = CoordinatorTransportGate(), result = response(), numbers = CoordinatorRequestNumbers()
        await gate.releaseAll()
        let coordinator = AIRequestCoordinator(transport: { prepared in await gate.wait(prepared.request.url!.lastPathComponent); return result })
        let run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 1)
        defer { run.finish() }
        let request = try prepared("never-sent", input: 500)
        let cancelled = Task {
            try await coordinator.perform(request, lane: .foreground, progress: nil, onStart: { number in
                numbers.append(number)
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await cancelled.value; XCTFail("发送前的取消必须停止传输。") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await coordinator.perform(prepared("following", input: 500), lane: .foreground, progress: nil,
            onStart: { numbers.append($0) })
        let started = await gate.started, used = await coordinator.requestsUsed
        XCTAssertEqual(started, ["following"])
        XCTAssertEqual(numbers.values, [1, 2], "已分配的请求序号仍保持单调，不能回收后重复。")
        XCTAssertEqual(used, 2)
        await coordinator.endRun(run)
    }

    func testCancellationAfterEnteringTransportKeepsConservativeReservationAndReleasesSlot() async throws {
        let gate = CoordinatorTransportGate(), result = response()
        await gate.releaseAll()
        let coordinator = AIRequestCoordinator(transport: { prepared in
            let name = prepared.request.url!.lastPathComponent
            await gate.wait(name)
            if name == "sent" { throw CancellationError() }
            return result
        })
        let run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 1)
        defer { run.finish() }
        do {
            _ = try await coordinator.perform(prepared("sent", input: 500), lane: .foreground, progress: nil, onStart: { _ in })
            XCTFail("传输取消必须向调用者报告。")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await coordinator.perform(prepared("over-budget", input: 500), lane: .foreground, progress: nil, onStart: { _ in })
            XCTFail("已进入传输的未知用量不能释放为零。")
        } catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        _ = try await coordinator.perform(prepared("small", input: 100), lane: .foreground, progress: nil, onStart: { _ in })
        let started = await gate.started, used = await coordinator.requestsUsed
        XCTAssertEqual(started, ["sent", "small"], "小请求获准说明取消后并发槽已释放。")
        XCTAssertEqual(used, 2)
        await coordinator.endRun(run)
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

    func testConcurrentExtremeUsageSaturatesAndReleasesBothActiveRequests() async throws {
        let gate = CoordinatorTransportGate(), result = response(tokenCost: Int.max)
        let coordinator = AIRequestCoordinator(transport: { prepared in await gate.wait(prepared.request.url!.lastPathComponent); return result })
        let run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 2)
        let one = try prepared("huge-one"), two = try prepared("huge-two")
        let first = Task { try await coordinator.perform(one, lane: .foreground, progress: nil, onStart: { _ in }) }
        let second = Task { try await coordinator.perform(two, lane: .foreground, progress: nil, onStart: { _ in }) }
        defer { first.cancel(); second.cancel(); Task { await gate.releaseAll() }; run.finish() }
        try await waitUntil { await gate.started.count == 2 }
        await gate.releaseAll()
        let firstResult = try await first.value, secondResult = try await second.value
        XCTAssertEqual(firstResult.tokenCost, Int.max); XCTAssertEqual(secondResult.tokenCost, Int.max)
        do {
            _ = try await coordinator.perform(prepared("same-run"), lane: .foreground, progress: nil, onStart: { _ in })
            XCTFail("极端共享用量后，同一轮次的新请求应预算暂停。")
        } catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        run.finish(); await coordinator.endRun(run)
        let next = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 2)
        // A fresh admission proves neither overflowing completion left an
        // active permit behind that would prevent resetting the next run.
        _ = try await coordinator.perform(prepared("fresh-run"), lane: .foreground, progress: nil, onStart: { _ in })
        next.finish(); await coordinator.endRun(next)
    }

    func testConcurrentExtremeUsagePausesQueuedAndLaterRequestsWithoutSendingThem() async throws {
        let gate = CoordinatorTransportGate(), result = response(tokenCost: Int.max)
        let coordinator = AIRequestCoordinator(transport: { prepared in await gate.wait(prepared.request.url!.lastPathComponent); return result })
        let run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 2)
        let one = try prepared("huge-background"), two = try prepared("huge-question"), queuedRequest = try prepared("queued-question")
        let background = Task { try await coordinator.perform(one, lane: .background, progress: nil, onStart: { _ in }) }
        let foreground = Task { try await coordinator.perform(two, lane: .foreground, progress: nil, onStart: { _ in }) }
        defer { background.cancel(); foreground.cancel(); Task { await gate.releaseAll() }; run.finish() }
        try await waitUntil { await gate.started.count == 2 }
        let queued = Task { try await coordinator.perform(queuedRequest, lane: .foreground, progress: nil, onStart: { _ in }) }
        defer { queued.cancel() }
        try await waitUntil { await coordinator.queuedRequestCount == 1 }
        await gate.releaseAll()
        _ = try await background.value; _ = try await foreground.value
        do { _ = try await queued.value; XCTFail("已排队请求也应在极端用量后暂停。") }
        catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        do {
            _ = try await coordinator.perform(prepared("later-question"), lane: .foreground, progress: nil, onStart: { _ in })
            XCTFail("后续请求不能越过共享预算。")
        } catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        let started = await gate.started, queuedCount = await coordinator.queuedRequestCount, usedRequests = await coordinator.requestsUsed
        XCTAssertEqual(started, ["huge-background", "huge-question"])
        XCTAssertEqual(queuedCount, 0); XCTAssertEqual(usedRequests, 2)
        run.finish(); await coordinator.endRun(run)
        let next = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 1)
        _ = try await coordinator.perform(prepared("after-pause"), lane: .foreground, progress: nil, onStart: { _ in })
        next.finish(); await coordinator.endRun(next)
    }
}
