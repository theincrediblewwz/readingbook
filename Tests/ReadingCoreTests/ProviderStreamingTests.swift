import Foundation
import XCTest
@testable import ReadingCore

private final class StreamingFixtureProtocol: URLProtocol {
    static var chunks: [Data] = []
    static var headers: [String: String] = ["Content-Type": "text/event-stream"]
    static var finishResponse = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if Self.finishResponse { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

private final class StreamingProgressRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderStreamSnapshot] = []
    var snapshots: [ProviderStreamSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ value: ProviderStreamSnapshot) { lock.lock(); values.append(value); lock.unlock() }
}

final class ProviderStreamingTests: XCTestCase {
    private func event(_ delta: [String: Any], finish: String? = nil) throws -> Data {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return try wire(["choices": [choice]])
    }
    private func wire(_ value: [String: Any]) throws -> Data {
        Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) + "\n\n").utf8)
    }
    private func prepared() -> ProviderClient.Prepared {
        ProviderClient.Prepared(request: URLRequest(url: URL(string: "https://fixture.invalid/v1/chat/completions")!), estimatedInputTokens: 10)
    }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamingFixtureProtocol.self]; return config
    }
    override func setUp() {
        StreamingFixtureProtocol.chunks = []; StreamingFixtureProtocol.headers = ["Content-Type": "text/event-stream"]
        StreamingFixtureProtocol.finishResponse = true
    }
    func testUnicodeChunksProduceOnlyCountersAndCompleteMessage() throws {
        let decoder = ProviderStreamDecoder()
        var data = try event(["role": "assistant", "reasoning_content": "私有思考😀"])
        data.append(try event(["content": "答案甲"], finish: "stop"))
        data.append(try wire(["choices": [], "usage": ["total_tokens": 17]]))
        data.append(Data("data: [DONE]\n\n".utf8))
        for byte in data { try decoder.append(Data([byte])) }
        let result = try decoder.finish()
        XCTAssertEqual(result.0.content, "答案甲"); XCTAssertEqual(result.1, "stop"); XCTAssertEqual(result.2, 17)
        XCTAssertEqual(decoder.snapshot.reasoningCharacters, 5)
        XCTAssertEqual(decoder.snapshot.answerCharacters, 3)
        XCTAssertEqual(decoder.snapshot.receivedBytes, data.count)
        // The UI telemetry type has counts, never the received private text.
        XCTAssertFalse(String(describing: decoder.snapshot).contains("私有思考"))
    }
    func testToolArgumentsAreAssembledBeforeAnyExecution() throws {
        let decoder = ProviderStreamDecoder()
        try decoder.append(event(["tool_calls": [["index": 0, "id": "c1", "type": "function", "function": ["name": "source_", "arguments": "{\"id\":"]], ["index": 1, "id": "c2", "type": "function", "function": ["name": "document_read", "arguments": "{\"id\":\"d1\"}"]]]]))
        try decoder.append(event(["tool_calls": [["index": 0, "function": ["name": "read", "arguments": "\"u1\"}"]]]], finish: "tool_calls"))
        let result = try decoder.finish()
        XCTAssertEqual(result.0.tool_calls?.map(\.id), ["c1", "c2"])
        XCTAssertEqual(result.0.tool_calls?.first?.function.name, "source_read")
        XCTAssertEqual(result.0.tool_calls?.first?.function.arguments, "{\"id\":\"u1\"}")
        XCTAssertEqual(decoder.snapshot.phase, .receivingTools)
    }
    func testReasoningDetailsCountReadableTextWithoutDoubleCountingOrReplayingAnotherProtocol() throws {
        let decoder = ProviderStreamDecoder()
        try decoder.append(event(["reasoning": "思考", "reasoning_details": [["type": "reasoning.text", "text": "思考"]]]))
        try decoder.append(event(["reasoning_details": [["type": "reasoning.summary", "summary": "摘要"], ["type": "reasoning.encrypted", "data": "opaque-signature"]]]))
        try decoder.append(event(["content": "完成"], finish: "stop"))
        let message = try decoder.finish().0
        XCTAssertEqual(decoder.snapshot.reasoningCharacters, 4)
        XCTAssertNil(message.reasoning_content)
    }
    func testInterruptedStreamCannotBecomeACompletedAnswer() throws {
        let decoder = ProviderStreamDecoder(); try decoder.append(event(["content": "部分回答"]))
        XCTAssertThrowsError(try decoder.finish())
        let doneOnly = ProviderStreamDecoder(); try doneOnly.append(Data("data: [DONE]\n\n".utf8))
        XCTAssertThrowsError(try doneOnly.finish())
        let postFinish = ProviderStreamDecoder(); try postFinish.append(event(["content": "完成"], finish: "stop"))
        XCTAssertThrowsError(try postFinish.append(event(["content": "后续内容"])))
    }
    func testCommentsCRLFAndUsageOnlyEventsRemainCompatible() throws {
        let decoder = ProviderStreamDecoder()
        try decoder.append(Data(": keepalive\r\n\r\n".utf8))
        let data = try event(["content": "完成"], finish: "stop")
        try decoder.append(Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8))
        try decoder.append(wire(["choices": [], "usage": ["total_tokens": NSNull()]]))
        XCTAssertEqual(try decoder.finish().0.content, "完成")
    }
    func testMalformedOrOversizeToolsAndProviderErrorAreRejected() throws {
        let invalidIndex = ProviderStreamDecoder()
        XCTAssertThrowsError(try invalidIndex.append(event(["tool_calls": [["index": 32, "id": "c", "function": ["name": "source_read", "arguments": "{}"]]]])))
        let tooLarge = ProviderStreamDecoder()
        XCTAssertThrowsError(try tooLarge.append(event(["tool_calls": [["index": 0, "id": "c", "function": ["name": "source_read", "arguments": String(repeating: "x", count: 512 * 1024 + 1)]]]])))
        let providerError = ProviderStreamDecoder()
        do { try providerError.append(wire(["error": ["message": "PRIVATE_KEY_AND_BOOK"]])); XCTFail("Error must fail") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE_KEY")) }
    }
    func testWireLimitAppliesBeforeUnboundedAccumulation() throws {
        let decoder = ProviderStreamDecoder()
        try decoder.append(Data(repeating: 32, count: BoundedProviderResponse.maximumBytes))
        XCTAssertThrowsError(try decoder.append(Data([32])))
    }
    func testProgressCoalescesCharactersKeepsFinalCountAndStopsAfterCancellation() {
        let records = StreamingProgressRecords()
        let reporter = ProviderProgressReporter { records.append($0) }
        for count in 1...1000 { reporter.emit(ProviderStreamSnapshot(phase: .reasoning, reasoningCharacters: count)) }
        reporter.emit(ProviderStreamSnapshot(phase: .reasoning, reasoningCharacters: 1000), force: true)
        XCTAssertLessThan(records.snapshots.count, 1000)
        XCTAssertEqual(records.snapshots.last?.reasoningCharacters, 1000)
        let count = records.snapshots.count
        reporter.stop(); reporter.emit(ProviderStreamSnapshot(phase: .answering, answerCharacters: 5), force: true)
        XCTAssertEqual(records.snapshots.count, count)
    }
    func testTransportStreamsBeforeCompletionAndCancelsWaitingResponse() async throws {
        let received = expectation(description: "real chunk counter before response finishes")
        StreamingFixtureProtocol.chunks = [try event(["reasoning_content": "不可展示的推理"])]
        StreamingFixtureProtocol.finishResponse = false
        let records = StreamingProgressRecords()
        let request = prepared(), config = configuration()
        let task = Task { try await ProviderClient.perform(request, configuration: config, progress: { value in
            records.append(value)
            if value.reasoningCharacters > 0 { received.fulfill() }
        }) }
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(records.snapshots.last?.reasoningCharacters, 7)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled stream must not commit") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
    func testJSONFallbackAndHeaderlessSSEBothDecode() async throws {
        let records = StreamingProgressRecords()
        StreamingFixtureProtocol.headers = ["Content-Type": "application/json"]
        StreamingFixtureProtocol.chunks = [Data(#"{"choices":[{"message":{"role":"assistant","content":"一次性回答"},"finish_reason":"stop"}],"usage":{"total_tokens":8}}"#.utf8)]
        var result = try await ProviderClient.perform(prepared(), configuration: configuration(), progress: { records.append($0) })
        XCTAssertEqual(result.message.content, "一次性回答"); XCTAssertEqual(records.snapshots.last?.answerCharacters, 5)
        StreamingFixtureProtocol.headers = [:]
        StreamingFixtureProtocol.chunks = [Data("da".utf8), try event(["content": "流式"], finish: "stop").dropFirst(2)]
        result = try await ProviderClient.perform(prepared(), configuration: configuration())
        XCTAssertEqual(result.message.content, "流式")
    }
    func testTruncatedFinishReasonStillFailsNormalProviderValidation() async throws {
        StreamingFixtureProtocol.chunks = [try event(["content": "截断结果"], finish: "length")]
        do { _ = try await ProviderClient.perform(prepared(), configuration: configuration()); XCTFail("Length is not completion") }
        catch { XCTAssertTrue(error.localizedDescription.contains("截断")) }
    }
}
