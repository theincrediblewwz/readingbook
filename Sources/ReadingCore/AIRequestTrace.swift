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
