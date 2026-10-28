import Foundation

/// Find a unique literal quote in PDFKit's page-local UTF-16 text. Imported
/// unit offsets are deliberately not used as native PDF character offsets.
/// Cancellation is cooperative between Foundation searches; an individual
/// NSString search is still a synchronous native call.
public enum NativeQuoteRangeMatcher {
    public static func range(of quote: String, prefix: String? = nil, suffix: String? = nil,
                             in text: NSString, isCancelled: () -> Bool = { Task.isCancelled }) -> NSRange? {
        guard !quote.isEmpty, !isCancelled() else { return nil }
        var start = 0
        var candidate: NSRange?
        while start < text.length {
            guard !isCancelled() else { return nil }
            let range = text.range(of: quote, options: [.literal], range: NSRange(location: start, length: text.length - start))
            guard range.location != NSNotFound else { break }
            // Include overlapping occurrences; two valid matches remain
            // ambiguous even if the first occurrence was already found.
            start = range.location + 1
            guard text.substring(with: range).utf8.elementsEqual(quote.utf8) else { continue }
            if let prefix, !prefix.isEmpty {
                let length = prefix.utf16.count
                guard range.location >= length,
                      text.substring(with: NSRange(location: range.location - length, length: length)).utf8.elementsEqual(prefix.utf8) else { continue }
            }
            if let suffix, !suffix.isEmpty {
                let length = suffix.utf16.count
                guard NSMaxRange(range) <= text.length - length,
                      text.substring(with: NSRange(location: NSMaxRange(range), length: length)).utf8.elementsEqual(suffix.utf8) else { continue }
            }
            guard candidate == nil else { return nil }
            candidate = range
        }
        // Cancellation while proving uniqueness must discard the first match,
        // rather than turn an unfinished scan into a confirmed native range.
        guard !isCancelled() else { return nil }
        return candidate
    }
}
