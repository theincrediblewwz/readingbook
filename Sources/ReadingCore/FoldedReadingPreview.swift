import Foundation

/// A short display hint, never a second saved copy or a context summary.
/// Parsing is bounded; the canonical message/Markdown is not rewritten.
public enum FoldedReadingPreview {
    public static func make(_ source: String, title: String = "", limit: Int = 90) -> String {
        guard limit > 0 else { return "" }
        let bounded = String(source.prefix(4097))
        let wasTruncated = bounded.count > 4096
        var value = String(bounded.prefix(4096))
        value = value.replacingOccurrences(of: "<!--[\\s\\S]*?(?:-->|$)", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "!?\\[([^\\]\\n]+)\\]\\([^\\n]*?(?:\\)|$)", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?m)^\\s{0,3}(?:#{1,6}\\s+|>\\s*)", with: "", options: .regularExpression)
        var lines = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let first = lines.first, first == title.trimmingCharacters(in: .whitespacesAndNewlines) { lines.removeFirst() }
        value = lines.joined(separator: " ").replacingOccurrences(of: "[\\t\\r\\n ]+", with: " ", options: .regularExpression)
        let prefix = String(value.prefix(limit))
        return prefix + (value.count > limit || wasTruncated ? "…" : "")
    }
}
