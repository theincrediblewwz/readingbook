import Foundation
import XCTest
@testable import ReadingCore

private final class RejectedProviderFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "3", "Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch request.url!.lastPathComponent {
        case "suspended": client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 4096)); return
        case "oversized": client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 100_000)); return
        default:
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"type":"server_error","message":"Upstream request failed: [overloaded] the server is overloaded; retry shortly PRIVATE_CREDENTIAL_AND_BOOK_TEXT"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class FailureProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func called() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

private actor RecoveringProvider {
    private(set) var count = 0
    func perform(_ request: ProviderClient.Prepared) throws -> ProviderClient.Result {
        count += 1
        if count == 1 {
            throw ProviderHTTPFailure(response: HTTPURLResponse(url: request.request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "3"])!)
        }
        return .init(message: .init(role: "assistant", content: "恢复", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 1)
    }
}

final class ProviderFailureTests: XCTestCase {
    private func failure(_ status: Int, body: String = "", retry: String? = nil, now: Date = Date()) -> ProviderHTTPFailure {
        let response = HTTPURLResponse(url: URL(string: "https://provider.invalid/private")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: retry.map { ["Retry-After": $0] })!
        return ProviderHTTPFailure(response: response, body: Data(body.utf8), now: now)
    }
    func testOverloadIsDistinctFromQuotaWithoutEchoingProviderText() {
        let value = failure(429, body: #"{"error":{"type":"server_error","message":"Upstream request failed: [overloaded] PRIVATE_CREDENTIAL_AND_BOOK_TEXT"}}"#, retry: "3")
        XCTAssertEqual(value.reason, .overloaded); XCTAssertEqual(value.retryAfterSeconds, 3)
        XCTAssertTrue(value.localizedDescription.contains("过载")); XCTAssertTrue(value.localizedDescription.contains("3 秒"))
        XCTAssertFalse(value.localizedDescription.contains("PRIVATE")); XCTAssertFalse(value.localizedDescription.contains("额度"))
        let quota = failure(429, body: #"{"error":{"code":"insufficient_quota","message":"PRIVATE"}}"#)
        XCTAssertEqual(quota.reason, .quota); XCTAssertTrue(quota.localizedDescription.contains("额度限制"))
    }
    func testUnknownRateLimitDoesNotInventAnAccountCause() {
        for body in ["PRIVATE_CREDENTIAL", #"{"error":{"message":"PRIVATE_CREDENTIAL"}}"#, ""] {
            let value = failure(429, body: body)
            XCTAssertEqual(value.reason, .rateLimited)
            XCTAssertFalse(value.localizedDescription.contains("额度")); XCTAssertFalse(value.localizedDescription.contains("PRIVATE"))
            XCTAssertTrue(value.localizedDescription.contains("HTTP 429"))
        }
    }
    func testOnlyValidatedShortRetryHintsAreDisplayed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for retry in ["PRIVATE_CREDENTIAL", "-1", "0", "99999999999999999999", "7200", "3\nPRIVATE_CREDENTIAL"] {
            let value = failure(503, retry: retry, now: now)
            XCTAssertNil(value.retryAfterSeconds); XCTAssertFalse(value.localizedDescription.contains("PRIVATE"))
        }
        let date = failure(503, retry: "Tue, 14 Nov 2023 22:13:23 GMT", now: now)
        XCTAssertEqual(date.retryAfterSeconds, 3)
        XCTAssertNil(failure(503, retry: "Tue, 14 Nov 2023 22:13:19 GMT", now: now).retryAfterSeconds)
    }
    func testStatusCategoriesNeverExposeRawProviderBody() {
        for (status, reason) in [(401, ProviderHTTPFailure.Reason.unauthorized), (403, .forbidden), (502, .unavailable), (400, .request), (302, .request)] {
            let value = failure(status, body: #"{"error":{"message":"PRIVATE_CREDENTIAL_AND_BOOK_TEXT"}}"#)
            XCTAssertEqual(value.reason, reason); XCTAssertTrue(value.localizedDescription.contains(String(status)))
            XCTAssertFalse(value.localizedDescription.contains("PRIVATE"))
        }
    }
    func testBoundedTransportClassifiesFailureAndNeverFeedsItIntoAnswerProgress() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RejectedProviderFixture.self]
        let progress = FailureProgress()
        do {
            _ = try await BoundedProviderResponse.read(URLRequest(url: URL(string: "https://provider.invalid/complete")!), configuration: config,
                onResponse: { _ in progress.called() }, onChunk: { _ in progress.called() })
            XCTFail("拒绝请求不能作为回答返回。")
        } catch {
            let value = try XCTUnwrap(error as? ProviderHTTPFailure)
            XCTAssertEqual(value.reason, .overloaded); XCTAssertEqual(value.retryAfterSeconds, 3)
            XCTAssertFalse(value.localizedDescription.contains("PRIVATE"))
        }
        XCTAssertEqual(progress.count, 0)
    }
    func testFailureWithStalledPrefixOrExcessiveBodyFinishesPromptly() async throws {
        for path in ["suspended", "oversized"] {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RejectedProviderFixture.self]; config.timeoutIntervalForResource = 3
            let start = Date()
            do {
                _ = try await BoundedProviderResponse.read(URLRequest(url: URL(string: "https://provider.invalid/" + path)!), configuration: config)
                XCTFail("无效错误体不能成功。")
            } catch {
                XCTAssertEqual((error as? ProviderHTTPFailure)?.statusCode, 429, "\(path): \(error)")
                XCTAssertLessThan(Date().timeIntervalSince(start), 3)
            }
        }
    }
    func testCancellationWhileAwaitingErrorBodyKeepsCancellationSemantics() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RejectedProviderFixture.self]
        let task = Task {
            try await BoundedProviderResponse.read(URLRequest(url: URL(string: "https://provider.invalid/suspended")!), configuration: config)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("取消不能变为成功。") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
    func testCoordinatorCountsFailureOnceAndRecoversOnlyOnNextExplicitRequest() async throws {
        let provider = RecoveringProvider(), coordinator = AIRequestCoordinator(transport: { request in try await provider.perform(request) })
        let settings = ProviderSettings(model: "offline", maxRequestsPerRun: 4, maxOutputTokens: 64, contextWindowTokens: 4096)
        try await coordinator.beginRun(settings: settings, maximumConcurrency: 2)
        var request = URLRequest(url: URL(string: "https://provider.invalid/recovery")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["max_tokens": 64])
        let prepared = ProviderClient.Prepared(request: request, estimatedInputTokens: 100)
        do { _ = try await coordinator.perform(prepared, lane: .foreground, progress: nil, onStart: { _ in }); XCTFail("第一轮应保留失败。") }
        catch { XCTAssertEqual((error as? ProviderHTTPFailure)?.statusCode, 429) }
        let failedCount = await provider.count, failedRequests = await coordinator.requestsUsed
        XCTAssertEqual(failedCount, 1); XCTAssertEqual(failedRequests, 1)
        let result = try await coordinator.perform(prepared, lane: .foreground, progress: nil, onStart: { _ in })
        let finalCount = await provider.count, finalRequests = await coordinator.requestsUsed
        XCTAssertEqual(result.message.content, "恢复"); XCTAssertEqual(finalCount, 2); XCTAssertEqual(finalRequests, 2)
        await coordinator.endRun()
    }
}
