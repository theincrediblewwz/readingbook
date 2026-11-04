import Foundation

/// A narrow compatibility decoder for documented DeepSeek V4/V4.1 DSML.
/// Only an entire assistant tool envelope, for this turn's offered component
/// tools, can be normalized. No prose, source text, arbitrary tools or writes
/// are interpreted here. Normal query validation/admission still follows.
enum ReadingComponentProtocol {
    static func recover(_ content: String, model: String, allowedNames: Set<String>) -> [ProviderClient.ToolCall]? {
        guard model.lowercased().split(separator: "/").last?.hasPrefix("deepseek-v4") == true,
              content.utf8.count <= 32_768 else { return nil }
        var input = Cursor(text: content.trimmingCharacters(in: .whitespacesAndNewlines))
        let space: String, root: String
        if input.consume("<｜DSML｜ calls>") { space = " "; root = "calls" }
        else if input.consume("<｜DSML｜tool_calls>") { space = ""; root = "tool_calls" }
        else { return nil }
        var values: [(String, Data)] = []
        while true {
            input.skipWhitespace()
            if input.consume("</｜DSML｜" + space + root + ">") { break }
            guard values.count < 8, input.consume("<｜DSML｜" + space + "invoke name=\""),
                  let name = input.take(until: "\"", maximumBytes: 80), input.consume(">"),
                  ReadingQueryToolCatalog.componentNames.contains(name), allowedNames.contains(name) else { return nil }
            var arguments: [String: Any] = [:]
            while true {
                input.skipWhitespace()
                if input.consume("</｜DSML｜" + space + "invoke>") { break }
                guard arguments.count < 4, input.consume("<｜DSML｜" + space + "parameter name=\""),
                      let key = input.take(until: "\"", maximumBytes: 40), !key.isEmpty, arguments[key] == nil,
                      input.consume(" string=\""), let string = input.take(until: "\"", maximumBytes: 5),
                      ["true", "false"].contains(string), input.consume(">"),
                      let value = input.take(until: "</｜DSML｜" + space + "parameter>", maximumBytes: 32_768) else { return nil }
                if string == "true" { arguments[key] = value }
                else {
                    guard let decoded = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]), !(decoded is NSNull) else { return nil }
                    arguments[key] = decoded
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else { return nil }
            do {
                if name == "components_list" { _ = try ReadingComponentDirectoryRequest.decode(data) }
                else { _ = try ReadingComponentRequest.decode(data) }
            } catch { return nil }
            values.append((name, data))
        }
        input.skipWhitespace()
        guard input.isAtEnd, !values.isEmpty else { return nil }
        return values.map { name, data in .init(id: "component-" + UUID().uuidString, type: "function",
            function: .init(name: name, arguments: String(decoding: data, as: UTF8.self))) }
    }
    private struct Cursor {
        let text: String
        var offset: String.Index
        init(text: String) { self.text = text; offset = text.startIndex }
        var isAtEnd: Bool { offset == text.endIndex }
        mutating func skipWhitespace() {
            while offset < text.endIndex, text[offset].isWhitespace { offset = text.index(after: offset) }
        }
        mutating func consume(_ token: String) -> Bool {
            guard text[offset...].hasPrefix(token) else { return false }
            offset = text.index(offset, offsetBy: token.count); return true
        }
        mutating func take(until token: String, maximumBytes: Int) -> String? {
            guard let range = text.range(of: token, options: [.literal], range: offset..<text.endIndex) else { return nil }
            let value = String(text[offset..<range.lowerBound])
            guard value.utf8.count <= maximumBytes else { return nil }
            offset = range.upperBound; return value
        }
    }
}
