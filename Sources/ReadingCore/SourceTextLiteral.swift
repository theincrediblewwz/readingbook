import Foundation

/// Evidence is a literal source substring, not a Unicode-normalized search.
/// Repeated equal quotes are valid evidence; position anchors add uniqueness.
enum SourceTextLiteral {
    static func contains(_ quote: String, in text: String) -> Bool {
        guard !quote.isEmpty, let range = text.range(of: quote, options: .literal) else { return false }
        return text[range].utf8.elementsEqual(quote.utf8)
    }
}
