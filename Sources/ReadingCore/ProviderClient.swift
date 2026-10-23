import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// This transport has no file, browsing, or arbitrary network tools. Its only
/// destination is the provider endpoint explicitly configured by the user.
enum ProviderClient {
    private static let fallbackSessionID = "readingbook-" + UUID().uuidString
    struct ToolCall: Decodable, Sendable {
        struct Function: Decodable, Sendable { let name: String; let arguments: String }
        let id: String
        let type: String
        let function: Function
    }

    struct Message: Decodable, Sendable {
        let role: String
        let content: String?
        let refusal: String?
        let tool_calls: [ToolCall]?
        let reasoning_content: String?

        var conversationValue: [String: Any] {
            var value: [String: Any] = ["role": "assistant", "content": content.map { $0 as Any } ?? NSNull()]
            if let reasoning = reasoning_content { value["reasoning_content"] = reasoning }
            if let calls = tool_calls, !calls.isEmpty {
                value["tool_calls"] = calls.map { call in
                    ["id": call.id, "type": call.type,
                     "function": ["name": call.function.name, "arguments": call.function.arguments]] as [String: Any]
                }
            }
            return value
        }
    }

    struct Result: Sendable {
        let message: Message
        let finishReason: String
        let tokenCost: Int
    }

    struct Prepared: Sendable {
        let request: URLRequest
        let estimatedInputTokens: Int
    }

    private struct Response: Decodable {
        struct Choice: Decodable { let message: Message; let finish_reason: String? }
        struct Usage: Decodable { let total_tokens: Int? }
        let choices: [Choice]
        let usage: Usage?
    }

    static func endpoint(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ReadingError.invalid("模型地址必须是完整的服务 URL，且不能包含账号、查询参数或片段。")
        }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw ReadingError.invalid("远程模型服务必须使用 HTTPS；HTTP 仅允许 localhost、127.0.0.1 或 ::1。")
        }
        var parts = components.path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else {
            throw ReadingError.invalid("模型地址不能包含相对路径。")
        }
        if !parts.suffix(2).elementsEqual(["chat", "completions"]) {
            if parts.last != "v1" { parts.append("v1") }
            parts.append(contentsOf: ["chat", "completions"])
        }
        components.scheme = scheme
        components.path = "/" + parts.joined(separator: "/")
        guard let url = components.url else { throw ReadingError.invalid("模型地址无效。") }
        return url
    }

    static func prepare(messages: [[String: Any]], tools: [[String: Any]], settings: ProviderSettings,
                        apiKey: String, remainingTokens: Int) throws -> Prepared {
        let url = try endpoint(settings.baseURL)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 240 else { throw ReadingError.invalid("请先填写模型名称。") }
        guard (1...10_000).contains(settings.maxRequestsPerRun),
              (64...1_048_576).contains(settings.maxOutputTokens),
              settings.contextWindowTokens.map({ (1024...4_194_304).contains($0) }) ?? true else {
            throw ReadingError.invalid("请求或 token 预算超出允许范围，请核对模型的上下文与输出上限。")
        }
        guard apiKey.utf8.count <= 8192, !apiKey.contains("\r"), !apiKey.contains("\n") else {
            throw ReadingError.invalid("密钥格式无效。")
        }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false, "n": 1]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        let outputKey = settings.tokenLimitParameter ?? "max_tokens"
        guard ["max_tokens", "max_completion_tokens"].contains(outputKey) else { throw ReadingError.invalid("不支持的输出 token 参数。") }
        body[outputKey] = settings.maxOutputTokens
        let initial = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard initial.count <= 16 * 1024 * 1024 else { throw ReadingError.invalid("模型请求超过 16 MiB，请缩小页图或内容范围。") }
        // Base64 bytes are transport data, not text tokens. Price images separately
        // using a conservative planning estimate; providers/model families differ.
        var imageCount = 0
        var estimationBody = body
        estimationBody["messages"] = messages.map { message -> [String: Any] in
            var value = message
            if let parts = message["content"] as? [[String: Any]] {
                value["content"] = parts.map { part -> [String: Any] in
                    guard part["type"] as? String == "image_url" else { return part }
                    imageCount += 1
                    return ["type": "image_url", "image_url": ["url": "<page-image>", "detail": "high"]]
                }
            }
            return value
        }
        let textBytes = try JSONSerialization.data(withJSONObject: estimationBody, options: [.sortedKeys]).count
        let estimate = textBytes + imageCount * 16_384 + 128
        let capacity = min(remainingTokens, settings.contextWindowTokens ?? remainingTokens)
        let outputLimit = min(settings.maxOutputTokens, capacity - estimate)
        guard outputLimit >= 64 else {
            throw ReadingError.invalid("本次内容接近模型上下文或任务 token 上限；请缩小范围或核对配置，当前结果未提交。")
        }
        body[outputKey] = outputLimit
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ReadingBook/0.16", forHTTPHeaderField: "User-Agent")
        if url.host?.lowercased() == "opencode.ai" {
            let sessionID = settings.transportSessionID ?? fallbackSessionID
            guard sessionID.range(of: "^[a-zA-Z0-9._:-]{1,180}$", options: .regularExpression) != nil else { throw ReadingError.invalid("模型会话标识无效。") }
            request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        }
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return Prepared(request: request, estimatedInputTokens: estimate)
    }

    static func perform(_ prepared: Prepared, configuration suppliedConfiguration: URLSessionConfiguration? = nil) async throws -> Result {
        try Task.checkCancellation()
        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1800
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        // Redirects could otherwise move a user-supplied bearer token to a
        // different destination or downgrade HTTPS to HTTP.
        let (data, response) = try await BoundedProviderResponse.read(prepared.request, configuration: configuration)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ReadingError.invalid("模型服务未返回 HTTP 响应。") }
        guard (200...299).contains(http.statusCode) else {
            // Provider response bodies may echo secrets or source text.
            throw ReadingError.invalid("模型请求失败（HTTP \(http.statusCode)）；请检查服务地址、模型、授权与额度。")
        }
        guard data.count <= 4 * 1024 * 1024 else { throw ReadingError.invalid("模型响应超过 4 MiB 限制。") }
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ReadingError.invalid("模型响应不符合 Chat Completions 契约，当前内容未计为已读。") }
        guard decoded.choices.count == 1, let choice = decoded.choices.first,
              let reason = choice.finish_reason, choice.message.role == "assistant" else {
            throw ReadingError.invalid("模型响应缺少完整的单条 assistant 结果。")
        }
        guard choice.message.refusal?.isEmpty != false else { throw ReadingError.invalid("模型拒绝本次请求，当前内容未计为已读。") }
        guard reason == "stop" || reason == "tool_calls" else {
            let detail = reason == "length" ? "输出被截断" : "未正常结束（\(String(reason.prefix(40)))）"
            throw ReadingError.invalid("模型\(detail)，当前内容未计为已读。")
        }
        let reported = decoded.usage?.total_tokens
        if let reported, !(0...4_194_304).contains(reported) { throw ReadingError.invalid("模型返回了无效或超出保护范围的 token 计数。") }
        return Result(message: choice.message, finishReason: reason,
                      tokenCost: max(1, reported ?? (prepared.estimatedInputTokens + data.count)))
    }
}
