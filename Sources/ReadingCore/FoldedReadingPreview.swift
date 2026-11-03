import Foundation

/// A short display hint, never a second saved copy or a context summary.
/// Parsing is bounded; the canonical message/Markdown is not rewritten.
public enum FoldedReadingPreview {
    // NSRegularExpression instances are immutable. Reuse compiled display
    // rules across rows instead of compiling them for each folded answer.
    private static let comment = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?(?:-->|$)")
    private static let link = try! NSRegularExpression(pattern: "!?\\[([^\\]\\n]+)\\]\\([^\\n]*?(?:\\)|$)")
    private static let strong = try! NSRegularExpression(pattern: #"(\*\*|__|~~)(\S(?:[^\n]*?\S)?)\1"#)
    private static let heading = try! NSRegularExpression(pattern: "(?m)^\\s{0,3}(?:#{1,6}\\s+|>\\s*)")
    private static let whitespace = try! NSRegularExpression(pattern: "[\\t\\r\\n ]+")
    private static func replace(_ rule: NSRegularExpression, in value: String, with replacement: String) -> String {
        rule.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: replacement)
    }
    public static func make(_ source: String, title: String = "", limit: Int = 90) -> String {
        guard limit > 0, !source.isEmpty else { return "" }
        let bounded = String(source.prefix(4097))
        let wasTruncated = bounded.count > 4096
        var value = String(bounded.prefix(4096))
        value = replace(comment, in: value, with: "")
        // Reuse the citation renderer's code/math/escape rules. Its temporary
        // display links are immediately reduced to labels below, never saved.
        if value.contains("[unit:") || value.contains("[doc:") || value.contains("[message:") {
            value = MarkdownReferenceLinks.render(value, bookID: "folded-preview", labelForReference: { kind, _ in
                switch kind { case "unit": return "原文"; case "document": return "笔记"; case "message": return "历史对话"; default: return nil }
            })
        }
        value = replace(link, in: value, with: "$1")
        value = replace(strong, in: value, with: "$2")
        value = replace(heading, in: value, with: "")
        var lines = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let first = lines.first, first == title.trimmingCharacters(in: .whitespacesAndNewlines) { lines.removeFirst() }
        value = replace(whitespace, in: lines.joined(separator: " "), with: " ")
        let prefix = String(value.prefix(limit))
        return prefix + (value.count > limit || wasTruncated ? "…" : "")
    }
}
