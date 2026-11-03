import Foundation
#if os(macOS)
import PDFKit
#endif

public enum ReaderAnnotationColor: String, Codable, CaseIterable, Hashable, Sendable {
    case yellow, green, blue, pink
    public var title: String { switch self { case .yellow: return "黄色"; case .green: return "绿色"; case .blue: return "蓝色"; case .pink: return "粉色" } }
}
public enum ReaderAnnotationKind: String, Codable, Hashable, Sendable { case text, region }
/// Missing means the existing translucent highlighter. Text marks keep their
/// original range and line boxes; only their presentation changes.
public enum ReaderAnnotationLineStyle: String, Codable, CaseIterable, Hashable, Sendable { case straight, wavy }

/// PDF page-space coordinates (72 dpi, lower-left origin), one rectangle per selected line.
public struct ReaderQuadRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Stored only in project metadata. The original PDF is never rewritten.
/// A cross-page/noncontiguous selection creates one record per page text range.
public struct ReaderAnnotation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sourceHash: String
    public var page: Int
    public var text: String
    public var rangeLocation: Int
    public var rangeLength: Int
    public var quads: [ReaderQuadRect]
    public var color: ReaderAnnotationColor
    public var comment: String
    public var createdAt: Date
    public var updatedAt: Date
    public var trashedAt: Date?
    public var kind: ReaderAnnotationKind? = nil
    public var lineStyle: ReaderAnnotationLineStyle? = nil
    public var lineAppearance: ReaderUnderlineAppearance? = nil
    public var highlightAppearance: ReaderHighlightAppearance? = nil
    public var effectiveKind: ReaderAnnotationKind { kind ?? .text }
    public init(id: String = UUID().uuidString, sourceHash: String, page: Int, text: String, rangeLocation: Int, rangeLength: Int, quads: [ReaderQuadRect], color: ReaderAnnotationColor = .yellow, comment: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), trashedAt: Date? = nil, kind: ReaderAnnotationKind? = nil, lineStyle: ReaderAnnotationLineStyle? = nil) {
        self.id = id; self.sourceHash = sourceHash; self.page = page; self.text = text; self.rangeLocation = rangeLocation; self.rangeLength = rangeLength; self.quads = quads; self.color = color; self.comment = comment; self.createdAt = createdAt; self.updatedAt = updatedAt; self.trashedAt = trashedAt; self.kind = kind
        self.lineStyle = lineStyle
    }
}

public enum ReaderAnnotationValidator {
    public static func validate(_ annotation: ReaderAnnotation, in project: BookProject) throws {
        try validate(annotation, in: project, pageExists: project.units.contains(where: { $0.page == annotation.page }))
    }
    private static func validate(_ annotation: ReaderAnnotation, in project: BookProject, pageExists: Bool) throws {
        guard URL(fileURLWithPath: project.originalName).pathExtension.lowercased() == "pdf",
              annotation.sourceHash == project.sourceHash, UUID(uuidString: annotation.id) != nil,
              annotation.page >= 1, pageExists else {
            throw ReadingError.invalid("PDF批注标识、来源版本或页码无效。")
        }
        let validText = annotation.effectiveKind == .text && annotation.rangeLocation >= 0 && annotation.rangeLocation <= 100_000_000 && annotation.rangeLength > 0 && annotation.rangeLength <= 100_000_000 - annotation.rangeLocation && !annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let validRegion = annotation.effectiveKind == .region && annotation.lineStyle == nil && annotation.rangeLocation == 0 && annotation.rangeLength == 0 && annotation.text.isEmpty && annotation.quads.count == 1
        guard validText || validRegion, annotation.text.count <= 32_768,
              annotation.comment.count <= 16_000, !annotation.quads.isEmpty, annotation.quads.count <= 512 else {
            throw ReadingError.invalid("PDF批注文字范围、正文、评论或行框数量超出限制。")
        }
        guard annotation.lineAppearance == nil || (annotation.lineStyle != nil && annotation.effectiveKind == .text && annotation.lineAppearance?.isValid == true) else {
            throw ReadingError.invalid("下划线样式无效，原批注保留。")
        }
        guard annotation.highlightAppearance == nil || (annotation.effectiveKind == .text && annotation.lineStyle == nil && annotation.highlightAppearance?.isValid == true) else {
            throw ReadingError.invalid("荧光标记样式无效，原批注保留。")
        }
        guard annotation.quads.allSatisfy({ rect in
            [rect.x, rect.y, rect.width, rect.height].allSatisfy { $0.isFinite && abs($0) <= 10_000_000 } && rect.width > 0 && rect.height > 0
        }), annotation.createdAt.timeIntervalSinceReferenceDate.isFinite, annotation.updatedAt.timeIntervalSinceReferenceDate.isFinite,
        annotation.trashedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw ReadingError.invalid("PDF批注坐标或时间无效。") }
    }

    public static func validateAll(in project: BookProject) throws {
        let annotations = project.readerAnnotations ?? []
        guard annotations.count <= 100_000, Set(annotations.map(\.id)).count == annotations.count else { throw ReadingError.invalid("PDF批注过多或标识重复。") }
        let pages = Set(project.units.compactMap(\.page))
        for annotation in annotations { try validate(annotation, in: project, pageExists: pages.contains(annotation.page)) }
    }
}

#if os(macOS)
/// Render from durable page coordinates. These annotations live on the in-memory
/// PDFDocument only, including page-turn snapshots, never on the original file.
public enum ReaderAnnotationAppearance {
    public static func make(_ record: ReaderAnnotation, quad: ReaderQuadRect, crop: CGRect) -> PDFAnnotation? {
        guard [quad.x, quad.y, quad.width, quad.height].allSatisfy({ $0.isFinite }), quad.width > 0, quad.height > 0 else { return nil }
        let rect = CGRect(x: quad.x, y: quad.y, width: quad.width, height: quad.height).intersection(crop)
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let color: NSColor
        switch record.color { case .yellow: color = .systemYellow; case .green: color = .systemGreen; case .blue: color = .systemBlue; case .pink: color = .systemPink }
        let annotation: PDFAnnotation
        if record.effectiveKind == .region {
            annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            let border = PDFBorder(); border.lineWidth = 1.5; annotation.border = border
            annotation.color = color.withAlphaComponent(0.9); annotation.interiorColor = color.withAlphaComponent(0.1)
        } else if let style = record.lineStyle {
            let appearance = record.lineAppearance ?? ReaderUnderlineAppearance()
            guard appearance.isValid else { return nil }
            let thickness = CGFloat(appearance.thickness)
            let amplitude = style == .wavy ? min(0.85, rect.height * 0.06) : 0
            // Put the entire stroke, including its wave crest, below the line
            // box. The durable quad remains the original text geometry.
            let clearance: CGFloat = 1.5
            let padding: CGFloat = appearance.glow ? 3 : 0.5
            let bottom = max(crop.minY, rect.minY - clearance - thickness - 2 * amplitude - padding)
            let bounds = CGRect(x: rect.minX, y: bottom, width: rect.width, height: rect.maxY - bottom)
            let ink = ReaderUnderlinePDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            ink.highlightRect = rect; ink.appearance = appearance
            annotation = ink
            let border = PDFBorder(); border.lineWidth = thickness; annotation.border = border
            annotation.color = record.lineAppearance == nil ? color.withAlphaComponent(0.8) : NSColor(srgbRed: appearance.red, green: appearance.green, blue: appearance.blue, alpha: appearance.opacity)
            let path = NSBezierPath(); path.lineWidth = thickness; path.lineCapStyle = .round
            let baseline = max(amplitude + thickness / 2, rect.minY - bottom - clearance - thickness / 2 - amplitude)
            guard baseline + amplitude + thickness / 2 <= rect.minY - bottom - clearance + 0.001 else { return nil }
            path.move(to: CGPoint(x: 0, y: baseline))
            if style == .straight { path.line(to: CGPoint(x: rect.width, y: baseline)) }
            else {
                // Bounded sampling also handles unusually large PDF page units.
                let steps = max(1, min(4096, Int(ceil(rect.width / 0.65))))
                for i in 1...steps {
                    let x = rect.width * CGFloat(i) / CGFloat(steps)
                    path.line(to: CGPoint(x: x, y: baseline + sin(x * 2 * .pi / appearance.waveLength) * amplitude))
                }
            }
            annotation.add(path)
        } else {
            annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            if let appearance = record.highlightAppearance {
                guard appearance.isValid else { return nil }
                annotation.color = appearance.nativeColor
            } else { annotation.color = color.withAlphaComponent(0.42) }
        }
        annotation.contents = record.comment.isEmpty ? record.text : record.comment
        return annotation
    }
}

private final class ReaderUnderlinePDFAnnotation: PDFAnnotation {
    var highlightRect = CGRect.zero
    var appearance = ReaderUnderlineAppearance()
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.setBlendMode(.multiply)
        if appearance.highlighter {
            context.setFillColor(color.withAlphaComponent(appearance.opacity * 0.2).cgColor)
            context.fill(highlightRect)
        }
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.setStrokeColor(color.cgColor); context.setLineWidth(border?.lineWidth ?? 0.8); context.setLineCap(.round)
        if appearance.glow { context.setShadow(offset: .zero, blur: 2, color: color.withAlphaComponent(0.45).cgColor) }
        for path in paths ?? [] { context.addPath(path.cgPath); context.strokePath() }
    }
}

public enum ReaderAnnotationCapture {
    /// Resolve an explicit click without depending on prepared hover geometry.
    /// This still requires a physical glyph hit; margins are never guessed.
    public static func sentence(at point: CGPoint, page: PDFPage, document: PDFDocument, sourceHash: String) throws -> ReaderAnnotation? {
        guard page.document === document, let text = page.string, text.utf8.count <= 2_000_000,
              point.x.isFinite, point.y.isFinite else { return nil }
        guard let hit = PDFNativeTextGeometry.character(at: point, on: page),
              let range = ReadingSentenceAnchors.ranges(in: text).first(where: { NSLocationInRange(hit.range.location, $0) }) else { return nil }
        return try sentence(range: range, page: page, document: document, sourceHash: sourceHash, point: point)
    }
    /// A context command must physically hit this exact native text range.
    /// In particular, a blank margin or a later equal sentence is not a match.
    public static func sentence(range: NSRange, page: PDFPage, document: PDFDocument, sourceHash: String, point: CGPoint) throws -> ReaderAnnotation? {
        guard page.document === document, range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= 100_000_000, range.length <= 100_000_000 - range.location,
              point.x.isFinite, point.y.isFinite, let selection = page.selection(for: range) else { return nil }
        let records = try capture(selection: selection, document: document, sourceHash: sourceHash)
        guard records.count == 1, var record = records.first, let native = page.string as NSString?,
              range.location <= native.length, range.length <= native.length - range.location,
              record.rangeLocation <= range.location, record.rangeLocation + record.rangeLength >= NSMaxRange(range),
              record.rangeLocation + record.rangeLength <= native.length,
              record.quads.contains(where: { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) }) else { return nil }
        // PDFKit sometimes includes the following line break in its reported
        // selection range, even though the requested native range and string
        // end at the punctuation. Admit only verified whitespace expansion;
        // retain the precise requested sentence instead of losing its menu.
        let before = native.substring(with: NSRange(location: record.rangeLocation, length: range.location - record.rangeLocation))
        let after = native.substring(with: NSRange(location: NSMaxRange(range), length: record.rangeLocation + record.rangeLength - NSMaxRange(range)))
        guard (before + after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        record.rangeLocation = range.location; record.rangeLength = range.length
        record.text = native.substring(with: range)
        return record
    }
    /// PDFKit ranges are page-local UTF-16 character ranges. Never apply a cross-page range to just the first page.
    public static func capture(selection: PDFSelection, document: PDFDocument, sourceHash: String) throws -> [ReaderAnnotation] {
        guard !document.isLocked, document.allowsCopying, !sourceHash.isEmpty else { throw ReadingError.invalid("PDF尚未解锁、禁止复制或缺少来源版本。") }
        var records: [ReaderAnnotation] = []
        for page in selection.pages.sorted(by: { document.index(for: $0) < document.index(for: $1) }) {
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound, page.document === document else { throw ReadingError.invalid("选中文字不属于当前PDF。") }
            for index in 0..<selection.numberOfTextRanges(on: page) {
                var range = selection.range(at: index, on: page)
                guard range.location != NSNotFound, range.location >= 0, range.length > 0,
                      let textSelection = page.selection(for: range), var text = textSelection.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let native = page.string as NSString?, range.location <= native.length, range.length <= native.length - range.location {
                    let slice = native.substring(with: range), trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.utf8.elementsEqual(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                       let exact = slice.range(of: trimmed, options: .literal) {
                        let local = NSRange(exact, in: slice)
                        range = NSRange(location: range.location + local.location, length: local.length); text = trimmed
                    }
                }
                let rects = textSelection.selectionsByLine().map { $0.bounds(for: page).intersection(page.bounds(for: .cropBox)) }.filter { !$0.isNull && !$0.isEmpty }
                guard !rects.isEmpty, rects.count <= 512, text.count <= 32_768, records.count < 512,
                      range.location <= 100_000_000, range.length <= 100_000_000 - range.location else { throw ReadingError.invalid("选中文字过多或位置无法核对，请缩小选择。") }
                records.append(ReaderAnnotation(sourceHash: sourceHash, page: pageIndex + 1, text: text, rangeLocation: range.location, rangeLength: range.length, quads: rects.map { ReaderQuadRect(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height) }))
            }
        }
        guard !records.isEmpty else { throw ReadingError.invalid("当前选择没有PDF文字范围。扫描页或无文字选择时，可用阅读菜单的“框选区域批注”。") }
        return records
    }
}
#endif
