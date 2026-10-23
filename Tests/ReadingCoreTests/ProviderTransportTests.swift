import Foundation
import XCTest
@testable import ReadingCore

private final class FixtureProviderProtocol: URLProtocol {
    static var responseStatus = 200
    static var responseHeaders: [String: String] = [:]
    static var chunks: [Data] = []
    static var suspendAfterHeaders = false
    static var onStart: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseStatus, httpVersion: "HTTP/1.1", headerFields: Self.responseHeaders)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.onStart?()
        if Self.suspendAfterHeaders { return }
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor TransportStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

final class ProviderTransportTests: XCTestCase {
    private func prepared() -> ProviderClient.Prepared {
        ProviderClient.Prepared(request: URLRequest(url: URL(string: "https://provider.invalid/v1/chat/completions")!), estimatedInputTokens: 1)
    }
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProviderProtocol.self]
        return configuration
    }
    override func setUp() {
        FixtureProviderProtocol.responseStatus = 200; FixtureProviderProtocol.responseHeaders = [:]; FixtureProviderProtocol.chunks = []
        FixtureProviderProtocol.suspendAfterHeaders = false; FixtureProviderProtocol.onStart = nil
    }
    func testValidBoundedResponseStillDecodes() async throws {
        FixtureProviderProtocol.chunks = [Data(#"{"choices":[{"message":{"role":"assistant","content":"完成"},"finish_reason":"stop"}],"usage":{"total_tokens":5}}"#.utf8)]
        let result = try await ProviderClient.perform(prepared(), configuration: configuration())
        XCTAssertEqual(result.message.content, "完成"); XCTAssertEqual(result.tokenCost, 5)
    }
    func testAdvertisedOversizeRejectedBeforeDecode() async {
        FixtureProviderProtocol.responseHeaders = ["Content-Length": String(BoundedProviderResponse.maximumBytes + 1)]
        do { _ = try await ProviderClient.perform(prepared(), configuration: configuration()); XCTFail("超长声明应拒绝") }
        catch { XCTAssertTrue(error.localizedDescription.contains("4 MiB")) }
    }
    func testUnknownLengthBodyIsBoundedWhileReceiving() async {
        FixtureProviderProtocol.chunks = [Data(repeating: 32, count: BoundedProviderResponse.maximumBytes), Data([32])]
        do { _ = try await ProviderClient.perform(prepared(), configuration: configuration()); XCTFail("分块超限应拒绝") }
        catch { XCTAssertTrue(error.localizedDescription.contains("4 MiB")) }
    }
    func testProviderErrorNeverEchoesBody() async {
        FixtureProviderProtocol.responseStatus = 403; FixtureProviderProtocol.chunks = [Data("PRIVATE_KEY_AND_BOOK_TEXT".utf8)]
        do { _ = try await ProviderClient.perform(prepared(), configuration: configuration()); XCTFail("HTTP错误应拒绝") }
        catch { XCTAssertTrue(error.localizedDescription.contains("403")); XCTAssertFalse(error.localizedDescription.contains("PRIVATE_KEY")) }
    }
    func testExtremeReportedUsageIsRejectedWithoutOverflow() async {
        FixtureProviderProtocol.chunks = [Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"完成\"},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":\(Int.max)}}".utf8)]
        do { _ = try await ProviderClient.perform(prepared(), configuration: configuration()); XCTFail("异常计数应拒绝") }
        catch { XCTAssertTrue(error.localizedDescription.contains("token")) }
    }
    func testCancellationBeforeStartCannotTurnIntoSuccessfulResponse() async {
        let request = prepared(), configuration = configuration(), gate = TransportStartGate()
        let task = Task { await gate.wait(); try Task.checkCancellation(); return try await ProviderClient.perform(request, configuration: configuration) }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("已取消不应成功") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
    func testCancellationDuringResponseResumesWaitingCaller() async {
        let started = expectation(description: "fixture request started")
        FixtureProviderProtocol.suspendAfterHeaders = true; FixtureProviderProtocol.onStart = { started.fulfill() }
        let request = prepared(), configuration = configuration()
        let task = Task { try await ProviderClient.perform(request, configuration: configuration) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("活动请求取消后不应挂住或成功") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
}
