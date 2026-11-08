import Foundation

/// Local, transient evidence of what the host actually sent or returned. This
/// is deliberately not Codable and never enters a book or request-history file.
/// Only message text and tool arguments cross this boundary, never HTTP headers,
/// credentials, image bytes or the model's private reasoning channel.
public struct AITraceText: Equatable, Sendable {
    public let text: String
    public let originalBytes: Int
    public var isPartial: Bool { text.utf8.count < originalBytes }
    public init(_ text: String, maximumBytes: Int = 65_536) {
        originalBytes = text.utf8.count
        guard originalBytes > max(0, maximumBytes) else { self.text = text; return }
        var end = text.startIndex, used = 0
        while end < text.endIndex {
            let next = text.index(after: end), bytes = text[end..<next].utf8.count
            guard used + bytes <= max(0, maximumBytes) else { break }
            used += bytes; end = next
        }
        self.text = String(text[..<end])
    }
}

public struct AIRequestTrace: Equatable, Sendable {
    public struct Message: Identifiable, Equatable, Sendable {
        public let id: Int
        public let role: String
        public let content: AITraceText
    }
    public let messages: [Message]
    public let toolNames: [String]
    public let omittedMessages: Int
    public var retainedBytes: Int { messages.reduce(0) { $0 + $1.content.text.utf8.count } }

    static func capture(_ prepared: ProviderClient.Prepared, maximumBytes: Int = 262_144) -> Self? {
        guard let data = prepared.request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = body["messages"] as? [[String: Any]] else { return nil }
        var remaining = max(0, maximumBytes), messages: [Message] = [], omitted = 0
        for (index, row) in rows.enumerated() {
            var pieces: [String] = []
            if let text = row["content"] as? String { pieces.append(text) }
            else if let parts = row["content"] as? [[String: Any]] {
                for part in parts {
                    if part["type"] as? String == "text", let text = part["text"] as? String { pieces.append(text) }
                    else if part["type"] as? String == "image_url" { pieces.append("[本次附有图片；此处不保留图片数据]") }
                }
            }
            if let calls = row["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { continue }
                    pieces.append(name + "\n" + (function["arguments"] as? String ?? ""))
                }
            }
            // reasoning_content is intentionally neither read nor retained.
            guard !pieces.isEmpty else { continue }
            guard remaining > 0 else { omitted += 1; continue }
            let content = AITraceText(pieces.joined(separator: "\n\n"), maximumBytes: min(65_536, remaining))
            remaining -= content.text.utf8.count
            messages.append(Message(id: index, role: row["role"] as? String ?? "unknown", content: content))
        }
        let names = (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        return Self(messages: messages, toolNames: names, omittedMessages: omitted)
    }
}

/// The public response to one actual HTTP request. Kept in the same bounded
/// diagnostic memory as outgoing text, independently of final-answer saving.
public struct AIResponseTrace: Equatable, Sendable {
    public struct ToolCall: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let arguments: AITraceText
    }
    public let content: AITraceText?
    public let refusal: AITraceText?
    public let toolCalls: [ToolCall]
    public let omittedToolCalls: Int
    public let finishReason: String
    public var retainedBytes: Int {
        (content?.text.utf8.count ?? 0) + (refusal?.text.utf8.count ?? 0)
            + toolCalls.reduce(0) { $0 + $1.name.utf8.count + $1.arguments.text.utf8.count }
    }
    static func capture(_ response: ProviderClient.Result, maximumBytes: Int = 262_144) -> Self {
        var remaining = max(0, maximumBytes)
        func retain(_ text: String?) -> AITraceText? {
            guard let text, !text.isEmpty else { return nil }
            let value = AITraceText(text, maximumBytes: min(65_536, remaining)); remaining -= value.text.utf8.count
            return value
        }
        let content = retain(response.message.content), refusal = retain(response.message.refusal)
        var calls: [ToolCall] = [], omitted = 0
        for (index, call) in (response.message.tool_calls ?? []).enumerated() {
            let name = String(call.function.name.prefix(80))
            guard calls.count < 32, name.utf8.count <= remaining else { omitted += 1; continue }
            remaining -= name.utf8.count
            let arguments = AITraceText(call.function.arguments, maximumBytes: min(32_768, remaining)); remaining -= arguments.text.utf8.count
            calls.append(ToolCall(id: index, name: name, arguments: arguments))
        }
        return Self(content: content, refusal: refusal, toolCalls: calls, omittedToolCalls: omitted,
            finishReason: String(response.finishReason.prefix(80)))
    }
}

public struct AIToolTrace: Equatable, Sendable {
    public struct Fragment: Identifiable, Equatable, Sendable {
        public let id: Int
        public let title: String
        public let text: String
        public let detail: String
    }
    public let arguments: AITraceText
    public let result: AITraceText
    public let fragments: [Fragment]
    public var retainedBytes: Int {
        arguments.text.utf8.count + result.text.utf8.count
            + fragments.reduce(0) { $0 + $1.title.utf8.count + $1.text.utf8.count + $1.detail.utf8.count }
    }
    public init(arguments: String, result: String) {
        self.arguments = AITraceText(arguments, maximumBytes: 32_768)
        self.result = AITraceText(result, maximumBytes: 32_768)
        guard result.utf8.count <= 32_768, let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fragments = []; return }
        let rows = object["hits"] as? [[String: Any]] ?? [object]
        fragments = rows.prefix(20).enumerated().compactMap { index, row in
            guard let text = row["text"] as? String ?? row["snippet"] as? String else { return nil }
            let title = row["locator"] as? String ?? row["title"] as? String ?? row["id"] as? String ?? "实际返回的文字"
            let detail: String
            if row["snippet"] != nil { detail = "检索命中片段，并非整页正文。" }
            else if let next = row["nextOffset"] as? Int { detail = "本次读取到字符 \(next)，后面还有正文。" }
            else if let start = row["offset"] as? Int, start > 0 { detail = "从字符 \(start) 读至本段末尾。" }
            else { detail = "本次返回的正文。" }
            return Fragment(id: index, title: String(title.prefix(300)), text: text, detail: detail)
        }
    }
}
