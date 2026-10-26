import Foundation

public enum ReadingSentenceSyntax: Equatable, Sendable {
    case plainText, markdown
}

/// Precompute once per source unit, then check old passage anchors without
/// rescanning the page for each saved translation or decoration.
public struct ReadingPassageBoundaryIndex: Sendable {
    private let length: Int
    private let boundaries: [Int]
    private let regions: [NSRange]?
    fileprivate init(length: Int, boundaries: [Int], regions: [NSRange]? = nil) {
        self.length = length; self.boundaries = boundaries; self.regions = regions
    }
    public func crossesStructuralBoundary(_ range: NSRange) -> Bool {
        guard range.location >= 0, range.length > 0, range.location <= length, range.length <= length - range.location else { return true }
        let end = range.location + range.length
        if let regions {
            var low = 0, high = regions.count
            while low < high {
                let middle = low + (high - low) / 2
                if regions[middle].location <= range.location { low = middle + 1 } else { high = middle }
            }
            guard low > 0, end <= NSMaxRange(regions[low - 1]) else { return true }
        }
        var low = 0, high = boundaries.count
        while low < high {
            let middle = low + (high - low) / 2
            if boundaries[middle] <= range.location { low = middle + 1 } else { high = middle }
        }
        return low < boundaries.count && boundaries[low] < end
    }
}

/// Disposable reading affordances. A sentence becomes saved analysis only
/// after the reader explicitly asks for a translation and the host commits it.
public enum ReadingSentenceAnchors {
    public static func syntax(for unit: SourceUnit, in project: BookProject) -> ReadingSentenceSyntax {
        let ext = URL(fileURLWithPath: project.originalName).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return .markdown }
        if let page = unit.page, project.ocrPages?.contains(where: { $0.page == page }) == true { return .markdown }
        return .plainText
    }

    public static func ranges(in text: String, maximumUTF16Length: Int = 1600, chapterTitle: String? = nil,
                              syntax: ReadingSentenceSyntax = .plainText) -> [NSRange] {
        guard maximumUTF16Length >= 64, !Task.isCancelled else { return [] }
        guard syntax == .markdown, ReadingMarkdownStructure.needsStructure(text) else {
            return scan(text, maximumUTF16Length: maximumUTF16Length, chapterTitle: chapterTitle).ranges
        }
        guard let blocks = ReadingMarkdownStructure.blocks(in: text, displayMath: { breaks in
            scan(text, maximumUTF16Length: maximumUTF16Length, chapterTitle: chapterTitle,
                 collectRanges: false, displayMathOnly: true, codeSpanBreaks: breaks).displayMath
        }), !Task.isCancelled else { return [] }
        let source = text as NSString
        var result: [NSRange] = []
        for block in blocks where block.annotates {
            guard !Task.isCancelled else { return [] }
            let content = source.substring(with: block.range)
            if block.atomic {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let local = content.range(of: trimmed, options: .literal) {
                    let value = NSRange(local, in: content)
                    result.append(NSRange(location: block.range.location + value.location, length: value.length))
                }
            } else {
                for value in scan(content, maximumUTF16Length: maximumUTF16Length, chapterTitle: chapterTitle).ranges {
                    result.append(NSRange(location: block.range.location + value.location, length: value.length))
                }
            }
        }
        // The block map is a disposable view over exactly this source string.
        return result.filter { $0.location <= source.length && $0.length <= source.length - $0.location }
    }

    public static func boundaryIndex(in text: String, chapterTitle: String? = nil,
                                     syntax: ReadingSentenceSyntax = .plainText) -> ReadingPassageBoundaryIndex {
        guard !Task.isCancelled else { return ReadingPassageBoundaryIndex(length: -1, boundaries: []) }
        if syntax == .markdown, ReadingMarkdownStructure.needsStructure(text) {
            guard let blocks = ReadingMarkdownStructure.blocks(in: text, displayMath: { breaks in
                scan(text, maximumUTF16Length: 1600, chapterTitle: chapterTitle,
                     collectRanges: false, displayMathOnly: true, codeSpanBreaks: breaks).displayMath
            }), !Task.isCancelled else {
                return ReadingPassageBoundaryIndex(length: -1, boundaries: [])
            }
            let source = text as NSString
            var boundaries: [Int] = []
            for block in blocks {
                guard !Task.isCancelled else { return ReadingPassageBoundaryIndex(length: -1, boundaries: []) }
                if !block.atomic {
                    boundaries += scan(source.substring(with: block.range), maximumUTF16Length: 1600, chapterTitle: chapterTitle, collectRanges: false).boundaries.map { block.range.location + $0 }
                }
            }
            guard !Task.isCancelled else { return ReadingPassageBoundaryIndex(length: -1, boundaries: []) }
            return ReadingPassageBoundaryIndex(length: text.utf16.count, boundaries: Array(Set(boundaries)).sorted(), regions: blocks.map(\.range))
        }
        guard !Task.isCancelled else { return ReadingPassageBoundaryIndex(length: -1, boundaries: []) }
        let value = scan(text, maximumUTF16Length: 1600, chapterTitle: chapterTitle, collectRanges: false)
        guard !Task.isCancelled else { return ReadingPassageBoundaryIndex(length: -1, boundaries: []) }
        return ReadingPassageBoundaryIndex(length: text.utf16.count, boundaries: value.boundaries)
    }

    private static func scan(_ text: String, maximumUTF16Length: Int, chapterTitle: String?, collectRanges: Bool = true,
                             displayMathOnly: Bool = false, codeSpanBreaks: [Int] = []) -> (ranges: [NSRange], boundaries: [Int], displayMath: [NSRange]) {
        guard !text.isEmpty, maximumUTF16Length >= 64 else { return ([], [], []) }
        var result: [NSRange] = [], boundaries: [Int] = [], math: [NSRange] = [], start = text.startIndex, cursor = start, lineStart = start
        var count = 0, mathWidth = 0, lineOnlyWhitespace = true
        var fenceMarker: Character?, fenceWidth = 0, escapedMathEnd: String?
        var mathStart: String.Index?
        // A missing closer must not rescan the remaining source for every
        // malformed opener. There are only two escaped delimiters; remember
        // each one's last occurrence once for this immutable scan.
        var lastMathClosers: [String: String.Index] = [:], absentMathClosers = Set<String>()
        func hasMathCloser(_ delimiter: String, after start: String.Index) -> Bool {
            if let last = lastMathClosers[delimiter] { return last >= start }
            if absentMathClosers.contains(delimiter) { return false }
            guard let last = text.range(of: delimiter, options: [.literal, .backwards])?.lowerBound else {
                absentMathClosers.insert(delimiter); return false
            }
            lastMathClosers[delimiter] = last; return last >= start
        }
        let codeSpanEnds = text.contains("`") ? backtickSpanEnds(in: text, structuralBreaks: codeSpanBreaks) : [:]
        let closing: Set<Character> = ["”", "’", "」", "』", "\"", "'", "）", ")", "】", "]"]
        func append(_ end: String.Index) {
            guard collectRanges else { return }
            var left = start, right = end
            while left < right, text[left].isWhitespace { left = text.index(after: left) }
            while left < right { let previous = text.index(before: right); if !text[previous].isWhitespace { break }; right = previous }
            if left < right { result.append(NSRange(left..<right, in: text)) }
        }
        while cursor < text.endIndex {
            if Task.isCancelled { return ([], [], []) }
            let fenced = fenceMarker != nil
            if cursor == lineStart, !fenced, mathWidth == 0, escapedMathEnd == nil,
               let end = headingEnd(in: text, at: cursor, chapterTitle: chapterTitle) {
                append(cursor)
                start = cursor; append(end)
                let range = NSRange(cursor..<end, in: text)
                boundaries.append(range.location); boundaries.append(NSMaxRange(range))
                start = end; cursor = end; count = 0; lineOnlyWhitespace = false
                continue
            }
            let value = text[cursor], next = text.index(after: cursor)
            let lineWasWhitespace = lineOnlyWhitespace
            if value.isNewline { lineStart = next; lineOnlyWhitespace = true }
            else if !value.isWhitespace { lineOnlyWhitespace = false }
            count += String(value).utf16.count
            if (value == "`" || value == "~"), mathWidth == 0, escapedMathEnd == nil, lineWasWhitespace {
                let end = text[cursor...].prefix(while: { $0 == value }).endIndex
                let width = text[cursor..<end].count
                if width >= 3 {
                    if !fenced { fenceMarker = value; fenceWidth = width }
                    else if fenceMarker == value, width >= fenceWidth, line(in: text, at: end).value.isEmpty { fenceMarker = nil; fenceWidth = 0 }
                    cursor = end; continue
                }
            }
            if value == "`", !fenced, mathWidth == 0, escapedMathEnd == nil {
                // Outside code an escape consumes just this tick. The rest
                // of a longer run may still open a shorter code span.
                if isEscaped(in: text, at: cursor) { cursor = next; continue }
                let runEnd = text[cursor...].prefix(while: { $0 == "`" }).endIndex
                if let end = codeSpanEnds[cursor] {
                    let span = text[cursor..<end]
                    count += span.utf16.count - 1 // The first delimiter was counted above.
                    if let newline = span.lastIndex(where: \.isNewline) { lineStart = text.index(after: newline) }
                    cursor = end; lineOnlyWhitespace = false; continue
                }
                // An unmatched run is literal text. Its second tick cannot
                // become a different opener unless the first was escaped.
                count += text[cursor..<runEnd].utf16.count - 1
                cursor = runEnd; continue
            }
            if value == "\\", !fenced, mathWidth == 0,
               (cursor == text.startIndex || text[text.index(before: cursor)] != "\\") {
                if let end = escapedMathEnd, text[cursor...].hasPrefix(end) {
                    let after = text.index(cursor, offsetBy: 2)
                    if end == "\\]", let begin = mathStart { math.append(NSRange(begin..<after, in: text)) }
                    escapedMathEnd = nil; mathStart = nil; cursor = after; continue
                }
                if escapedMathEnd == nil {
                    for (begin, end) in [("\\[", "\\]"), ("\\(", "\\)")] where text[cursor...].hasPrefix(begin) {
                        if displayMathOnly && begin == "\\(" { continue }
                        if hasMathCloser(end, after: text.index(cursor, offsetBy: 2)) {
                            escapedMathEnd = end; mathStart = cursor; cursor = text.index(cursor, offsetBy: 2); break
                        }
                    }
                    if escapedMathEnd != nil { continue }
                }
            }
            if value == "$", !fenced, escapedMathEnd == nil, (cursor == text.startIndex || text[text.index(before: cursor)] != "\\") {
                let width = next < text.endIndex && text[next] == "$" ? 2 : 1
                let after = width == 2 ? text.index(after: next) : next
                // A currency dollar or unmatched inline opener in a previous
                // paragraph cannot hide a later display-block opener. This
                // prepass only discovers display atoms; normal scans retain
                // their existing inline-math handling.
                if displayMathOnly && width == 1 { cursor = next; continue }
                if mathWidth == width {
                    if width == 2, let begin = mathStart { math.append(NSRange(begin..<after, in: text)) }
                    mathWidth = 0; mathStart = nil
                }
                else if mathWidth == 0, text[after...].range(of: width == 2 ? "$$" : "$") != nil { mathWidth = width; mathStart = cursor }
                if width == 2 { cursor = after; continue }
            }
            let decimal = value == "." && cursor > start && next < text.endIndex && text[text.index(before: cursor)].isNumber && text[next].isNumber
            let punctuation = "。！？!?；;".contains(value) || (value == "." && !decimal && (next == text.endIndex || text[next].isWhitespace || closing.contains(text[next])))
            let paragraph = value.isNewline && (lineWasWhitespace || next == text.endIndex || text[next].isNewline)
            if !fenced && mathWidth == 0 && escapedMathEnd == nil && (punctuation || paragraph || count >= maximumUTF16Length) {
                var end = next
                while end < text.endIndex, closing.contains(text[end]) { end = text.index(after: end) }
                append(end); start = end; cursor = end; count = 0
            } else { cursor = next }
        }
        if start < text.endIndex { append(text.endIndex) }
        return (result, Array(Set(boundaries)).sorted(), math)
    }

    /// Each backtick run knows the end of the next equal-width run. This makes
    /// unmatched runs literal without repeatedly searching the remaining page.
    /// Blank lines, ATX headings and fenced-block boundaries cannot be crossed
    /// by an inline code span. Backslashes are checked only at an opener: inside code they
    /// are literal and may precede a closing run.
    private static func backtickSpanEnds(in text: String, structuralBreaks: [Int] = []) -> [String.Index: String.Index] {
        var result: [String.Index: String.Index] = [:], pending: [Int: [String.Index]] = [:]
        // UTF16 source-line endpoints are already sorted. Convert them in one
        // scalar pass, rather than seeking from the String prefix per block.
        // A quote/list boundary resets unmatched code delimiters even when
        // CommonMark allows code spans across soft or lazy line breaks.
        var breaks = Set<String.Index>()
        if !structuralBreaks.isEmpty {
            var boundary = 0, offset = 0
            for index in text.unicodeScalars.indices {
                if Task.isCancelled { return [:] }
                while boundary < structuralBreaks.count, structuralBreaks[boundary] < offset { boundary += 1 }
                if boundary < structuralBreaks.count, structuralBreaks[boundary] == offset { breaks.insert(index) }
                offset += text.unicodeScalars[index].value > 0xffff ? 2 : 1
            }
        }
        var cursor = text.startIndex, lineOnlyWhitespace = true, atLineStart = true, headingLine = false
        while cursor < text.endIndex {
            if Task.isCancelled { return [:] }
            if breaks.contains(cursor) { pending.removeAll(keepingCapacity: true) }
            if atLineStart {
                let sourceLine = line(in: text, at: cursor)
                let value = text[cursor..<sourceLine.end], spaces = value.prefix(while: { $0 == " " }).count
                let content = value.dropFirst(spaces), hashes = content.prefix(while: { $0 == "#" }).count
                let tail = content.dropFirst(hashes)
                headingLine = spaces <= 3 && (1...6).contains(hashes) && (tail.isEmpty || tail.first == " " || tail.first == "\t")
                if headingLine { pending.removeAll(keepingCapacity: true) }
                atLineStart = false
            }
            let value = text[cursor]
            if value.isNewline {
                if lineOnlyWhitespace || headingLine { pending.removeAll(keepingCapacity: true) }
                cursor = text.index(after: cursor); lineOnlyWhitespace = true; atLineStart = true; continue
            }
            if value == "`" || value == "~" {
                let end = text[cursor...].prefix(while: { $0 == value }).endIndex
                let width = text[cursor..<end].count
                if width >= 3, lineOnlyWhitespace {
                    pending.removeAll(keepingCapacity: true)
                } else if value == "`" {
                    for previous in pending[width] ?? [] { result[previous] = end }
                    pending[width] = [cursor]
                    if width > 1, isEscaped(in: text, at: cursor) {
                        pending[width - 1, default: []].append(text.index(after: cursor))
                    }
                }
                cursor = end; lineOnlyWhitespace = false
            } else {
                if !value.isWhitespace { lineOnlyWhitespace = false }
                cursor = text.index(after: cursor)
            }
        }
        return result
    }

    private static func isEscaped(in text: String, at index: String.Index) -> Bool {
        var cursor = index, count = 0
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            count += 1; cursor = previous
        }
        return count % 2 == 1
    }

    private struct SourceLine {
        let end: String.Index
        let next: String.Index
        let value: String
    }
    private static func line(in text: String, at start: String.Index) -> SourceLine {
        let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
        return SourceLine(end: end, next: end < text.endIndex ? text.index(after: end) : end,
                          value: String(text[start..<end]).trimmingCharacters(in: .whitespaces))
    }
    private static let chineseChapter = try? NSRegularExpression(pattern: #"^第[ \t　]*[0-9０-９〇零○一二三四五六七八九十百千万萬亿億两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟廿卅卌]+[ \t　]*[章节節回卷部篇编編幕讲講课課]"#)
    private static let englishChapter = try? NSRegularExpression(pattern: #"(?i)^(?:chapter|part|book|section|volume|act)[ \t]+(?:[0-9]+|[ivxlcdm]+)\b"#)
    private static func headingEnd(in text: String, at start: String.Index, chapterTitle: String?) -> String.Index? {
        let first = line(in: text, at: start), value = first.value
        guard !value.isEmpty, value.count <= 160 else { return nil }
        guard !value.hasPrefix("```"), !value.hasPrefix("~~~"), !value.hasPrefix("$$") else { return nil }
        if value.range(of: #"^#{1,6}[ \t]+\S"#, options: .regularExpression) != nil { return first.end }
        if !value.contains("$"), !value.contains("`"), first.next < text.endIndex {
            let second = line(in: text, at: first.next)
            if second.value.range(of: #"^(?:={3,}|-{3,})$"#, options: .regularExpression) != nil { return second.end }
        }
        // An exact independent line may be a title supplied by the importer.
        // Never infer a heading from merely containing the book/chapter name.
        let knownTitle = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matchesTitle = !knownTitle.isEmpty && knownTitle.count <= 120 && value.utf8.elementsEqual(knownTitle.utf8)
        guard !value.contains(where: { "。！？!?；;".contains($0) }) else { return matchesTitle ? first.end : nil }
        let whole = NSRange(value.startIndex..<value.endIndex, in: value)
        if let match = chineseChapter?.firstMatch(in: value, range: whole) {
            let tail = (value as NSString).substring(from: NSMaxRange(match.range))
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":：.．、-—")))
            guard first.next < text.endIndex else { return first.end }
            let second = line(in: text, at: first.next)
            if tail.isEmpty, second.next < text.endIndex {
                let third = line(in: text, at: second.next)
                if let width = coupletWidth(second.value), coupletWidth(third.value) == width { return third.end }
            }
            // An already titled chapter line is complete. A following short
            // prose line can have exactly the same width as a couplet; length
            // alone cannot authorize extending this heading into that line.
            return first.end
        }
        if matchesTitle { return first.end }
        if let match = englishChapter?.firstMatch(in: value, range: whole) {
            let tail = (value as NSString).substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            if tail == "." || value.last != "." { return first.end }
        }
        return nil
    }
    private static func coupletWidth(_ text: String) -> Int? {
        let content = text.filter { !$0.isWhitespace }
        if chineseChapter?.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)) != nil { return nil }
        // Wrapped opening prose can also happen to be two equal-length CJK
        // lines. Familiar narrative starts are not a chapter-title couplet.
        guard !["却说", "卻說", "且说", "且說", "话说", "話說", "原来", "原來", "当下", "當下", "次日", "忽然", "于是", "於是", "只见", "只見", "此时", "此時"].contains(where: { content.hasPrefix($0) }) else { return nil }
        guard (5...20).contains(content.count), content.unicodeScalars.allSatisfy({
            (0x3400...0x9fff).contains($0.value) || (0x20000...0x323af).contains($0.value)
        }) else { return nil }
        return content.count
    }

    public static func anchors(in unit: SourceUnit, project: BookProject, maximum: Int = 2000) -> [SourceAnchor] {
        guard maximum > 0, !Task.isCancelled,
              let creator = try? ReadingExperienceRuntime.anchorCreator(sourceHash: project.sourceHash, unitID: unit.id, in: project) else { return [] }
        var result: [SourceAnchor] = []
        for value in ranges(in: unit.text, chapterTitle: unit.chapter, syntax: syntax(for: unit, in: project)).prefix(max(0, min(2000, maximum))) {
            guard !Task.isCancelled, let range = Range(value, in: unit.text) else { break }
            // Keep the same stable identity and literal validation as saved
            // anchors. Ambiguous excerpts are skipped instead of guessed.
            let quote = String(unit.text[range])
            let prefix = String(unit.text[..<range.lowerBound].suffix(200))
            let suffix = String(unit.text[range.upperBound...].prefix(200))
            if let anchor = try? creator(quote, prefix, suffix) { result.append(anchor) }
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
