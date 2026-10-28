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

/// A full-page byte comparison, either raw or after the importer's CRLF/CR-to-LF
/// conversion, proves how host-validated source offsets map to PDF characters. Use
/// only with ranges already admitted by ReadingExperienceRuntime, never with
/// model-supplied offsets. If this proof fails, use the unique-quote matcher.
public struct NativePageTextProof: Sendable {
    public let identity: String
    private let units: [UInt16]
    // Each CRLF removes exactly one native UTF-16 unit. Record its canonical
    // end boundary, rather than retaining an Int for every page character.
    // Pages without a CRLF contraction need no offset mapping at all.
    private let collapsedLineEndBoundaries: [Int]?
    public var byteCount: Int {
        units.count * MemoryLayout<UInt16>.stride + (collapsedLineEndBoundaries?.count ?? 0) * MemoryLayout<Int>.stride
    }

    public static func prove(page: Int, nativeText: String, source: PDFPageSourceText,
                             isCancelled: () -> Bool = { Task.isCancelled }) -> Self? {
        guard !isCancelled(), source.page == page else { return nil }
        let identicalBytes = nativeText.utf8.elementsEqual(source.text.utf8)
        guard !isCancelled() else { return nil }
        // Preserve the existing raw proof, including old exact CR/CRLF source
        // text. Only a failed byte comparison needs the importer's conversion.
        let convertsLineEndings = !identicalBytes && nativeText.utf8.contains(0x0D)
        guard identicalBytes || convertsLineEndings else { return nil }
        // Converting a Swift UTF-16 offset for every quote can itself walk the
        // page prefix. Build one immutable buffer, so all later lookups are
        // O(quote length), plus two binary searches only for CRLF contractions.
        var units: [UInt16] = []
        units.reserveCapacity(nativeText.utf16.count)
        var collapsedLineEndBoundaries: [Int]?
        if convertsLineEndings {
            var iterator = nativeText.utf16.makeIterator()
            var next = iterator.next()
            while let value = next {
                if units.count & 1023 == 0, isCancelled() { return nil }
                next = iterator.next()
                if value == 0x0D {
                    units.append(0x0A)
                    if next == 0x0A {
                        next = iterator.next()
                        if collapsedLineEndBoundaries == nil { collapsedLineEndBoundaries = [] }
                        collapsedLineEndBoundaries?.append(units.count)
                    }
                } else { units.append(value) }
            }
            // No Unicode, spaces, tabs or OCR differences may be promoted by
            // this proof. The only admitted change is BookImporter.splitText's
            // exact newline conversion over the complete native page.
            guard !isCancelled(), String(decoding: units, as: UTF16.self).utf8.elementsEqual(source.text.utf8),
                  !isCancelled() else { return nil }
        } else {
            for (index, value) in nativeText.utf16.enumerated() {
                if index & 1023 == 0, isCancelled() { return nil }
                units.append(value)
            }
        }
        guard !isCancelled() else { return nil }
        return Self(identity: source.identity, units: units, collapsedLineEndBoundaries: collapsedLineEndBoundaries)
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
        let start = nativeBoundary(location), end = nativeBoundary(location + length)
        return NSRange(location: start, length: end - start)
    }

    private func nativeBoundary(_ offset: Int) -> Int {
        guard let boundaries = collapsedLineEndBoundaries else { return offset }
        var lower = 0, upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if boundaries[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return offset + lower
    }

    private func isBoundary(_ offset: Int) -> Bool {
        guard offset > 0, offset < units.count else { return true }
        return !((0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset]))
    }
}
