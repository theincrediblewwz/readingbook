import Foundation

/// A bounded, offline spelling plan for PDFKit's asynchronous multi-string
/// search. It changes queries only; selections and snippets keep source text.
/// Script conversion is not typo correction or cross-language translation.
public enum NativePDFSearchQuery {
    public static func terms(for input: String) -> [String] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { return [] }
        var values = [query]
        if LibrarySearchCanonicalizer.containsHan(query) {
            values.append(query.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? query)
            values.append(query.applyingTransform(StringTransform(rawValue: "Simplified-Traditional"), reverse: false) ?? query)
        }
        var seen = Set<String>()
        return values.filter { value in
            let identity = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return seen.insert(identity).inserted
        }
    }
}

public struct NativePDFSearchSnippet: Equatable, Sendable {
    public let before: String
    public let match: String
    public let after: String
    /// Paragraphs in the PDF's extracted text layer, not inferred book structure.
    public let paragraph: Int?
    public var text: String { before + match + after }
    public static func unlocated(_ match: String) -> Self { .init(before: "", match: match, after: "", paragraph: nil) }
}

/// Immutable page text prepared off the UI thread, shared by visible hits only.
/// Indexing once avoids scanning the same page prefix for each result row.
public final class NativePDFSearchTextIndex: @unchecked Sendable {
    private let text: NSString
    private let paragraphStarts: [Int]
    public let byteCount: Int
    public init(_ value: String) {
        text = NSString(string: value)
        let units = Array(value.utf16)
        var starts = [0]
        for index in units.indices {
            let unit = units[index]
            if unit == 0x0A || (unit == 0x0D && (index + 1 == units.count || units[index + 1] != 0x0A)) || unit == 0x2029 {
                if index + 1 < units.count { starts.append(index + 1) }
            }
        }
        paragraphStarts = starts; byteCount = units.count * 2 + starts.count * MemoryLayout<Int>.stride
    }
    public func snippet(range requestedRange: NSRange, expectedMatch: String, context: Int = 22) -> NativePDFSearchSnippet {
        guard requestedRange.location != NSNotFound, requestedRange.location >= 0, requestedRange.length > 0, requestedRange.location <= text.length,
              requestedRange.length <= text.length - requestedRange.location, (0...80).contains(context), !expectedMatch.isEmpty else { return .unlocated(expectedMatch) }
        var range = requestedRange
        let raw = text.substring(with: range)
        if !raw.utf8.elementsEqual(expectedMatch.utf8) {
            // PDFKit can include the line-ending character in range(at:on:)
            // while omitting it from selection.string. Trim only verified
            // whitespace around the exact match, never search another place.
            let native = raw as NSString, hit = native.range(of: expectedMatch, options: .literal)
            guard hit.location != NSNotFound,
                  native.substring(to: hit.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  native.substring(from: NSMaxRange(hit)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unlocated(expectedMatch) }
            range = NSRange(location: range.location + hit.location, length: hit.length)
        }
        let start = max(0, range.location - context), end = min(text.length, NSMaxRange(range) + context)
        let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        func compact(_ value: String) -> String { value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
        let before = compact(text.substring(with: NSRange(location: window.location, length: range.location - window.location)))
        let after = compact(text.substring(with: NSRange(location: NSMaxRange(range), length: NSMaxRange(window) - NSMaxRange(range))))
        var low = 0, high = paragraphStarts.count
        while low < high { let mid = low + (high - low) / 2; if paragraphStarts[mid] <= range.location { low = mid + 1 } else { high = mid } }
        return NativePDFSearchSnippet(before: (window.location > 0 ? "…" : "") + before, match: compact(expectedMatch),
            after: after + (NSMaxRange(window) < text.length ? "…" : ""), paragraph: max(1, low))
    }
}
