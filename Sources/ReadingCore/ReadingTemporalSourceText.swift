import Foundation

enum ReadingTemporalSourceText {
    /// PDF soft line breaks may split a time label. Resolve only a unique
    /// newline-only match inside the explicitly referenced anchors, and store
    /// the actual substring, including its original line breaks. No spelling,
    /// punctuation, whitespace other than line breaks, or dates are inferred.
    static func canonical(_ requested: String, anchors: [SourceAnchor]) -> String {
        guard !requested.isEmpty, !anchors.contains(where: { $0.quote.range(of: requested, options: .literal) != nil }) else { return requested }
        func lineBreak(_ value: UInt16) -> Bool { value == 10 || value == 13 || value == 0x2028 || value == 0x2029 }
        let target = String(decoding: requested.utf16.filter { !lineBreak($0) }, as: UTF16.self)
        guard !target.isEmpty else { return requested }
        var candidate: String?
        for anchor in anchors {
            let original = Array(anchor.quote.utf16)
            let offsets = original.indices.filter { !lineBreak(original[$0]) }
            let folded = String(decoding: offsets.map { original[$0] }, as: UTF16.self) as NSString
            var search = NSRange(location: 0, length: folded.length)
            while search.length > 0 {
                let found = folded.range(of: target, options: .literal, range: search)
                guard found.location != NSNotFound, found.length > 0 else { break }
                // Two occurrences are ambiguous, even when their labels match.
                guard candidate == nil else { return requested }
                let first = offsets[found.location], last = offsets[NSMaxRange(found) - 1] + 1
                candidate = (anchor.quote as NSString).substring(with: NSRange(location: first, length: last - first))
                let next = found.location + 1
                search = NSRange(location: next, length: folded.length - next)
            }
        }
        return candidate ?? requested
    }
}
