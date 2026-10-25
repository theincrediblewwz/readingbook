import Foundation

/// Disposable reading affordances. A sentence becomes saved analysis only
/// after the reader explicitly asks for a translation and the host commits it.
public enum ReadingSentenceAnchors {
    public static func ranges(in text: String, maximumUTF16Length: Int = 1600) -> [NSRange] {
        guard !text.isEmpty, maximumUTF16Length >= 64 else { return [] }
        var result: [NSRange] = [], start = text.startIndex, cursor = start
        var count = 0, mathWidth = 0, fenced = false, inlineCode = false
        let closing: Set<Character> = ["”", "’", "」", "』", "\"", "'", "）", ")", "】", "]"]
        func append(_ end: String.Index) {
            var left = start, right = end
            while left < right, text[left].isWhitespace { left = text.index(after: left) }
            while left < right { let previous = text.index(before: right); if !text[previous].isWhitespace { break }; right = previous }
            if left < right { result.append(NSRange(left..<right, in: text)) }
        }
        while cursor < text.endIndex {
            if Task.isCancelled { return [] }
            let value = text[cursor], next = text.index(after: cursor)
            count += String(value).utf16.count
            if value == "`", text[cursor...].hasPrefix("```") { fenced.toggle(); cursor = text.index(cursor, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex; continue }
            if value == "`", !fenced { inlineCode.toggle() }
            if value == "$", !fenced, !inlineCode, (cursor == text.startIndex || text[text.index(before: cursor)] != "\\") {
                let width = next < text.endIndex && text[next] == "$" ? 2 : 1
                let after = width == 2 ? text.index(after: next) : next
                if mathWidth == width { mathWidth = 0 }
                else if mathWidth == 0, text[after...].range(of: width == 2 ? "$$" : "$") != nil { mathWidth = width }
                if width == 2 { cursor = after; continue }
            }
            let decimal = value == "." && cursor > start && next < text.endIndex && text[text.index(before: cursor)].isNumber && text[next].isNumber
            let punctuation = "。！？!?；;".contains(value) || (value == "." && !decimal && (next == text.endIndex || text[next].isWhitespace || closing.contains(text[next])))
            let paragraph = value == "\n" && (next == text.endIndex || text[next] == "\n")
            if !fenced && !inlineCode && mathWidth == 0 && (punctuation || paragraph || count >= maximumUTF16Length) {
                var end = next
                while end < text.endIndex, closing.contains(text[end]) { end = text.index(after: end) }
                append(end); start = end; cursor = end; count = 0
            } else { cursor = next }
        }
        if start < text.endIndex { append(text.endIndex) }
        return result
    }

    public static func anchors(in unit: SourceUnit, project: BookProject, maximum: Int = 2000) -> [SourceAnchor] {
        var result: [SourceAnchor] = []
        for value in ranges(in: unit.text).prefix(max(0, min(2000, maximum))) {
            guard !Task.isCancelled, let range = Range(value, in: unit.text) else { break }
            // Keep the same stable identity and literal validation as saved
            // anchors. Ambiguous excerpts are skipped instead of guessed.
            let quote = String(unit.text[range])
            let prefix = String(unit.text[..<range.lowerBound].suffix(200))
            let suffix = String(unit.text[range.upperBound...].prefix(200))
            if let anchor = try? ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: unit.id,
                quote: quote, prefix: prefix, suffix: suffix, in: project) { result.append(anchor) }
        }
        return result
    }

    /// Actual visible pages have priority; only a small neighboring window is
    /// prefetched, so a large document never causes a full-book geometry pass.
    public static func pageWindow(current: Int, visible: [Int], available: Set<Int>, maximum: Int = 12) -> [Int] {
        let limit = max(1, min(32, maximum))
        let shown = Set(visible.filter { $0 > 0 && available.contains($0) }).union(available.contains(current) ? [current] : [])
        let prioritized = shown.sorted { abs($0 - current) == abs($1 - current) ? $0 < $1 : abs($0 - current) < abs($1 - current) }
        let neighbors = Set(shown.flatMap { [$0 - 1, $0 + 1] }).subtracting(shown).filter { $0 > 0 && available.contains($0) }
            .sorted { abs($0 - current) == abs($1 - current) ? $0 < $1 : abs($0 - current) < abs($1 - current) }
        return Array((prioritized + neighbors).prefix(limit))
    }
}
