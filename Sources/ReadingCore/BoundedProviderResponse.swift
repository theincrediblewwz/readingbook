import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stop while receiving, rather than buffering an unbounded body before checking its size.
final class BoundedProviderResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var data = Data()
    private var terminal = false

    static func read(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        let receiver = BoundedProviderResponse()
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
        let pending = continuation, running = task, savedResponse = response, savedData = data
        continuation = nil; task = nil; response = nil; data = Data()
        lock.unlock()
        if let error { running?.cancel(); pending?.resume(throwing: error) }
        else if let savedResponse { pending?.resume(returning: (savedData, savedResponse)) }
        else { pending?.resume(throwing: ReadingError.invalid("模型服务未返回 HTTP 响应。")) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(error: ReadingError.invalid("模型服务未返回 HTTP 响应。")); completionHandler(.cancel); return
        }
        guard (200...299).contains(http.statusCode) else {
            finish(error: ReadingError.invalid("模型请求失败（HTTP \(http.statusCode)）；请检查服务地址、模型、授权与额度。"))
            completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
            finish(error: ReadingError.invalid("模型响应超过 4 MiB 限制。")); completionHandler(.cancel); return
        }
        lock.lock()
        let active = !terminal
        if active { self.response = response }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        let overflow = chunk.count > Self.maximumBytes - data.count
        if !overflow { data.append(chunk) }
        lock.unlock()
        if overflow { finish(error: ReadingError.invalid("模型响应超过 4 MiB 限制。")) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error: error) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
