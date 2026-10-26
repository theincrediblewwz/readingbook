import Foundation

/// Disposable source text for one complete PDF page, prepared off the UI thread.
/// The identity is byte based, not Swift String's normalized equality. This is
/// presentation metadata, never a replacement for source-anchor validation.
public struct PDFPageSourceText: Sendable {
    public let page: Int
    public let text: String
    public let identity: String

    public init(page: Int, text: String) throws {
        guard page > 0 else { throw ReadingError.invalid("原文页码无效。") }
        try Task.checkCancellation()
        self.page = page; self.text = text
        self.identity = String(page) + ":" + (try BookImporter.sha256(Data(text.utf8)))
        try Task.checkCancellation()
    }
}

/// A full-page byte comparison proves that host-validated source offsets and
/// native PDF character offsets address the same text. Only use with ranges
/// already admitted by ReadingExperienceRuntime, never with model-supplied
/// offsets. If this proof fails, callers must use the unique-quote matcher.
public struct NativePageTextProof: Sendable {
    public let identity: String
    private let units: [UInt16]
    public var byteCount: Int { units.count * MemoryLayout<UInt16>.stride }

    public static func prove(page: Int, nativeText: String, source: PDFPageSourceText,
                             isCancelled: () -> Bool = { Task.isCancelled }) -> Self? {
        guard !isCancelled(), source.page == page,
              nativeText.utf8.elementsEqual(source.text.utf8), !isCancelled() else { return nil }
        // Converting a Swift UTF-16 offset for every quote can itself walk the
        // page prefix. Build one immutable buffer, so all later lookups are
        // O(quote length) with constant-time boundary checks.
        var units: [UInt16] = []
        units.reserveCapacity(nativeText.utf16.count)
        for (index, value) in nativeText.utf16.enumerated() {
            if index & 1023 == 0, isCancelled() { return nil }
            units.append(value)
        }
        guard !isCancelled() else { return nil }
        return Self(identity: source.identity, units: units)
    }

    /// Exact UTF-16 equality on valid Swift strings preserves the original
    /// Unicode scalars and therefore their UTF-8 bytes; it never normalizes.
    public func range(of quote: String, location: Int?, length: Int?,
                      isCancelled: () -> Bool = { Task.isCancelled }) -> NSRange? {
        guard !isCancelled(), !quote.isEmpty, let location, let length,
              location >= 0, length > 0, location <= units.count,
              length <= units.count - location, quote.utf16.count == length,
              isBoundary(location), isBoundary(location + length) else { return nil }
        for (offset, value) in quote.utf16.enumerated() {
            if offset & 255 == 0, isCancelled() { return nil }
            guard units[location + offset] == value else { return nil }
        }
        guard !isCancelled() else { return nil }
        return NSRange(location: location, length: length)
    }

    private func isBoundary(_ offset: Int) -> Bool {
        guard offset > 0, offset < units.count else { return true }
        return !((0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset]))
    }
}
