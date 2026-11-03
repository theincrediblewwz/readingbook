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
    public static func character(at point: CGPoint, on page: PDFPage) -> CharacterHit? {
        guard point.x.isFinite, point.y.isFinite, let native = page.string as NSString?, native.length <= 1_000_000 else { return nil }
        return autoreleasepool {
            // Word hits require ink, while selection boxes include the whole
            // character cell. Probe only a small neighbourhood, and still
            // require the ORIGINAL pointer to lie inside a verified text box.
            let probes = [point, .init(x: point.x-3, y: point.y), .init(x: point.x+3, y: point.y),
                          .init(x: point.x, y: point.y-4), .init(x: point.x, y: point.y+4),
                          .init(x: point.x-7, y: point.y), .init(x: point.x+7, y: point.y)]
            for probe in probes {
                guard let word = page.selectionForWord(at: probe) ?? page.selectionForLine(at: probe),
                      word.bounds(for: page).insetBy(dx: -1.5, dy: -1.5).contains(point), word.numberOfTextRanges(on: page) <= 16 else { continue }
                var hits: [CharacterHit] = []
                for i in 0..<word.numberOfTextRanges(on: page) {
                    let range = word.range(at: i, on: page)
                    guard valid(range, in: native), range.length <= 512 else { continue }
                    var offset = range.location
                    while offset < NSMaxRange(range) {
                        let character = native.rangeOfComposedCharacterSequence(at: offset)
                        if let hit = hit(character, native: native, page: page), hit.bounds.insetBy(dx: -1.5, dy: -1.5).contains(point) { hits.append(hit) }
                        offset = NSMaxRange(character)
                    }
                }
                if let result = hits.min(by: { a, b in
                    let ad = hypot(a.bounds.midX - point.x, a.bounds.midY - point.y)
                    let bd = hypot(b.bounds.midX - point.x, b.bounds.midY - point.y)
                    return ad == bd ? a.range.location < b.range.location : ad < bd
                }) { return result }
            }
            return nil
        }
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
    private static func hit(_ range: NSRange, native: NSString, page: PDFPage) -> CharacterHit? {
        guard valid(range, in: native) else { return nil }
        let text = native.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selection = page.selection(for: range), selection.string?.utf8.elementsEqual(text.utf8) == true else { return nil }
        let rect = selection.bounds(for: page)
        guard !rect.isEmpty, !rect.isNull, [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) else { return nil }
        return CharacterHit(range: range, bounds: rect)
    }
}
#endif
