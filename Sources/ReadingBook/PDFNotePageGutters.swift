import AppKit
import PDFKit
import ObjectiveC

@MainActor private var readingOriginalBoxesKey: UInt8 = 0
private final class ReadingOriginalPDFBoxes: NSObject {
    let crop: CGRect
    let media: CGRect
    init(_ page: PDFPage) { crop = page.bounds(for: .cropBox); media = page.bounds(for: .mediaBox) }
}

@MainActor extension PDFPage {
    /// Source anchors, annotation quads and preparation proofs always use the
    /// imported page. A display-only note gutter must not enter those values.
    func readingSourceBounds(for box: PDFDisplayBox) -> CGRect {
        if let original = objc_getAssociatedObject(self, &readingOriginalBoxesKey) as? ReadingOriginalPDFBoxes {
            if box == .cropBox { return original.crop }
            if box == .mediaBox { return original.media }
        }
        return bounds(for: box)
    }
}

/// Public PDFKit boxes reserve real space between native continuous pages.
/// Only the UI document changes in memory; this class never serializes a PDF.
@MainActor final class PDFNotePageGutters {
    private struct Entry { let page: PDFPage; let original: ReadingOriginalPDFBoxes }
    private var entries: [ObjectIdentifier: Entry] = [:]
    func contains(_ page: PDFPage) -> Bool { entries[ObjectIdentifier(page)] != nil }
    @discardableResult func apply(pages: [PDFPage], widthRatio: CGFloat) -> Bool {
        let wanted = Set(pages.map(ObjectIdentifier.init))
        var changed = false
        for key in Array(entries.keys) where !wanted.contains(key) || widthRatio <= 0 {
            if let old = entries.removeValue(forKey: key) {
                old.page.setBounds(old.original.crop, for: .cropBox)
                old.page.setBounds(old.original.media, for: .mediaBox)
                objc_setAssociatedObject(old.page, &readingOriginalBoxesKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                changed = true
            }
        }
        guard widthRatio.isFinite, widthRatio > 0 else { return changed }
        for page in pages {
            let key = ObjectIdentifier(page)
            let original = entries[key]?.original ?? (objc_getAssociatedObject(page, &readingOriginalBoxesKey) as? ReadingOriginalPDFBoxes) ?? ReadingOriginalPDFBoxes(page)
            let crop = original.crop, angle = ((page.rotation % 360) + 360) % 360
            let width = (angle == 90 || angle == 270 ? crop.height : crop.width) * widthRatio
            guard width.isFinite, width > 0, width < 10_000_000 else { continue }
            let expanded = Self.expanded(crop, rotation: angle, width: width)
            if page.bounds(for: .cropBox) != expanded {
                objc_setAssociatedObject(page, &readingOriginalBoxesKey, original, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                // crop bounds are intersected with media bounds by PDFKit.
                page.setBounds(original.media.union(expanded), for: .mediaBox)
                page.setBounds(expanded, for: .cropBox)
                entries[key] = Entry(page: page, original: original); changed = true
            }
        }
        return changed
    }
    func restore() { _ = apply(pages: [], widthRatio: 0) }
    static func expanded(_ crop: CGRect, rotation: Int, width: CGFloat) -> CGRect {
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height + width)
        case 180: return CGRect(x: crop.minX - width, y: crop.minY, width: crop.width + width, height: crop.height)
        case 270: return CGRect(x: crop.minX, y: crop.minY - width, width: crop.width, height: crop.height + width)
        default: return CGRect(x: crop.minX, y: crop.minY, width: crop.width + width, height: crop.height)
        }
    }
}
