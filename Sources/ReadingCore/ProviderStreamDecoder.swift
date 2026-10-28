import Foundation
import CoreFoundation

/// Incremental Chat Completions SSE assembly. Only complete, normally finished
/// messages are returned to the existing tool validators and persistence path.
final class ProviderStreamDecoder: @unchecked Sendable {
    private struct Call {
        var id = ""
        var type = "function"
        var name = ""
        var arguments = ""
    }
    private var pending = Data()
    private var scannedBytes = 0
    private var eventData: [String] = []
    private var content = ""
    private var reasoning = ""
    private var refusal = ""
    private var calls: [Int: Call] = [:]
    private var finishReason: String?
    private var totalTokens: Int?
    private var done = false
    private var bytes = 0
    private(set) var snapshot = ProviderStreamSnapshot()
    var onProgress: ((ProviderStreamSnapshot) -> Void)?

    func append(_ chunk: Data) throws {
        guard chunk.count <= BoundedProviderResponse.maximumBytes - bytes else { throw invalid("模型响应超过 4 MiB 限制。") }
        bytes += chunk.count; snapshot.receivedBytes = bytes
        pending.append(chunk)
        var start = pending.startIndex
        var scan = pending.index(pending.startIndex, offsetBy: scannedBytes)
        while let newline = pending[scan...].firstIndex(of: 10) {
            var line = Data(pending[start..<newline])
            start = pending.index(after: newline)
            scan = start
            if line.last == 13 { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8) else { throw invalid("模型流式响应含无效 UTF-8。") }
            try consumeLine(text)
        }
        if start > pending.startIndex { pending.removeSubrange(..<start) }
        scannedBytes = pending.count
        onProgress?(snapshot)
    }

    func finish() throws -> (ProviderClient.Message, String, Int?) {
        if !pending.isEmpty {
            var tail = pending
            if tail.last == 13 { tail.removeLast() }
            guard let text = String(data: tail, encoding: .utf8) else { throw invalid("模型流式响应在 UTF-8 字符中途结束。") }
            pending.removeAll(); try consumeLine(text)
        }
        try dispatchEvent()
        guard let finishReason else { throw invalid("模型流式响应中途结束，缺少完成标记；当前内容未计为已读。") }
        let ordered = calls.keys.sorted()
        guard ordered.isEmpty || ordered == Array(0..<ordered.count) else { throw invalid("模型工具分片序号不连续。") }
        let toolCalls = try ordered.map { index -> ProviderClient.ToolCall in
            let call = calls[index]!
            guard !call.id.isEmpty, call.id.count <= 200, call.type == "function", !call.name.isEmpty,
                  call.name.count <= 200, call.arguments.utf8.count <= 512 * 1024 else { throw invalid("模型工具分片不完整或超出限制。") }
            return ProviderClient.ToolCall(id: call.id, type: call.type, function: .init(name: call.name, arguments: call.arguments))
        }
        guard Set(toolCalls.map(\.id)).count == toolCalls.count else { throw invalid("模型工具调用 ID 重复。") }
        return (ProviderClient.Message(role: "assistant", content: content.isEmpty ? nil : content,
                                       refusal: refusal.isEmpty ? nil : refusal, tool_calls: toolCalls.isEmpty ? nil : toolCalls,
                                       reasoning_content: reasoning.isEmpty ? nil : reasoning), finishReason, totalTokens)
    }

    private func consumeLine(_ line: String) throws {
        if line.isEmpty { try dispatchEvent(); return }
        if line.hasPrefix(":") { return }
        if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            eventData.append(String(value.first == " " ? value.dropFirst() : value))
        }
    }
    private func dispatchEvent() throws {
        guard !eventData.isEmpty else { return }
        let text = eventData.joined(separator: "\n"); eventData.removeAll(keepingCapacity: true)
        guard !done else { throw invalid("模型完成标记后又返回了数据。") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { done = true; return }
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["error"] == nil, let choices = value["choices"] as? [[String: Any]], choices.count <= 1 else {
            throw invalid("模型流式响应格式无效或服务返回错误；当前内容未计为已读。")
        }
        if let usage = value["usage"] as? [String: Any], let raw = usage["total_tokens"], !(raw is NSNull) {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue, (0...4_194_304).contains(number.intValue) else { throw invalid("模型返回了无效或超出保护范围的 token 计数。") }
            totalTokens = number.intValue
        }
        guard let choice = choices.first else { return } // Usage-only terminal chunk.
        guard finishReason == nil else { throw invalid("模型结束后又返回正文分片；当前结果未提交。") }
        if let rawIndex = choice["index"] {
            guard let index = rawIndex as? NSNumber, CFGetTypeID(index) != CFBooleanGetTypeID(), index.doubleValue == 0 else { throw invalid("模型必须返回单条 assistant 流式结果。") }
        }
        if let delta = choice["delta"] as? [String: Any] {
            for key in ["role", "content", "reasoning_content", "reasoning", "refusal"] {
                if let value = delta[key], !(value is NSNull), !(value is String) { throw invalid("模型返回了无效的文本分片。") }
            }
            if let role = delta["role"] as? String, role != "assistant" { throw invalid("模型返回了非 assistant 分片。") }
            if let text = delta["content"] as? String { content += text; snapshot.answerCharacters += text.unicodeScalars.count; snapshot.phase = .answering }
            // Preserve the existing DeepSeek replay field. Other providers'
            // reasoning/summary text is counted without inventing a message
            // field or copying opaque signatures into UI telemetry.
            if let replay = delta["reasoning_content"] as? String { reasoning += replay }
            let detailText = (delta["reasoning_details"] as? [[String: Any]])?.compactMap { ($0["text"] as? String) ?? ($0["summary"] as? String) }.joined()
            let thought = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? detailText
            if let thought { snapshot.reasoningCharacters += thought.unicodeScalars.count; if (delta["content"] as? String)?.isEmpty != false { snapshot.phase = .reasoning } }
            if let text = delta["refusal"] as? String { refusal += text }
            if let rawCalls = delta["tool_calls"], !(rawCalls is NSNull) {
                guard let fragments = rawCalls as? [[String: Any]] else { throw invalid("模型工具分片格式无效。") }
                guard fragments.count <= 32 else { throw invalid("模型工具调用分片过多。") }
                for fragment in fragments {
                    guard let rawIndex = fragment["index"] as? NSNumber, CFGetTypeID(rawIndex) != CFBooleanGetTypeID(),
                          rawIndex.doubleValue.rounded() == rawIndex.doubleValue, (0..<32).contains(rawIndex.intValue) else { throw invalid("模型工具调用分片序号无效。") }
                    let index = rawIndex.intValue
                    var call = calls[index] ?? Call()
                    if let id = fragment["id"] as? String { call.id += id }
                    if let type = fragment["type"] as? String { guard type == "function" else { throw invalid("模型工具类型无效。") }; call.type = type }
                    if let function = fragment["function"] as? [String: Any] {
                        if let name = function["name"] as? String { call.name += name }
                        if let arguments = function["arguments"] as? String { call.arguments += arguments }
                    }
                    guard call.id.utf8.count <= 800, call.name.utf8.count <= 800, call.arguments.utf8.count <= 512 * 1024 else { throw invalid("模型工具参数超过允许范围。") }
                    calls[index] = call
                }
                if !fragments.isEmpty { snapshot.phase = .receivingTools }
            }
        } else if let rawDelta = choice["delta"], !(rawDelta is NSNull) { throw invalid("模型文本分片格式无效。") }
        if let reason = choice["finish_reason"] as? String {
            guard finishReason == nil || finishReason == reason else { throw invalid("模型完成标记不一致。") }
            finishReason = reason
        }
    }
    private func invalid(_ message: String) -> ReadingError { .invalid(message) }
}

/// Some compatible gateways return JSON even when streaming was requested.
/// Sniff missing Content-Type headers without ever accepting an incomplete SSE
/// event as a finished JSON response.
final class ProviderStreamingResponse: @unchecked Sendable {
    let decoder = ProviderStreamDecoder()
    private var streaming: Bool?
    private var prefix = Data()
    private var bytes = 0
    var onBufferedProgress: ((Int) -> Void)?
    func setContentType(_ mimeType: String?) {
        if mimeType?.lowercased() == "text/event-stream" { streaming = true }
        else if mimeType?.lowercased().contains("json") == true { streaming = false }
    }
    func append(_ data: Data) throws {
        bytes += data.count
        if streaming == true { try decoder.append(data); return }
        if streaming == false { onBufferedProgress?(bytes); return }
        prefix.append(data)
        let start = String(decoding: prefix.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if start.hasPrefix("data:") || start.hasPrefix(":") || start.hasPrefix("event:") || start.hasPrefix("id:") {
            streaming = true; try decoder.append(prefix); prefix.removeAll()
        } else if start.hasPrefix("{") || start.hasPrefix("[") || prefix.count > 256 {
            streaming = false; prefix.removeAll()
        }
        if streaming != true { onBufferedProgress?(bytes) }
    }
    func finish() throws -> (ProviderClient.Message, String, Int?)? {
        if streaming == true { return try decoder.finish() }
        return nil
    }
}
