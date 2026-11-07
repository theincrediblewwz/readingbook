import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stop while receiving, rather than buffering an unbounded body before checking its size.
final class BoundedProviderResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    /// SSE repeats protocol fields for every tiny delta. Bound that traffic
    /// separately; the decoder still bounds the assembled payload at 4 MiB.
    static let maximumStreamingBytes = 64 * 1024 * 1024
    static let maximumErrorBytes = 16 * 1024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var failureResponse: HTTPURLResponse?
    private var failureDeadline: DispatchWorkItem?
    private var data = Data()
    private var receivedBytes = 0
    private var consumesStream = false
    private var terminal = false
    private let onResponse: (@Sendable (HTTPURLResponse) -> Void)?
    private let onHeaders: (@Sendable (HTTPURLResponse) -> Void)?
    private let onChunk: (@Sendable (Data) throws -> Void)?

    init(onResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil, onChunk: (@Sendable (Data) throws -> Void)? = nil,
         onHeaders: (@Sendable (HTTPURLResponse) -> Void)? = nil) {
        self.onResponse = onResponse; self.onChunk = onChunk; self.onHeaders = onHeaders
        super.init()
    }

    static func read(_ request: URLRequest, configuration: URLSessionConfiguration,
                     onResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil,
                     onChunk: (@Sendable (Data) throws -> Void)? = nil,
                     onHeaders: (@Sendable (HTTPURLResponse) -> Void)? = nil) async throws -> (Data, URLResponse) {
        let receiver = BoundedProviderResponse(onResponse: onResponse, onChunk: onChunk, onHeaders: onHeaders)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { receiver.start(request, session: session, continuation: $0) }
        } onCancel: { receiver.cancel() }
    }
    private func start(_ request: URLRequest, session: URLSession, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        guard !terminal else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let created = session.dataTask(with: request); task = created
        lock.unlock()
        created.resume()
    }
    private func cancel() { finish(error: CancellationError()) }
    private func finish(error: Error?) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let pending = continuation, running = task, savedResponse = response, savedData = data, deadline = failureDeadline
        continuation = nil; task = nil; response = nil; failureResponse = nil; failureDeadline = nil; data = Data()
        lock.unlock()
        deadline?.cancel()
        if let error { running?.cancel(); pending?.resume(throwing: error) }
        else if let savedResponse { pending?.resume(returning: (savedData, savedResponse)) }
        else { pending?.resume(throwing: ReadingError.invalid("模型服务未返回 HTTP 响应。")) }
    }
    private func finishHTTPFailure() {
        lock.lock()
        let http = failureResponse, body = data
        lock.unlock()
        if let http { finish(error: ProviderHTTPFailure(response: http, body: body)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(error: ReadingError.invalid("模型服务未返回 HTTP 响应。")); completionHandler(.cancel); return
        }
        onHeaders?(http)
        guard (200...299).contains(http.statusCode) else {
            // Collect only a small error prefix, with a short deadline even if
            // the server leaves its error response open. Never feed it into the
            // answer stream and never retry a potentially billable request here.
            let deadline = DispatchWorkItem { [weak self] in self?.finishHTTPFailure() }
            lock.lock()
            let active = !terminal
            if active { failureResponse = http; failureDeadline = deadline }
            lock.unlock()
            if active { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250), execute: deadline) }
            completionHandler(active ? .allow : .cancel); return
        }
        let consumesStream = onChunk != nil && http.mimeType?.lowercased() == "text/event-stream"
        let maximum = consumesStream ? Self.maximumStreamingBytes : Self.maximumBytes
        guard response.expectedContentLength <= Int64(maximum) else {
            finish(error: ReadingError.invalid(consumesStream ? "模型流式传输超过 64 MiB 限制，当前结果未提交。" : "模型响应超过 4 MiB 限制。")); completionHandler(.cancel); return
        }
        lock.lock()
        let active = !terminal
        if active { self.response = response; self.consumesStream = consumesStream }
        lock.unlock()
        if active { onResponse?(http) }
        completionHandler(active ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        let failing = failureResponse != nil
        let maximum = failing ? Self.maximumErrorBytes : consumesStream ? Self.maximumStreamingBytes : Self.maximumBytes
        let used = failing ? data.count : receivedBytes
        let overflow = chunk.count > maximum - used
        if failing { data.append(chunk.prefix(maximum - data.count)) }
        else if !overflow {
            receivedBytes += chunk.count
            // Parsed SSE is never decoded from the raw body again. Avoid
            // retaining a second copy of all protocol envelopes in memory.
            if !consumesStream { data.append(chunk) }
        }
        let reachedErrorLimit = failing && data.count == Self.maximumErrorBytes
        lock.unlock()
        if failing {
            if overflow || reachedErrorLimit { finishHTTPFailure() }
        }
        else if overflow { finish(error: ReadingError.invalid(consumesStream ? "模型流式传输超过 64 MiB 限制，当前结果未提交。" : "模型响应超过 4 MiB 限制。")) }
        else { do { try onChunk?(chunk) } catch { finish(error: error) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let failing = failureResponse != nil; lock.unlock()
        if failing { finishHTTPFailure() } else { finish(error: error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
