import Foundation

extension ReadingAnswerEngine {
    /// Only expand written identities. No range expansion, prefix guessing or
    /// book lookup; citations() still checks every resulting ID against the
    /// excerpts actually supplied to this final request.
    static func separatedCitationMarks(_ content: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\[(unit|doc|message):([^\\]\\r\\n]+)\\]"),
              let identity = try? NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$") else { return content }
        let original = content as NSString
        var result = content
        let separators = CharacterSet(charactersIn: "、,，;；")
        for match in regex.matches(in: content, range: NSRange(location: 0, length: original.length)).reversed() {
            let kind = original.substring(with: match.range(at: 1)), body = original.substring(with: match.range(at: 2))
            let parts = body.components(separatedBy: separators)
            guard (2...16).contains(parts.count) else { continue }
            let ids = parts.map { part -> String in
                let value = part.trimmingCharacters(in: .whitespaces)
                return value.hasPrefix(kind + ":") ? String(value.dropFirst(kind.count + 1)) : value
            }
            guard ids.allSatisfy({ identity.firstMatch(in: $0, range: NSRange($0.startIndex..<$0.endIndex, in: $0)) != nil }),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: ids.map { "[\(kind):\($0)]" }.joined())
        }
        return result
    }

    /// Give a format-repair request the missing identities, not another vague
    /// rejection. This reveals no new book data and grants no extra evidence.
    static func citationRepairGuide(_ content: String, session: ReadingQuerySession) throws -> String {
        let rows = ["unit": session.sourceExcerpts, "doc": session.documentExcerpts, "message": session.conversationExcerpts]
        let supplied = rows.mapValues { Array(Set($0.filter { !$0.1.isEmpty }.map { $0.0 })).sorted() }
        let regex = try NSRegularExpression(pattern: "\\[(unit|doc|message):([^\\]\\r\\n]+)\\]")
        let original = content as NSString
        var invalid: [[String: String]] = []
        for mark in regex.matches(in: content, range: NSRange(location: 0, length: original.length)) {
            let kind = original.substring(with: mark.range(at: 1)), id = original.substring(with: mark.range(at: 2))
            if !(supplied[kind]?.contains(id) ?? false), invalid.count < 12 {
                invalid.append(["kind": kind, "id": String(id.prefix(200)), "reason": "不在下方这次实际提供的片段中；请移除依赖它的结论或改用下方确有依据的片段，不猜编号。"])
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "invalidCitationMarks": invalid, "suppliedCitationIDs": supplied.mapValues { Array($0.prefix(64)) },
            "suppliedIDsTruncated": supplied.mapValues { $0.count > 64 },
            "format": "每个出处独立写[unit:原样ID]、[doc:原样ID]或[message:原样ID]；无须把多个编号放在一个括号中。"
        ], options: [.sortedKeys]), as: UTF8.self)
    }
}
