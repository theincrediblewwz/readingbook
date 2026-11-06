import Foundation
import XCTest
@testable import ReadingCore

private final class PacerFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 100
    private var waits: [Double] = []
    var hold = false
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); time += seconds; lock.unlock() }
    func recordedWaits() -> [Double] { lock.lock(); defer { lock.unlock() }; return waits }
    private func record(_ seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }; waits.append(seconds)
        if !hold { time += seconds }; return hold
    }
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        if record(seconds) { try await Task.sleep(nanoseconds: 30_000_000_000) }
        try Task.checkCancellation()
    }
    var clock: ProviderRequestPacer.Clock { .init(now: { self.now() }, sleep: { try await self.sleep($0) }) }
}

private final class PacedTransportProtocol: URLProtocol {
    static var requests = 0
    static var status = 200
    static var headers: [String: String] = [:]
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProviderRequestPacerTests: XCTestCase {
    private let url = URL(string: "https://provider.invalid/v1/chat/completions")!
    private func hint(_ status: Int = 200, at time: Double = 100, headers: [String: String] = [:]) -> ProviderRequestPacer.ResponseHint {
        .init(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, receivedAt: time, date: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func failure(_ status: Int = 429, body: String = "") -> ProviderHTTPFailure {
        .init(response: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, body: Data(body.utf8))
    }
    func testOneSecondStartGapAddsNothingAfterSlowResponse() {
        var state = ProviderRequestPacer.State(); state.lastStart = 100
        XCTAssertEqual(state.delay(at: 100, interval: 1), 1)
        XCTAssertEqual(state.delay(at: 100.25, interval: 1), 0.75)
        XCTAssertEqual(state.delay(at: 108, interval: 1), 0, "不能在每次长回答结束后再强制多等一秒")
    }
    func testSameServiceProfilesSharePacingAndDifferentServicesDoNot() async throws {
        let clock = PacerFixtureClock()
        let shared = ProviderRequestPacer(clock: clock.clock)
        try await shared.acquire(for: url)
        try await shared.acquire(for: URL(string: "https://PROVIDER.invalid:443/another-model")!)
        XCTAssertEqual(clock.now(), 101)
        try await shared.acquire(for: URL(string: "https://another.invalid/v1/chat/completions")!)
        XCTAssertEqual(clock.now(), 101); XCTAssertEqual(clock.recordedWaits(), [1])
        XCTAssertFalse(ProviderRequestPacer.serviceKey(url).contains("completions"))
    }
    func testConcurrentAdmissionsCannotStartTogether() async throws {
        let clock = PacerFixtureClock()
        let shared = ProviderRequestPacer(clock: clock.clock)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await shared.acquire(for: self.url) } }
            try await group.waitForAll()
        }
        XCTAssertGreaterThanOrEqual(clock.now(), 107)
        XCTAssertGreaterThanOrEqual(clock.recordedWaits().count, 7)
    }
    func testExhaustedRequestTokenAndProjectWindowsUseLatestReset() {
        var state = ProviderRequestPacer.State()
        state.observe(hint(headers: ["x-ratelimit-remaining-requests": "0", "x-ratelimit-reset-requests": "2s", "x-ratelimit-remaining-tokens": "0", "x-ratelimit-reset-tokens": "1m2s", "x-ratelimit-remaining-project-tokens": "0", "x-ratelimit-reset-project-tokens": "1m3s"]), failure: nil, jitter: 0)
        XCTAssertEqual(state.delay(at: 100, interval: 1), 63)
        XCTAssertEqual(state.delay(at: 164, interval: 1), 0)
        var available = ProviderRequestPacer.State()
        available.observe(hint(headers: ["x-ratelimit-remaining-requests": "9", "x-ratelimit-reset-requests": "1m"]), failure: nil, jitter: 0)
        XCTAssertEqual(available.delay(at: 100, interval: 1), 0)
    }
    func testRetryAfterIsMinimumIncludingLongHintsAndHTTPDate() {
        var state = ProviderRequestPacer.State()
        state.observe(hint(429, headers: ["Retry-After": "7200"]), failure: failure(), jitter: 0.25)
        XCTAssertEqual(state.delay(at: 100, interval: 1), 7200.25, "不能把服务器长等待截短后提前重发")
        XCTAssertEqual(hint(503, headers: ["Retry-After": "Tue, 14 Nov 2023 22:13:23 GMT"]).retryDelay, 3)
        XCTAssertEqual(hint(503, headers: ["Retry-After": "0"]).retryDelay, 0)
    }
    func testMissingHintsBackOffAndSuccessResetsFailureStreak() {
        var state = ProviderRequestPacer.State()
        state.observe(hint(429), failure: failure(), jitter: 0.25)
        XCTAssertEqual(state.delay(at: 100, interval: 1), 2.25)
        state.observe(hint(503, at: 103), failure: failure(503), jitter: 0.25)
        XCTAssertEqual(state.delay(at: 103, interval: 1), 4.25)
        state.observe(hint(at: 110), failure: nil, jitter: 0)
        state.observe(hint(429, at: 111), failure: failure(), jitter: 0.25)
        XCTAssertEqual(state.delay(at: 111, interval: 1), 2.25)
        for index in 1...10 { state.observe(hint(503, at: Double(200 + index * 100)), failure: failure(503), jitter: 0.25) }
        XCTAssertEqual(state.delay(at: 1200, interval: 1), 60.25)
    }
    func testQuotaAuthAndOtherErrorsDoNotPretendToBeTemporaryRateLimits() {
        var state = ProviderRequestPacer.State()
        state.observe(hint(429, headers: ["Retry-After": "999"]), failure: failure(body: #"{"error":{"code":"insufficient_quota"}}"#), jitter: 0)
        state.observe(hint(401, headers: ["Retry-After": "999"]), failure: failure(401), jitter: 0)
        state.observe(hint(400, headers: ["Retry-After": "999"]), failure: failure(400), jitter: 0)
        XCTAssertEqual(state.delay(at: 100, interval: 1), 0)
    }
    func testInvalidHintsAreIgnoredAndCompositeDurationsAreValidated() {
        XCTAssertEqual(ProviderRequestPacer.ResponseHint.duration("6m0s"), 360)
        XCTAssertEqual(ProviderRequestPacer.ResponseHint.duration("250ms"), 0.25)
        for value in ["PRIVATE_KEY", "1s garbage", "-2s", "NaNs", "", "1e400s"] {
            XCTAssertNil(ProviderRequestPacer.ResponseHint.duration(value))
        }
        for value in ["-1", "PRIVATE_KEY", "3\nsecret", "99999999999999999999"] { XCTAssertNil(hint(429, headers: ["Retry-After": value]).retryDelay) }
    }
    func testRepeatedReceiptAndOldSuccessCannotEraseNewBackoff() {
        var state = ProviderRequestPacer.State()
        let value = hint(429, at: 105)
        state.observe(value, failure: failure(), jitter: 0.25)
        state.observe(value, failure: failure(), jitter: 0.25)
        state.observe(hint(at: 104), failure: nil, jitter: 0)
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertEqual(state.delay(at: 105, interval: 1), 2.25)
    }
    func testCancellationDuringGapDoesNotReserveAPhantomSlot() async throws {
        let clock = PacerFixtureClock(); clock.hold = true
        let pacer = ProviderRequestPacer(clock: clock.clock)
        try await pacer.acquire(for: url)
        let task = Task { try await pacer.acquire(for: url) }
        while clock.recordedWaits().isEmpty { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("排队取消后不得发送") } catch { XCTAssertTrue(error is CancellationError) }
        clock.advance(1)
        try await pacer.acquire(for: url)
        XCTAssertEqual(clock.recordedWaits().count, 1)
    }
    func testRealTransportAppliesRetryHintWithoutAutomaticallyRepeatingRequest() async throws {
        let clock = PacerFixtureClock()
        let shared = ProviderRequestPacer(clock: clock.clock, jitter: { 0.25 })
        let prepared = ProviderClient.Prepared(request: URLRequest(url: url), estimatedInputTokens: 1)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PacedTransportProtocol.self]
        PacedTransportProtocol.requests = 0; PacedTransportProtocol.status = 429; PacedTransportProtocol.headers = ["Retry-After": "3"]
        PacedTransportProtocol.body = Data(#"{"error":{"code":"rate_limit_exceeded","message":"PRIVATE_KEY_AND_BOOK"}}"#.utf8)
        do { _ = try await ProviderClient.perform(prepared, configuration: configuration, pacer: shared); XCTFail("限流必须返回给调用方") }
        catch { XCTAssertTrue(error is ProviderHTTPFailure); XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        XCTAssertEqual(PacedTransportProtocol.requests, 1, "不得在内部悄悄增加收费请求")
        PacedTransportProtocol.status = 200; PacedTransportProtocol.headers = [:]
        PacedTransportProtocol.body = Data(#"{"choices":[{"message":{"role":"assistant","content":"完成"},"finish_reason":"stop"}],"usage":{"total_tokens":5}}"#.utf8)
        let result = try await ProviderClient.perform(prepared, configuration: configuration, pacer: shared)
        XCTAssertEqual(result.message.content, "完成"); XCTAssertEqual(PacedTransportProtocol.requests, 2)
        XCTAssertEqual(clock.recordedWaits(), [3.25])
    }
}
