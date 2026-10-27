import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if os(macOS)
import PDFKit
#endif

/// A disposable native line whose selection ranges reproduce its text exactly.
/// It admits candidates only; a sentence still has to contain the real point.
public struct NativePDFTextLine: Sendable {
    public let ranges: [NSRange]
    public let enclosingRange: NSRange

    public static func validate(_ ranges: [NSRange], lineText: String, pageText: String,
                                nativeCharacterCount: Int) -> Self? {
        validate(ranges, lineText: lineText, pageText: pageText as NSString, nativeCharacterCount: nativeCharacterCount)
    }

    public static func validate(_ ranges: [NSRange], lineText: String, pageText: NSString,
                                nativeCharacterCount: Int) -> Self? {
        guard !ranges.isEmpty, ranges.count <= 64, !lineText.isEmpty,
              lineText.utf16.count <= 32_768, nativeCharacterCount >= 0 else { return nil }
        let source = pageText
        var previousEnd = 0, totalLength = 0, bytes = Data()
        for (index, range) in ranges.enumerated() {
            guard let end = validEnd(range, limit: min(source.length, nativeCharacterCount)),
                  index == 0 || range.location >= previousEnd,
                  range.length <= 32_768 - totalLength,
                  isBoundary(range.location, in: source), isBoundary(end, in: source) else { return nil }
            bytes.append(contentsOf: source.substring(with: range).utf8)
            previousEnd = end; totalLength += range.length
        }
        guard bytes.elementsEqual(lineText.utf8), let first = ranges.first else { return nil }
        return Self(ranges: ranges, enclosingRange: NSRange(location: first.location, length: previousEnd - first.location))
    }

    public func intersects(_ range: NSRange) -> Bool {
        guard let end = Self.validEnd(range, limit: Int.max) else { return false }
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].location < end { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return false }
        let candidate = ranges[lower - 1]
        return NSMaxRange(candidate) > range.location
    }

    /// A validated line plus its actual, cropped page-space bounds. The text
    /// ranges admit candidates; the final sentence must still contain the point.
    public struct PhysicalLine: Sendable {
        public let text: NativePDFTextLine
        public let rectangle: CGRect
        public var byteCount: Int { 96 + text.ranges.count * MemoryLayout<NSRange>.stride }
        public init(text: NativePDFTextLine, rectangle: CGRect) {
            self.text = text; self.rectangle = rectangle
        }
    }

    /// Built once while a page is prepared, never by a mouse-move handler.
    /// Stores value types only, so PDFKit selections do not outlive preparation.
    public struct Directory: Sendable {
        private var values: [PhysicalLine] = []
        private var bands = ReadingGeometryBands<Int>()
        private var unindexed: [Int] = []
        public private(set) var byteCount = 0

        public init() {}

        public mutating func append(_ line: PhysicalLine) {
            guard NativePDFTextLine.usable(line.rectangle) else { return }
            if abs(line.rectangle.minY) > 1_000_000_000 || abs(line.rectangle.maxY) > 1_000_000_000 {
                // The broad phase deliberately bounds coordinate arithmetic.
                // Retain the exceptional physical lines rather than drop them.
                unindexed.append(values.count)
            } else { bands.insert(values.count, rectangle: line.rectangle) }
            values.append(line)
            // Include a conservative allowance for the broad-phase entries.
            let bandCount = line.rectangle.height <= 4_096 ? Int(ceil(line.rectangle.height / 64)) + 1 : 1
            byteCount += line.byteCount + 72 + bandCount * 32
        }

        public func lines(at point: CGPoint) -> [NativePDFTextLine] {
            guard point.x.isFinite, point.y.isFinite else { return [] }
            if bands.requiresFallback {
                // The existing broad phase degrades only for many exceptionally
                // tall lines. Preserve correctness without sorting them.
                return values.compactMap { $0.rectangle.contains(point) ? $0.text : nil }
            }
            let indexed = bands.candidates(atY: point.y).compactMap { index -> NativePDFTextLine? in
                let line = values[index]
                return line.rectangle.contains(point) ? line.text : nil
            }
            return indexed + unindexed.compactMap { index in
                let line = values[index]
                return line.rectangle.contains(point) ? line.text : nil
            }
        }
    }

    public struct Candidate<ID: Hashable & Sendable>: Sendable {
        public let id: ID
        public let range: NSRange
        public init(id: ID, range: NSRange) { self.id = id; self.range = range }
    }
    public struct Hit<ID: Hashable & Sendable>: Sendable {
        public let id: ID
        public let rectangle: CGRect
    }

    /// Callers provide an already bounded, most-specific-first candidate pool.
    /// Empty or non-containing geometry cannot hide a later valid candidate.
    public static func firstHit<ID: Hashable & Sendable>(at point: CGPoint, candidates: [Candidate<ID>],
                                     geometry: (Candidate<ID>) -> [CGRect]) -> Hit<ID>? {
        for candidate in candidates {
            if let rectangle = geometry(candidate).first(where: { usable($0) && $0.contains(point) }) {
                return Hit(id: candidate.id, rectangle: rectangle)
            }
        }
        return nil
    }

    private static func validEnd(_ range: NSRange, limit: Int) -> Int? {
        guard range.location >= 0, range.location != NSNotFound, range.length > 0,
              range.length != NSNotFound, range.location <= limit, range.length <= limit - range.location else { return nil }
        return range.location + range.length
    }
    private static func isBoundary(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0, offset < source.length else { return true }
        return !(0xD800...0xDBFF).contains(source.character(at: offset - 1)) ||
               !(0xDC00...0xDFFF).contains(source.character(at: offset))
    }
    private static func usable(_ rectangle: CGRect) -> Bool {
        !rectangle.isNull && !rectangle.isInfinite && !rectangle.isEmpty &&
            [rectangle.minX, rectangle.minY, rectangle.maxX, rectangle.maxY].allSatisfy(\.isFinite)
    }

#if os(macOS)
    @MainActor public static func at(_ point: CGPoint, on page: PDFPage, pageText: String) -> Self? {
        at(point, on: page, pageText: pageText as NSString)
    }

    @MainActor public static func at(_ point: CGPoint, on page: PDFPage, pageText: NSString) -> Self? {
        guard let selection = page.selectionForLine(at: point),
              let line = physicalLine(selection, on: page, pageText: pageText),
              line.rectangle.contains(point) else { return nil }
        return line.text
    }

    @MainActor public static func physicalLine(_ selection: PDFSelection, on page: PDFPage,
                                               pageText: NSString) -> PhysicalLine? {
        guard selection.pages.count == 1, selection.pages.first === page,
              let text = selection.string, !text.isEmpty else { return nil }
        let rawBounds = selection.bounds(for: page)
        guard usable(rawBounds) else { return nil }
        let bounds = rawBounds.intersection(page.bounds(for: .cropBox))
        guard usable(bounds) else { return nil }
        let count = selection.numberOfTextRanges(on: page)
        guard count > 0, count <= 64 else { return nil }
        let ranges = (0..<count).map { selection.range(at: $0, on: page) }
        if let line = validate(ranges, lineText: text, pageText: pageText, nativeCharacterCount: page.numberOfCharacters) {
            return PhysicalLine(text: line, rectangle: bounds)
        }
        // PDFKit's native line ranges can include one original line terminator
        // even though selection.string omits it. Remove only that exact suffix;
        // all remaining bytes still pass the unchanged strict proof above.
        guard var adjusted = rangesWithOneLineEndRemoved(ranges, pageText: pageText,
                                                         nativeCharacterCount: page.numberOfCharacters) else { return nil }
        if adjusted.last?.length == 0 { adjusted.removeLast() }
        guard let line = validate(adjusted, lineText: text, pageText: pageText,
                                  nativeCharacterCount: page.numberOfCharacters) else { return nil }
        return PhysicalLine(text: line, rectangle: bounds)
    }

    private static func rangesWithOneLineEndRemoved(_ ranges: [NSRange], pageText: NSString,
                                                    nativeCharacterCount: Int) -> [NSRange]? {
        var previousEnd = 0, totalLength = 0
        for (index, range) in ranges.enumerated() {
            guard let end = validEnd(range, limit: min(pageText.length, nativeCharacterCount)),
                  index == 0 || range.location >= previousEnd,
                  range.length <= 32_770 - totalLength,
                  isBoundary(range.location, in: pageText), isBoundary(end, in: pageText) else { return nil }
            previousEnd = end; totalLength += range.length
        }
        guard let last = ranges.last else { return nil }
        let end = NSMaxRange(last), final = pageText.character(at: end - 1)
        let removed: Int
        if final == 0x000A {
            removed = last.length >= 2 && pageText.character(at: end - 2) == 0x000D ? 2 : 1
        } else if final == 0x000D { removed = 1 }
        else { return nil }
        var result = ranges
        result[result.count - 1].length -= removed
        return result
    }

    @MainActor public static func rectangles(for range: NSRange, on page: PDFPage) -> [CGRect] {
        // PDFKit raises an Objective-C exception for invalid ranges; reject
        // them before making the call rather than trying to catch Swift errors.
        guard validEnd(range, limit: page.numberOfCharacters) != nil,
              let selection = page.selection(for: range) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            let rawBounds = line.bounds(for: page)
            guard usable(rawBounds) else { return nil }
            let rectangle = rawBounds.intersection(page.bounds(for: .cropBox))
            return usable(rectangle) ? rectangle : nil
        }
    }
#endif
}
