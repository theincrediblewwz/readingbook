import Foundation

/// Conservative, disposable PDF edge-line boundaries. These cuts separate
/// reading affordances; they never remove text or rewrite saved source units.
public enum PDFReadingStructure {
    fileprivate struct EdgeLine: Sendable {
        let start: Int
        let end: Int
        let value: String?
    }
    /// Prepared once per page in a reading window, then shared by its peers.
    public struct EdgeDescriptor: Sendable {
        fileprivate let first: EdgeLine
        fileprivate let last: EdgeLine
    }

    /// Peers are distinct pages supplied by the host. A repeated edge needs two
    /// peer pages on the same side, with identical original line bytes. One-line
    /// pages provide no evidence of a header or footer distinct from their body.
    public static func boundaries(in text: String, peers: [String]) -> [Int] {
        guard !Task.isCancelled, let current = edgeDescriptor(in: text) else { return [] }
        return boundaries(in: current, peers: peers.compactMap { edgeDescriptor(in: $0) })
    }

    public static func boundaries(in current: EdgeDescriptor, peers: [EdgeDescriptor]) -> [Int] {
        guard !Task.isCancelled else { return [] }
        var firstMatches = 0, lastMatches = 0
        if current.first.value != nil || current.last.value != nil {
            for peer in peers {
                guard !Task.isCancelled else { return [] }
                if let first = current.first.value, let other = peer.first.value,
                   first.utf8.elementsEqual(other.utf8) { firstMatches += 1 }
                if let last = current.last.value, let other = peer.last.value,
                   last.utf8.elementsEqual(other.utf8) { lastMatches += 1 }
                if firstMatches >= 2, lastMatches >= 2 { break }
            }
        }
        var result: [Int] = []
        if firstMatches >= 2 { result.append(current.first.end) }
        if lastMatches >= 2 || current.last.value.map(isPageNumber) == true { result.append(current.last.start) }
        return Array(Set(result)).sorted()
    }

    private static func isPageNumber(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return (1...6).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    public static func edgeDescriptor(in text: String) -> EdgeDescriptor? {
        var first: EdgeLine?, last: EdgeLine?, count = 0
        var start = text.startIndex, startOffset = 0, offset = 0
        func accept(_ end: String.Index, nextOffset: Int) {
            let content = text[start..<end]
            guard !content.allSatisfy(\.isWhitespace) else { return }
            count += 1
            let short = content.prefix(121)
            let value = short.count <= 120 && content.utf8.count <= 1_024 &&
                !short.contains(where: { "。！？!?；;.".contains($0) }) ? String(content) : nil
            let line = EdgeLine(start: startOffset, end: nextOffset, value: value)
            if first == nil { first = line }
            last = line
        }
        for cursor in text.indices {
            guard !Task.isCancelled else { return nil }
            let next = text.index(after: cursor)
            let width = String(text[cursor]).utf16.count
            if text[cursor].isNewline {
                accept(cursor, nextOffset: offset + width)
                start = next; startOffset = offset + width
            }
            offset += width
        }
        accept(text.endIndex, nextOffset: offset)
        guard !Task.isCancelled, count > 1, let first, let last else { return nil }
        return EdgeDescriptor(first: first, last: last)
    }
}
