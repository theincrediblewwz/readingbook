import Foundation
#if os(macOS)
import PDFKit
#endif

public enum ReaderAnnotationColor: String, Codable, CaseIterable, Hashable, Sendable {
    case yellow, green, blue, pink
    public var title: String { switch self { case .yellow: return "黄色"; case .green: return "绿色"; case .blue: return "蓝色"; case .pink: return "粉色" } }
}
public enum ReaderAnnotationKind: String, Codable, Hashable, Sendable { case text, region }

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
    public var effectiveKind: ReaderAnnotationKind { kind ?? .text }
    public init(id: String = UUID().uuidString, sourceHash: String, page: Int, text: String, rangeLocation: Int, rangeLength: Int, quads: [ReaderQuadRect], color: ReaderAnnotationColor = .yellow, comment: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), trashedAt: Date? = nil, kind: ReaderAnnotationKind? = nil) {
        self.id = id; self.sourceHash = sourceHash; self.page = page; self.text = text; self.rangeLocation = rangeLocation; self.rangeLength = rangeLength; self.quads = quads; self.color = color; self.comment = comment; self.createdAt = createdAt; self.updatedAt = updatedAt; self.trashedAt = trashedAt; self.kind = kind
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
        let validRegion = annotation.effectiveKind == .region && annotation.rangeLocation == 0 && annotation.rangeLength == 0 && annotation.text.isEmpty && annotation.quads.count == 1
        guard validText || validRegion, annotation.text.count <= 32_768,
              annotation.comment.count <= 16_000, !annotation.quads.isEmpty, annotation.quads.count <= 512 else {
            throw ReadingError.invalid("PDF批注文字范围、正文、评论或行框数量超出限制。")
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
public enum ReaderAnnotationCapture {
    /// PDFKit ranges are page-local UTF-16 character ranges. Never apply a cross-page range to just the first page.
    public static func capture(selection: PDFSelection, document: PDFDocument, sourceHash: String) throws -> [ReaderAnnotation] {
        guard !document.isLocked, document.allowsCopying, !sourceHash.isEmpty else { throw ReadingError.invalid("PDF尚未解锁、禁止复制或缺少来源版本。") }
        var records: [ReaderAnnotation] = []
        for page in selection.pages.sorted(by: { document.index(for: $0) < document.index(for: $1) }) {
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound, page.document === document else { throw ReadingError.invalid("选中文字不属于当前PDF。") }
            for index in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: index, on: page)
                guard range.location != NSNotFound, range.location >= 0, range.length > 0,
                      let textSelection = page.selection(for: range), let text = textSelection.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
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
