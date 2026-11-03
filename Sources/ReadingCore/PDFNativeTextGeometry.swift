import Foundation
#if os(macOS)
import PDFKit

/// A page's glyph hit index can exclude the line separators in its extracted
/// string. Use PDFSelection's native UTF-16 ranges and boxes at this boundary.
public enum PDFNativeTextGeometry {
    public struct CharacterHit {
        public let range: NSRange
        public let bounds: CGRect
    }
    /// A short-lived map for one native page. Line rectangles cover complete
    /// text cells, including the empty spaces inside Chinese characters.
    /// Character boxes are prepared only for lines reached by the pointer.
    public final class PageMap {
        private let page: PDFPage
        private let native: NSString
        private let lines: [(bounds: CGRect, ranges: [NSRange])]
        private var prepared: [Int: [CharacterHit]] = [:]
        public init?(page: PDFPage) {
            guard let native = page.string as NSString?, native.length > 0, native.length <= 1_000_000,
                  let selection = page.selection(for: .init(location: 0, length: native.length)) else { return nil }
            let selections = selection.selectionsByLine()
            guard selections.count <= 20_000 else { return nil }
            self.page = page; self.native = native
            lines = selections.compactMap { line in
                let bounds = line.bounds(for: page), count = line.numberOfTextRanges(on: page)
                guard !bounds.isEmpty, !bounds.isNull, count > 0, count <= 16 else { return nil }
                let ranges = (0..<count).map { line.range(at: $0, on: page) }.filter { PDFNativeTextGeometry.valid($0, in: native) }
                return ranges.isEmpty ? nil : (bounds, ranges)
            }
        }
        public func character(at point: CGPoint) -> CharacterHit? {
            guard point.x.isFinite, point.y.isFinite else { return nil }
            let candidates = lines.indices.filter { lines[$0].bounds.insetBy(dx: -1.5, dy: -1.5).contains(point) }
            for index in candidates {
                if prepared[index] == nil {
                    prepared[index] = autoreleasepool {
                        var result: [CharacterHit] = []
                        for range in lines[index].ranges where range.length <= 2048 {
                            var offset = range.location
                            while offset < NSMaxRange(range) {
                                let character = native.rangeOfComposedCharacterSequence(at: offset)
                                if let value = PDFNativeTextGeometry.hit(character, native: native, page: page, allowsSpacing: true) { result.append(value) }
                                offset = NSMaxRange(character)
                            }
                        }
                        return result
                    }
                }
                if let result = prepared[index]?.filter({ $0.bounds.insetBy(dx: -1.5, dy: -1.5).contains(point) }).min(by: { a, b in
                    let ad = hypot(a.bounds.midX - point.x, a.bounds.midY - point.y)
                    let bd = hypot(b.bounds.midX - point.x, b.bounds.midY - point.y)
                    return ad == bd ? a.range.location < b.range.location : ad < bd
                }) { return result }
            }
            return nil
        }
    }
    public static func character(at point: CGPoint, on page: PDFPage) -> CharacterHit? {
        PageMap(page: page)?.character(at: point)
    }
    /// The middle source character's real rectangle, within this exact quote.
    /// A separator at the midpoint is skipped, never treated as the prior glyph.
    public static func midpoint(in range: NSRange, on page: PDFPage) -> CGRect? {
        guard let native = page.string as NSString?, valid(range, in: native) else { return nil }
        let middle = range.location + range.length / 2
        return autoreleasepool {
            for distance in 0..<min(range.length, 1024) {
                for offset in distance == 0 ? [middle] : [middle + distance, middle - distance] where NSLocationInRange(offset, range) {
                    let character = native.rangeOfComposedCharacterSequence(at: offset)
                    guard character.location >= range.location, NSMaxRange(character) <= NSMaxRange(range) else { continue }
                    if let result = hit(character, native: native, page: page) { return result.bounds }
                }
            }
            return nil
        }
    }
    private static func valid(_ range: NSRange, in native: NSString) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length > 0 && range.location < native.length && range.length <= native.length - range.location
    }
    private static func hit(_ range: NSRange, native: NSString, page: PDFPage, allowsSpacing: Bool = false) -> CharacterHit? {
        guard valid(range, in: native) else { return nil }
        let text = native.substring(with: range)
        guard text.rangeOfCharacter(from: .newlines) == nil,
              allowsSpacing || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selection = page.selection(for: range), selection.string?.utf8.elementsEqual(text.utf8) == true else { return nil }
        let rect = selection.bounds(for: page)
        guard !rect.isEmpty, !rect.isNull, [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) else { return nil }
        return CharacterHit(range: range, bounds: rect)
    }
}
#endif
