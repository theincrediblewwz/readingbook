import Foundation
import XCTest
@testable import ReadingCore

private enum StreamBudgetFixture {
    static let delta = Data(("data: {\"id\":\"" + String(repeating: "protocol-metadata-", count: 20)
        + "\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"中\"}}]}\n\n").utf8)
    static let end = Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":12001}}\n\ndata: [DONE]\n\n".utf8)
}
private final class StreamBudgetFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json = request.url!.path == "/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": json ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if json { client?.urlProtocol(self, didLoad: Data(repeating: 32, count: BoundedProviderResponse.maximumBytes + 1)) }
        else {
            for _ in 0..<12000 { client?.urlProtocol(self, didLoad: StreamBudgetFixture.delta) }
            client?.urlProtocol(self, didLoad: StreamBudgetFixture.end)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ReadingStreamBudgetTests: XCTestCase {
    func testProtocolOverheadAboveFourMiBDoesNotRejectSmallCompleteAnswer() throws {
        let decoder = ProviderStreamDecoder()
        XCTAssertGreaterThan(StreamBudgetFixture.delta.count * 12000, BoundedProviderResponse.maximumBytes)
        for _ in 0..<12000 { try decoder.append(StreamBudgetFixture.delta) }
        try decoder.append(StreamBudgetFixture.end)
        let result = try decoder.finish()
        XCTAssertEqual(result.0.content, String(repeating: "中", count: 12000))
        XCTAssertEqual(result.1, "stop"); XCTAssertEqual(result.2, 12001)
        XCTAssertEqual(decoder.retainedPayloadBytes, 36000)
    }
    func testRealTransportConsumesSSEWithoutRetainingWireCopy() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamBudgetFixtureProtocol.self]
        let decoder = ProviderStreamDecoder()
        let (data, _) = try await BoundedProviderResponse.read(URLRequest(url: URL(string: "https://stream-budget.invalid/sse")!), configuration: config,
            onChunk: { try decoder.append($0) })
        XCTAssertTrue(data.isEmpty, "已解析的协议包不能再全量保留一份")
        XCTAssertGreaterThan(decoder.snapshot.receivedBytes, BoundedProviderResponse.maximumBytes)
        XCTAssertEqual(try decoder.finish().0.content?.count, 12000)
    }
    func testProviderClientAcceptsSameStreamAndKeepsFinalUsage() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamBudgetFixtureProtocol.self]
        let request = ProviderClient.Prepared(request: URLRequest(url: URL(string: "https://stream-budget.invalid/provider")!), estimatedInputTokens: 10)
        let value = try await ProviderClient.perform(request, configuration: config)
        XCTAssertEqual(value.message.content?.count, 12000); XCTAssertEqual(value.tokenCost, 12001)
    }
    func testDecodedPayloadAndOrdinaryJSONStillHaveFourMiBBoundary() async throws {
        let decoder = ProviderStreamDecoder(), text = String(repeating: "汉", count: 800000)
        let delta = Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]]), as: UTF8.self) + "\n\n").utf8)
        try decoder.append(delta)
        XCTAssertThrowsError(try decoder.append(delta)) { error in XCTAssertTrue(error.localizedDescription.contains("实际正文")) }
        XCTAssertEqual(decoder.retainedPayloadBytes, text.utf8.count)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamBudgetFixtureProtocol.self]
        do {
            _ = try await BoundedProviderResponse.read(URLRequest(url: URL(string: "https://stream-budget.invalid/json")!), configuration: config)
            XCTFail("非流式JSON仍受4MiB限制")
        } catch { XCTAssertTrue(error.localizedDescription.contains("4 MiB")) }
    }
    func testUnfinishedFrameAndTotalWireRemainBounded() throws {
        let incomplete = ProviderStreamDecoder()
        try incomplete.append(Data(repeating: 32, count: BoundedProviderResponse.maximumBytes))
        XCTAssertThrowsError(try incomplete.append(Data([32])))
        let wire = ProviderStreamDecoder(), comment = Data((":" + String(repeating: "x", count: 65533) + "\n\n").utf8)
        for _ in 0..<(BoundedProviderResponse.maximumStreamingBytes / comment.count) { try wire.append(comment) }
        XCTAssertThrowsError(try wire.append(comment))
        XCTAssertEqual(wire.retainedPayloadBytes, 0)
    }
}
