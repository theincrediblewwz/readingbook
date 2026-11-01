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
        case .warmCotton: return NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1)
        case .mistWhite: return NSColor(srgbRed: 0.95, green: 0.95, blue: 0.93, alpha: 1)
        case .sagePaper: return NSColor(srgbRed: 0.92, green: 0.94, blue: 0.90, alpha: 1)
        }
    }
}

@MainActor enum ReadingPaperAssets {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 3; cache.totalCostLimit = 24 * 1024 * 1024; return cache
    }()
    static func image(_ style: ReadingPaperStyle) -> NSImage? {
        guard style != .plain else { return nil }
        if let image = images.object(forKey: style.rawValue as NSString) { return image }
        guard let url = Bundle.module.url(forResource: style.rawValue, withExtension: "png", subdirectory: "Paper"),
              let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: style.rawValue as NSString, cost: 1536 * 1024 * 4)
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

/// PDFKit supplies and retires only the visible page overlays. Multiplication
/// changes the white paper without washing out black glyphs or editing the PDF.
@MainActor final class ReadingPaperPageProvider: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    var style: ReadingPaperStyle = .plain {
        didSet { if oldValue != style { for view in overlays.allObjects { view.apply(style) } } }
    }
    private let overlays = NSHashTable<ReadingPaperNativeVeil>.weakObjects()
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = ReadingPaperNativeVeil(frame: .zero); overlay.apply(style); overlays.add(overlay); return overlay
    }
}

@MainActor final class ReadingPaperNativeVeil: NSView {
    private var style: ReadingPaperStyle?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func apply(_ next: ReadingPaperStyle) {
        guard style != next else { return }; style = next
        wantsLayer = true
        isHidden = next == .plain
        layer?.contents = ReadingPaperAssets.image(next)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.compositingFilter = next == .plain ? nil : CIFilter(name: "CIMultiplyCompositing")
    }
}

struct ReadingPaperTextVeil: NSViewRepresentable {
    let style: ReadingPaperStyle
    func makeNSView(context: Context) -> ReadingPaperNativeVeil { let view = ReadingPaperNativeVeil(frame: .zero); view.apply(style); return view }
    func updateNSView(_ view: ReadingPaperNativeVeil, context: Context) { view.apply(style) }
}
