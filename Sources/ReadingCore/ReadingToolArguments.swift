import Foundation
import CoreFoundation

/// Diagnostics describe only the model's own bounded argument text. They do
/// not repair it, read book data, or grant permission to execute a tool.
struct ReadingToolArgumentError: LocalizedError {
    let issues: [[String: Any]]
    let rawArguments: Data?
    var errorDescription: String? { "工具参数有格式错误；请按位置局部修正，已保存成果保留。" }
}

enum ReadingToolArguments {
    static func parse(_ data: Data, maximumBytes: Int) throws -> [String: Any] {
        guard data.count <= maximumBytes else { throw ReadingError.invalid("工具参数超过大小上限，未执行。") }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch {
            let text = String(decoding: data, as: UTF8.self)
            var issue: [String: Any] = ["kind": "json_syntax", "reason": "参数不是完整的JSON；只修正标点或受影响的短文字，不重做已保存资料。"]
            if let mismatch = delimiterMismatch(Array(data)) {
                let prefix = String(decoding: data.prefix(mismatch.offset), as: UTF8.self)
                issue["line"] = prefix.filter { $0 == "\n" }.count + 1
                issue["column"] = (prefix.split(separator: "\n", omittingEmptySubsequences: false).last?.unicodeScalars.count ?? 0) + 1
                issue["expected"] = mismatch.expected
                issue["actual"] = mismatch.offset < data.count ? String(UnicodeScalar(data[data.startIndex + mismatch.offset])) : "end_of_input"
                // String indices keep Unicode intact, including near an EOF.
                let end = text.index(text.startIndex, offsetBy: min(prefix.count, text.count))
                let start = text.index(end, offsetBy: -min(96, text.distance(from: text.startIndex, to: end)))
                issue["near"] = String(text[start...].prefix(160))
            } else {
                let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                issue["reason"] = String((reason ?? "JSON标点、引号或值不完整；请检查原始参数。").prefix(240))
                issue["near"] = String(text.suffix(160))
            }
            if let edit = closingTextEdit(data) { issue["suggestedTextEdits"] = [edit] }
            throw ReadingToolArgumentError(issues: [issue], rawArguments: data)
        }
        guard let object = value as? [String: Any] else {
            throw ReadingToolArgumentError(issues: [["kind": "root_type", "path": "", "expected": "object", "actualType": jsonType(value)]], rawArguments: data)
        }
        return object
    }

    /// Offer only a closing-delimiter suffix replacement that Foundation can
    /// already parse. No keys, values, names, quotes or source text are added.
    /// This is a suggestion for an explicit repair call, never execution.
    private static func closingTextEdit(_ data: Data) -> [String: String]? {
        let bytes = Array(data)
        var tail = bytes.count
        while tail > 0, [UInt8(125),93,32,9,10,13].contains(bytes[tail-1]) { tail -= 1 }
        guard bytes.count - tail <= 128 else { return nil }
        var stack = [UInt8](), quoted = false, escaped = false
        for byte in bytes.prefix(tail) {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { stack.append(125) }
            else if byte == 91 { stack.append(93) }
            else if byte == 125 || byte == 93 {
                guard stack.popLast() == byte else { return nil }
            }
        }
        guard !quoted, !stack.isEmpty, stack.count <= 128 else { return nil }
        let prefix = String(decoding: bytes.prefix(tail), as: UTF8.self)
        let closing = String(decoding: stack.reversed(), as: UTF8.self)
        let candidate = prefix + closing
        guard let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)), object is [String: Any] else { return nil }
        let original = String(decoding: data, as: UTF8.self), context = String(prefix.suffix(96))
        let before = context + String(decoding: bytes.dropFirst(tail), as: UTF8.self)
        guard !before.isEmpty, let match = original.range(of: before, options: .literal),
              original.range(of: before, options: .literal, range: original.index(after: match.lowerBound)..<original.endIndex) == nil else { return nil }
        return ["before": before, "after": context + closing]
    }

    /// A delimiter hint, not a second JSON parser. Foundation remains the
    /// authority for numbers, escapes, separators and all other grammar.
    private static func delimiterMismatch(_ bytes: [UInt8]) -> (offset: Int, expected: String)? {
        var stack: [UInt8] = [], quoted = false, escaped = false
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true; continue }
            if byte == 123 { stack.append(125) }
            else if byte == 91 { stack.append(93) }
            else if byte == 125 || byte == 93 {
                guard let next = stack.last else { return (index, "end_of_input") }
                guard next == byte else { return (index, String(UnicodeScalar(next))) }
                stack.removeLast()
            }
        }
        if quoted { return (bytes.count, "\"") }
        if let next = stack.last { return (bytes.count, String(UnicodeScalar(next))) }
        return nil
    }

    static func decoding(_ error: DecodingError, original: [String: Any], prefix: [String]) -> ReadingToolArgumentError {
        let keys: [CodingKey], expected: String, reason: String
        switch error {
        case let .typeMismatch(type, context): keys = context.codingPath; expected = String(describing: type); reason = context.debugDescription
        case let .valueNotFound(type, context): keys = context.codingPath; expected = String(describing: type); reason = context.debugDescription
        case let .keyNotFound(key, context): keys = context.codingPath + [key]; expected = "required field"; reason = context.debugDescription
        case let .dataCorrupted(context): keys = context.codingPath; expected = "valid declared value"; reason = context.debugDescription
        @unknown default: keys = []; expected = "valid declared value"; reason = "参数无法解码。"
        }
        let tokens = prefix + keys.map { $0.intValue.map(String.init) ?? $0.stringValue }
        var current: Any? = original
        for token in tokens {
            if let object = current as? [String: Any] { current = object[token] }
            else if let array = current as? [Any], let index = Int(token), array.indices.contains(index) { current = array[index] }
            else { current = nil; break }
        }
        let pointer = tokens.map { "/" + $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined()
        return .init(issues: [["kind": "field_decode", "path": pointer, "expected": expected,
            "actualType": current.map(jsonType) ?? "missing", "reason": String(reason.prefix(300))]], rawArguments: nil)
    }

    private static func jsonType(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        if value is String { return "string" }
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number" }
        return "unknown"
    }
}
