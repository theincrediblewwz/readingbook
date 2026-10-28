import Foundation

/// A disposable UTF-16 source map for the note editor. The Markdown itself is
/// never abbreviated or replaced: only the destination's displayed glyphs fold.
public enum ReadingNoteLinkFolds {
    public struct Link: Equatable, Sendable {
        public let range: NSRange
        public let destinationRange: NSRange

        public init(range: NSRange, destinationRange: NSRange) {
            self.range = range; self.destinationRange = destinationRange
        }
    }

    /// Fold only an unambiguous, standalone inline link of the form emitted by
    /// ReadingBook. Code, external links, images, reference definitions, escaped
    /// syntax, multiline links and more elaborate user Markdown stay visible.
    /// Foundation must independently recognize the same link on that source
    /// line; a regex match alone never authorizes hiding source text.
    public static func links(in markdown: String) -> [Link] {
        guard !Task.isCancelled, markdown.contains("readingbook://book/") else { return [] }
        #if os(macOS)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .throwError
        options.appliesSourcePositionAttributes = true
        guard let parsed = try? AttributedString(markdown: markdown, options: options), !Task.isCancelled else { return [] }
        struct Proof: Hashable { let line: Int; let url: String }
        var proofs = Set<Proof>()
        for run in parsed.runs {
            guard !Task.isCancelled else { return [] }
            guard let url = run.link, url.scheme == "readingbook", url.host == "book",
                  run.inlinePresentationIntent?.contains(.code) != true,
                  run.inlinePresentationIntent?.contains(.inlineHTML) != true,
                  run.inlinePresentationIntent?.contains(.blockHTML) != true,
                  let position = run.markdownSourcePosition,
                  position.startLine > 0, position.startLine == position.endLine else { continue }
            proofs.insert(Proof(line: position.startLine, url: url.absoluteString))
        }
        guard !proofs.isEmpty,
              let expression = try? NSRegularExpression(pattern: #"^ {0,3}\[([^\[\]\\`\r\n]+)\]\((readingbook://book/[^\s()<>\\]+)\) *$"#) else { return [] }
        let source = markdown as NSString
        var result: [Link] = [], cursor = 0, line = 1
        while cursor < source.length {
            guard !Task.isCancelled else { return [] }
            var lineStart = 0, lineEnd = 0, contentEnd = 0
            source.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentEnd,
                for: NSRange(location: cursor, length: 0))
            let content = NSRange(location: lineStart, length: contentEnd - lineStart)
            let rawLine = source.substring(with: content)
            if let match = expression.firstMatch(in: rawLine, range: NSRange(location: 0, length: content.length)),
               match.range == NSRange(location: 0, length: content.length) {
                let local = match.range(at: 2)
                let destination = NSRange(location: content.location + local.location, length: local.length)
                let original = source.substring(with: destination)
                if let url = URL(string: original), url.scheme == "readingbook", url.host == "book",
                   url.user == nil, url.password == nil, url.port == nil,
                   url.pathComponents.filter({ $0 != "/" }).count == 3,
                   proofs.contains(Proof(line: line, url: url.absoluteString)) {
                    result.append(Link(range: content, destinationRange: destination))
                }
            }
            guard lineEnd > cursor else { break }
            cursor = lineEnd; line += 1
        }
        return result
        #else
        // This editor is macOS-only. Do not guess at Markdown code boundaries
        // on platforms without Foundation's source-position parser.
        return []
        #endif
    }

    /// Entering/selecting a target exposes its complete source before editing.
    /// IME composition always uses the ordinary, unfolded native text system.
    public static func foldedLinks(_ links: [Link], selection: NSRange, expanded: Bool, composing: Bool) -> [Link] {
        foldedLinks(links, selections: [selection], expanded: expanded, composing: composing)
    }

    public static func foldedLinks(_ links: [Link], selections: [NSRange], expanded: Bool, composing: Bool) -> [Link] {
        guard !expanded, !composing else { return [] }
        return links.filter { link in
            let target = link.destinationRange
            return !selections.contains { selection in
                if selection.length == 0 {
                    return selection.location >= target.location && selection.location <= NSMaxRange(target)
                }
                return NSIntersectionRange(selection, target).length > 0
            }
        }
    }

    /// Only ordinary prose edits can reuse a confirmed source map. A Markdown
    /// delimiter anywhere on the edited line, or a changed line boundary, can
    /// change code/link semantics elsewhere and requires background re-parsing.
    public static func canRemap(replacedText: String, replacement: String, editLine: String) -> Bool {
        let structural = Set("`~<>[]()\\!#*_$\r\n\t".utf16)
        return !replacedText.utf16.contains(where: structural.contains)
            && !replacement.utf16.contains(where: structural.contains)
            && !editLine.utf16.contains(where: structural.contains)
    }

    /// Rebase verified UTF-16 ranges after an ordinary prose edit. Touched links
    /// lose their authority until the parser confirms them again. This does no
    /// parsing or source copying and visits only the small existing link list.
    public static func remapped(_ links: [Link], editedRange: NSRange, replacementLength: Int) -> [Link] {
        let delta = replacementLength - editedRange.length
        return links.compactMap { link in
            if editedRange.length == 0,
               editedRange.location >= link.range.location && editedRange.location <= NSMaxRange(link.range) { return nil }
            if NSIntersectionRange(editedRange, link.range).length > 0 { return nil }
            if NSMaxRange(editedRange) <= link.range.location {
                return Link(range: NSRange(location: link.range.location + delta, length: link.range.length),
                    destinationRange: NSRange(location: link.destinationRange.location + delta, length: link.destinationRange.length))
            }
            return link
        }
    }

    /// Defensive edit gate for a native command that reaches hidden characters
    /// without first issuing a selection change. Reveal first; never silently
    /// delete or replace characters that the user has not been able to inspect.
    public static func editTouchesFold(_ range: NSRange, folded: [Link]) -> Bool {
        folded.contains { link in
            if range.length == 0 {
                return range.location >= link.destinationRange.location && range.location <= NSMaxRange(link.destinationRange)
            }
            return NSIntersectionRange(range, link.destinationRange).length > 0
        }
    }
}

/// Saving a new draft assigns it a document ID without changing the editing
/// session. Different books/documents and externally replaced text must never
/// inherit an old note's undo history, even when two notes have identical text.
public enum ReadingNoteEditorContinuity {
    public static func libraryKey(_ root: URL) -> String { root.standardizedFileURL.path }
    public static func identicalSource(_ lhs: String, _ rhs: String) -> Bool {
        // NSTextView commonly bridges a noncontiguous Cocoa String. Walking
        // its UTF-8 view per echo costs tens of ms for a 500 KiB note. Literal
        // UTF-16 equality is exactly the same source-byte test for valid Swift
        // strings, and explicitly keeps NFC/NFD (and CRLF/LF) distinct.
        let left = lhs as NSString, right = rhs as NSString
        if left === right { return true }
        guard left.length == right.length else { return false }
        return left.compare(rhs, options: .literal) == .orderedSame
    }

    public static func preservesHistory(previousLibraryKey: String, previousBookID: String?, previousDocumentID: String?,
        nextLibraryKey: String, nextBookID: String?, nextDocumentID: String?, currentMarkdown: String, incomingMarkdown: String) -> Bool {
        guard previousLibraryKey == nextLibraryKey, previousBookID == nextBookID,
              identicalSource(currentMarkdown, incomingMarkdown) else { return false }
        return previousDocumentID == nextDocumentID || previousDocumentID == nil && nextDocumentID != nil
    }
}
