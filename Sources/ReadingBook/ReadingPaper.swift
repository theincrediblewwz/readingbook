import AppKit
import CoreImage
import PDFKit
import SwiftUI

enum ReadingPaperStyle: String, CaseIterable, Identifiable {
    case plain, warmCotton = "warm-cotton", mistWhite = "mist-white", sagePaper = "sage-paper"
    var id: String { rawValue }
    var title: String {
        switch self { case .plain: return "原始白纸"; case .warmCotton: return "暖白棉纸"; case .mistWhite: return "雾白纸"; case .sagePaper: return "淡鼠尾草" }
    }
    var color: NSColor {
        switch self {
        case .plain: return .white
        case .warmCotton: return NSColor(srgbRed: 0.957, green: 0.941, blue: 0.906, alpha: 1)
        case .mistWhite: return NSColor(srgbRed: 0.957, green: 0.961, blue: 0.957, alpha: 1)
        case .sagePaper: return NSColor(srgbRed: 0.918, green: 0.941, blue: 0.910, alpha: 1)
        }
    }
}

@MainActor enum ReadingPaperAssets {
    /// Keep the approved 01/06/09 tones and the existing smooth-paper treatment.
    /// All surfaces and page turns share the same bounded material cache.
    static let grainStrength: CGFloat = 0.14
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 3; cache.totalCostLimit = 24 * 1024 * 1024; return cache
    }()
    static func image(_ style: ReadingPaperStyle) -> NSImage? {
        guard style != .plain else { return nil }
        if let image = images.object(forKey: style.rawValue as NSString) { return image }
        guard let bundle = ReadingBookResources.bundle,
              let url = bundle.url(forResource: style.rawValue, withExtension: "png", subdirectory: "Paper"),
              let original = NSImage(contentsOf: url),
              let source = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width * source.height <= 4_000_000,
              let canvas = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height))
        canvas.setFillColor(style.color.cgColor); canvas.fill(rect)
        canvas.setAlpha(grainStrength); canvas.draw(source, in: rect)
        guard let material = canvas.makeImage() else { return nil }
        let image = NSImage(cgImage: material, size: original.size)
        images.setObject(image, forKey: style.rawValue as NSString, cost: source.width * source.height * 4)
        return image
    }
}

struct ReaderPaperPanel: View {
    @AppStorage("reading.paperStyle") private var selected = ReadingPaperStyle.plain.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("阅读纸张").font(.system(size: 16, weight: .semibold))
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                ForEach(ReadingPaperStyle.allCases) { style in
                    Button { selected = style.rawValue } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Color(nsColor: style.color)
                                if let image = ReadingPaperAssets.image(style) { Image(nsImage: image).resizable().scaledToFill() }
                                HStack { Spacer(); if selected == style.rawValue { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent).padding(8) } }.frame(maxHeight: .infinity, alignment: .top)
                                Text("阅读").font(.system(size: 22, design: .serif)).foregroundStyle(Color.black.opacity(0.75))
                            }.frame(height: 74).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.accent.opacity(selected == style.rawValue ? 0.55 : 0.12)) }
                            Text(style.title).font(.system(size: 13))
                        }.padding(6).contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(ReadingQuietButtonStyle()).accessibilityLabel(style.title)
                        .accessibilityValue(selected == style.rawValue ? "已选中" : "未选中")
                        .help("切换为" + style.title + "；原书文件和批注不变。")
                }
            }
        }.padding(20).frame(width: 328).background(Palette.surface)
    }
}

/// One material spans the visible pages and their note reserve. Its mask keeps
/// page gaps clear; multiplication preserves black glyphs and the original PDF.
@MainActor final class ReadingPaperNativeVeil: NSView {
    private(set) var style: ReadingPaperStyle = .plain
    private(set) var paperRects: [CGRect]?
    private var materialApplied = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func apply(_ next: ReadingPaperStyle) {
        guard !materialApplied || style != next else { return }; style = next; materialApplied = true
        wantsLayer = true
        isHidden = next == .plain
        layer?.contents = ReadingPaperAssets.image(next)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.compositingFilter = next == .plain ? nil : CIFilter(name: "CIMultiplyCompositing")
    }
    func cover(_ rects: [CGRect]) {
        guard paperRects != rects || layer?.mask?.frame != bounds else { return }
        paperRects = rects
        let mask = CAShapeLayer(); mask.frame = bounds
        let path = CGMutablePath(); path.addRects(rects); mask.path = path
        mask.fillColor = NSColor.white.cgColor; layer?.mask = mask
    }
}

struct ReadingPaperTextVeil: NSViewRepresentable {
    let style: ReadingPaperStyle
    func makeNSView(context: Context) -> ReadingPaperNativeVeil { let view = ReadingPaperNativeVeil(frame: .zero); view.apply(style); return view }
    func updateNSView(_ view: ReadingPaperNativeVeil, context: Context) { view.apply(style) }
}

struct ReadingPaperBackground: View {
    @AppStorage("reading.paperStyle") private var styleName = ReadingPaperStyle.plain.rawValue
    var body: some View {
        let style = ReadingPaperStyle(rawValue: styleName) ?? .plain
        Color(nsColor: style.color)
    }
}

/// All three note presentations resolve the same explicit color, with the
/// legacy nil value inheriting the book's material without rewriting old data.
struct PositionNoteBackground: View {
    let paperStyle: String?
    @AppStorage("reading.paperStyle") private var inherited = ReadingPaperStyle.plain.rawValue
    var body: some View { Color(nsColor: Self.style(paperStyle, inherited: inherited).color) }
    static func style(_ value: String?, inherited: String) -> ReadingPaperStyle {
        value.flatMap(ReadingPaperStyle.init(rawValue:)) ?? ReadingPaperStyle(rawValue: inherited) ?? .plain
    }
}
