import Foundation

/// A collapsed knowledge row shows only a short preview. Keep the original
/// full-text search path; unqueried long prose needs just its visible prefix.
public enum ReadingKnowledgeExcerpt {
    public static func make(_ markdown: String, query: String) -> String {
        guard query.isEmpty, markdown.utf8.count > 4096 else { return fullExcerpt(markdown, query: query) }
        let scalars = markdown.unicodeScalars, whitespace = CharacterSet.whitespacesAndNewlines
        guard let first = scalars.firstIndex(where: { !whitespace.contains($0) }),
              let last = scalars.lastIndex(where: { !whitespace.contains($0) }) else { return "" }
        let end = scalars.index(after: last), trimmed = markdown[first..<end]
        var length = 128
        while true {
            let prefix = trimmed.prefix(length)
            let normalized = prefix.replacingOccurrences(of: "\n", with: " ")
            // Appending text may join the final grapheme. An extra complete
            // output grapheme keeps the first120 stable across that boundary.
            if normalized.count > 120 || prefix.endIndex == trimmed.endIndex { return String(normalized.prefix(120)) }
            length *= 2
        }
    }
    private static func fullExcerpt(_ markdown: String, query: String) -> String {
        let compact = markdown.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let match = compact.range(of: query, options: .caseInsensitive) else { return String(compact.prefix(120)) }
        let start = compact.index(match.lowerBound, offsetBy: -30, limitedBy: compact.startIndex) ?? compact.startIndex
        return (start == compact.startIndex ? "" : "…") + String(compact[start...].prefix(120))
    }
}
