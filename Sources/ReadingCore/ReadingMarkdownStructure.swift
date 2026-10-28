import Foundation

/// A transient source map, not a replacement renderer or a stored document.
/// Foundation owns Markdown container semantics. We retain complete original
/// source lines so offsets and quotation bytes never address rendered text.
enum ReadingMarkdownStructure {
    struct Block: Sendable {
        let range: NSRange
        let annotates: Bool
        let atomic: Bool
    }
    private struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int
    }
    private struct Group {
        var first: Int
        var last: Int
        let annotates: Bool
        let atomic: Bool
    }

    /// Most source pages do not need a second parser. This is only a syntax
    /// gate; the caller must also know that the source really is Markdown.
    static func needsStructure(_ text: String) -> Bool {
        var atStart = true, spaces = 0, digits = 0, marker = false
        var underline: Unicode.Scalar?, underlinePossible = true, underlineTrailingSpace = false
        for scalar in text.unicodeScalars {
            if Task.isCancelled { return false }
            if scalar == "\n" || scalar == "\r" {
                if underline != nil, underlinePossible { return true }
                atStart = true; spaces = 0; digits = 0; marker = false
                underline = nil; underlinePossible = true; underlineTrailingSpace = false
                continue
            }
            // Setext underlines may contain just one '=' or '-'. The plain
            // scanner's conservative PDF heading heuristic requires three,
            // and cannot prove multiline Markdown headings. Send genuine
            // underline candidates through Foundation's block map instead.
            // This shares the syntax-gate pass, without per-line substring
            // allocation or broadening the plain-text/PDF heading rules.
            if underlinePossible {
                if let underline {
                    if scalar == " " || scalar == "\t" { underlineTrailingSpace = true }
                    else if scalar != underline || underlineTrailingSpace { underlinePossible = false }
                } else if scalar == "=" || scalar == "-" { underline = scalar }
                else if scalar != " " { underlinePossible = false }
            }
            guard atStart else { continue }
            if marker {
                if scalar == " " || scalar == "\t" { return true }
                atStart = false; continue
            }
            if scalar == " " { spaces += 1; if spaces >= 4 { return true }; continue }
            if scalar == "\t" { return true }
            if scalar == ">" { return true }
            if scalar == "-" || scalar == "+" || scalar == "*" { marker = true; continue }
            if (48...57).contains(scalar.value), digits < 9 { digits += 1; continue }
            if digits > 0, scalar == "." || scalar == ")" { marker = true; continue }
            atStart = false
        }
        return underline != nil && underlinePossible
    }

    static func blocks(in text: String, displayMath: ([Int]) -> [NSRange]) -> [Block]? {
        guard !Task.isCancelled else { return nil }
        let source = text as NSString
        let lines = sourceLines(text)
        guard !lines.isEmpty, !Task.isCancelled else { return nil }
        #if os(macOS)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .throwError
        options.appliesSourcePositionAttributes = true
        guard let original = try? AttributedString(markdown: text, options: options), !Task.isCancelled else { return nil }
        var parsed = original, codeGroups = Set<Int>(), invalidGroups = Set<Int>()
        for run in original.runs {
            guard !Task.isCancelled else { return nil }
            guard let intent = run.presentationIntent, let leaf = Self.leaf(in: intent) else { continue }
            if run.inlinePresentationIntent?.contains(.inlineHTML) == true || run.inlinePresentationIntent?.contains(.blockHTML) == true {
                invalidGroups.insert(leaf.identity)
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                switch leaf.kind {
                case .paragraph, .header: codeGroups.insert(leaf.identity)
                default: break
                }
            }
        }
        if !codeGroups.isEmpty {
            // Foundation currently flattens the source positions of multiline
            // inline code and the text following it onto its opening line.
            // Even Range(sourcePosition, in:) then addresses the wrong bytes.
            // A disposable, byte-length-preserving shadow removes only inline
            // tick syntax. Block structure must be identical before its line
            // positions are allowed to map back to the untouched source.
            let shadow = structureShadow(source, lines: lines)
            if !Task.isCancelled, let shadow,
               let candidate = try? AttributedString(markdown: shadow, options: options),
               !hasInlineCode(candidate),
               let before = signature(of: original, lineCount: lines.count),
               let after = signature(of: candidate, lineCount: lines.count), before == after {
                parsed = candidate
            } else {
                // An uncertain shadow does not invalidate unrelated ordinary
                // paragraphs. Only its original code-bearing blocks lose
                // automatic sentence affordances; saved data stays intact.
                invalidGroups.formUnion(codeGroups)
            }
        }
        var groups: [Int: Group] = [:]
        var owners: [ReadingRangeIndex<[Int]>.Entry] = [], codeLines: [NSRange] = [], unknownLines: [NSRange] = []
        for run in parsed.runs {
            guard !Task.isCancelled else { return nil }
            // Synthetic separators do not claim to originate in source.
            if parsed.characters[run.range].allSatisfy(\.isWhitespace) { continue }
            let position = run.markdownSourcePosition
            let mappedLines: NSRange?
            // Lazy lines can retain a virtual ancestor indentation in their
            // columns (for example col 5...6 on a four-byte "  $$" line).
            // Only proven block identity and valid physical rows map source;
            // these columns never authorize an original byte/UTF16 position.
            if let position, position.startLine > 0, position.endLine >= position.startLine,
               position.endLine <= lines.count {
                mappedLines = NSRange(location: position.startLine - 1, length: position.endLine - position.startLine + 1)
            } else { mappedLines = nil }
            guard let intent = run.presentationIntent else {
                guard let mappedLines else { return nil }
                unknownLines.append(mappedLines); continue
            }
            let leaf = Self.leaf(in: intent)
            guard let leaf else {
                guard let mappedLines else { return nil }
                unknownLines.append(mappedLines); continue
            }
            guard let lineRange = mappedLines else {
                invalidGroups.insert(leaf.identity); continue
            }
            let first = lineRange.location, last = NSMaxRange(lineRange) - 1
            if intent.components.contains(where: { component in
                switch component.kind { case .table, .tableCell, .tableRow, .tableHeaderRow: return true; default: return false }
            }) { unknownLines.append(lineRange); continue }
            let path = intent.components.compactMap { component -> Int? in
                switch component.kind {
                case .blockQuote, .listItem: return component.identity
                default: return nil
                }
            }
            // Component order is not used for identity grouping. A sorted set
            // suffices for the ancestor containment check on math blocks.
            let owner = path.sorted()
            owners.append(.init(id: owner, range: lineRange))
            let annotates: Bool, atomic: Bool
            switch leaf.kind {
            case .paragraph: annotates = true; atomic = false
            case .header: annotates = true; atomic = true
            case .codeBlock:
                annotates = false; atomic = true
                codeLines.append(lineRange)
            default:
                // Multiple table cells share a physical line; a line-based
                // map cannot honestly claim their individual source ranges.
                unknownLines.append(lineRange)
                continue
            }
            if var existing = groups[leaf.identity] {
                existing.first = min(existing.first, first); existing.last = max(existing.last, last)
                groups[leaf.identity] = existing
            } else { groups[leaf.identity] = Group(first: first, last: last, annotates: annotates, atomic: atomic) }
        }
        guard !Task.isCancelled else { return nil }
        let unknown = merged(unknownLines), code = merged(codeLines)
        var base: [Block] = []
        for (id, group) in groups {
            guard !Task.isCancelled else { return nil }
            guard !invalidGroups.contains(id), !intersects(NSRange(location: group.first, length: group.last - group.first + 1), with: unknown) else { continue }
            base.append(Block(range: NSRange(location: lines[group.first].start, length: lines[group.last].end - lines[group.first].start), annotates: group.annotates, atomic: group.atomic))
        }
        base.sort { $0.range.location < $1.range.location }
        // Unsupported overlapping maps are local exclusions, never a reason
        // to fall back to an unstructured scan through another block.
        var overlapping = Set<Int>()
        if base.count > 1 {
            var previous = 0
            for index in 1..<base.count {
                if base[index].range.location < NSMaxRange(base[previous].range) {
                    overlapping.insert(previous); overlapping.insert(index)
                }
                if NSMaxRange(base[index].range) > NSMaxRange(base[previous].range) { previous = index }
            }
        }
        base = base.enumerated().compactMap { overlapping.contains($0.offset) ? nil : $0.element }
        let codeSpanBreaks = Array(Set(base.flatMap { [$0.range.location, NSMaxRange($0.range)] })).sorted()
        let atoms = mathBlocks(displayMath(codeSpanBreaks), source: source, lines: lines, codeLines: code, containers: ReadingRangeIndex(owners))
        guard !Task.isCancelled else { return nil }
        // Split paragraph maps at math atoms. A custom display formula may
        // include blank lines or text that Foundation sees as nested lists.
        // Its original source interval takes precedence over those interiors.
        var result: [Block] = [], atomCursor = 0
        for block in base {
            guard !Task.isCancelled else { return nil }
            var cursor = block.range.location
            let end = NSMaxRange(block.range)
            while atomCursor < atoms.count, NSMaxRange(atoms[atomCursor]) <= cursor { atomCursor += 1 }
            var index = atomCursor
            while index < atoms.count, atoms[index].location < end {
                guard !Task.isCancelled else { return nil }
                let atom = atoms[index]
                if atom.location > cursor {
                    result.append(Block(range: NSRange(location: cursor, length: atom.location - cursor), annotates: block.annotates, atomic: block.atomic))
                }
                cursor = max(cursor, NSMaxRange(atom)); index += 1
            }
            if cursor < end { result.append(Block(range: NSRange(location: cursor, length: end - cursor), annotates: block.annotates, atomic: block.atomic)) }
        }
        result += atoms.map { Block(range: $0, annotates: true, atomic: true) }
        result.sort { $0.range.location < $1.range.location }
        guard !Task.isCancelled else { return nil }
        return result.filter { $0.range.length > 0 }
        #else
        // Supported application targets use Foundation's native Markdown
        // parser. An unavailable parser never grants a structural boundary.
        return nil
        #endif
    }

    #if os(macOS)
    private struct SignatureBlock: Equatable {
        var first: Int
        var blockHTML: Bool
    }

    private static func leaf(in intent: PresentationIntent) -> PresentationIntent.IntentType? {
        intent.components.first { component in
            switch component.kind {
            case .paragraph, .header, .codeBlock, .tableCell: return true
            default: return false
            }
        }
    }

    private static func hasInlineCode(_ value: AttributedString) -> Bool {
        for run in value.runs {
            if Task.isCancelled { return true }
            guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
            guard let intent = run.presentationIntent, let leaf = Self.leaf(in: intent) else { return true }
            switch leaf.kind {
            case .paragraph, .header: return true
            default: break
            }
        }
        return false
    }

    /// Full intent values include every container's kind, identity and ordinal.
    /// Comparing their first source lines proves a one-to-one block skeleton,
    /// rather than guessing a paragraph end from the next visible paragraph.
    private static func signature(of value: AttributedString, lineCount: Int) -> [PresentationIntent: SignatureBlock]? {
        var result: [PresentationIntent: SignatureBlock] = [:]
        for run in value.runs {
            guard !Task.isCancelled else { return nil }
            if value.characters[run.range].allSatisfy(\.isWhitespace) { continue }
            guard let intent = run.presentationIntent, let position = run.markdownSourcePosition,
                  position.startLine > 0, position.startLine <= lineCount else { return nil }
            let html = run.inlinePresentationIntent?.contains(.blockHTML) == true
            if var block = result[intent] {
                block.first = min(block.first, position.startLine); block.blockHTML = block.blockHTML || html
                result[intent] = block
            } else { result[intent] = SignatureBlock(first: position.startLine, blockHTML: html) }
        }
        return result
    }

    private static func structureShadow(_ source: NSString, lines: [Line]) -> String? {
        var result = String(); result.reserveCapacity(source.length)
        for line in lines {
            guard !Task.isCancelled else { return nil }
            let content = source.substring(with: NSRange(location: line.start, length: line.contentEnd - line.start))
            var preservesFence = false
            if let first = content.firstIndex(where: { $0 == "`" || $0 == "~" }), isContainerPrefix(String(content[..<first])) {
                let marker = content[first], end = content[first...].prefix(while: { $0 == marker }).endIndex
                let width = content[first..<end].count
                // Backtick fence info cannot itself contain a backtick.
                // Preserve tilde fence info too, including its language hint.
                preservesFence = width >= 3 && (marker == "~" || !content[end...].contains("`"))
            }
            result += preservesFence ? content : content.replacingOccurrences(of: "`", with: "x", options: .literal)
            result += source.substring(with: NSRange(location: line.contentEnd, length: line.end - line.contentEnd))
        }
        return result
    }
    #endif

    private static func sourceLines(_ text: String) -> [Line] {
        // One sequential UTF8 pass gives original UTF16 line offsets without
        // per-run seeks from the beginning of a Swift String.
        let bytes = Array(text.utf8)
        var result: [Line] = [], start = 0, cursor = 0, byteCursor = 0
        while byteCursor < bytes.count {
            if Task.isCancelled { return [] }
            let value = bytes[byteCursor]
            if value == 10 || value == 13 {
                let contentEnd = cursor
                let width = value == 13 && byteCursor + 1 < bytes.count && bytes[byteCursor + 1] == 10 ? 2 : 1
                cursor += width; byteCursor += width
                result.append(Line(start: start, contentEnd: contentEnd, end: cursor))
                start = cursor
            } else {
                if value < 0x80 || value >= 0xc0 { cursor += value >= 0xf0 ? 2 : 1 }
                byteCursor += 1
            }
        }
        result.append(Line(start: start, contentEnd: cursor, end: cursor))
        return result
    }

    private static func mathBlocks(_ candidates: [NSRange], source: NSString, lines: [Line], codeLines: [NSRange], containers: ReadingRangeIndex<[Int]>) -> [NSRange] {
        func lineIndex(_ location: Int) -> Int? {
            guard location >= 0, location < source.length else { return nil }
            var low = 0, high = lines.count
            while low < high {
                let middle = low + (high - low) / 2
                if lines[middle].start <= location { low = middle + 1 } else { high = middle }
            }
            return low > 0 ? low - 1 : nil
        }
        var result: [NSRange] = []
        for candidate in candidates {
            if Task.isCancelled { return [] }
            guard candidate.length > 0, let first = lineIndex(candidate.location), let last = lineIndex(NSMaxRange(candidate) - 1),
                  !intersects(NSRange(location: first, length: 1), with: codeLines), NSMaxRange(candidate) <= lines[last].contentEnd else { continue }
            let prefix = source.substring(with: NSRange(location: lines[first].start, length: candidate.location - lines[first].start))
            let suffix = source.substring(with: NSRange(location: NSMaxRange(candidate), length: lines[last].contentEnd - NSMaxRange(candidate)))
            // Only a genuine display-block opener can override paragraph
            // boundaries. An inline $$ after prose cannot consume a new item.
            guard isContainerPrefix(prefix), suffix.allSatisfy(\.isWhitespace) else { continue }
            let openingOwners = containers.ids(containing: first), closingOwners = containers.ids(containing: last)
            guard openingOwners.count == 1, closingOwners.count == 1 else { continue }
            let before = Set(openingOwners.first ?? []), after = Set(closingOwners.first ?? [])
            guard before.isSubset(of: after) else { continue }
            let range = NSRange(location: lines[first].start, length: lines[last].end - lines[first].start)
            guard result.last.map({ NSMaxRange($0) <= range.location }) ?? true else { continue }
            result.append(range)
        }
        return result
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else { result.append(range) }
        }
        return result
    }

    private static func intersects(_ range: NSRange, with merged: [NSRange]) -> Bool {
        var low = 0, high = merged.count
        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(merged[middle]) <= range.location { low = middle + 1 } else { high = middle }
        }
        return low < merged.count && merged[low].location < NSMaxRange(range)
    }

    private static func isContainerPrefix(_ text: String) -> Bool {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let value = text[cursor]
            if value == " " || value == "\t" || value == ">" { cursor = text.index(after: cursor); continue }
            if value == "-" || value == "+" || value == "*" {
                let next = text.index(after: cursor)
                guard next < text.endIndex, text[next] == " " || text[next] == "\t" else { return false }
                cursor = next; continue
            }
            if value >= "0" && value <= "9" {
                var end = cursor, count = 0
                while end < text.endIndex, text[end] >= "0", text[end] <= "9", count < 10 { end = text.index(after: end); count += 1 }
                guard count <= 9, end < text.endIndex, text[end] == "." || text[end] == ")" else { return false }
                let next = text.index(after: end)
                guard next < text.endIndex, text[next] == " " || text[next] == "\t" else { return false }
                cursor = next; continue
            }
            return false
        }
        return true
    }
}
