import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import PDFKit
import SwiftUI

/// GPU page geometry acts on the rendered original glyphs and paper together.
/// Only the two pages in the current turn are rendered; no document is created,
/// flattened on disk or eagerly rasterized as a whole book.
@MainActor final class PDFPaperCurl: MTKView, MTKViewDelegate {
    private static let renderer: (MTLDevice, MTLCommandQueue, CIContext)? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return (device, queue, CIContext(mtlDevice: device, options: [.cacheIntermediates: false]))
    }()
    private let imageContext: CIContext
    private let queue: MTLCommandQueue
    private let curl = CIFilter.pageCurlWithShadowTransition()
    private var extent: CGRect
    private let backwards: Bool
    private let pixelScale: CGFloat
    private let materialFrame: CGRect
    private let initialSurface: CGRect
    private let fitsVisibleSheets: Bool
    private let paper: ReadingPaperStyle
    private let background: NSColor
    private let noteMarginWidth: CGFloat
    private let oldImage: CIImage
    private let poster = NSImageView()
    private(set) var targetRaster: CGImage?
    let originalPageFrame: CGRect
    private(set) var preparedPageFrame: CGRect?
    private(set) var targetPrepared = false
    var viewportSize: CGSize { materialFrame.size }
    private var firstFramePresented = false
    private var began: CFTimeInterval?
    private var finished = false
    var completion: (() -> Void)?
    private(set) var renderedFrames = 0
    private(set) var progressSamples: [Double] = []
    static var supported: Bool { renderer != nil }

    convenience init?(frame: CGRect, from: PDFPage, fromFrame: CGRect, to: PDFPage, toFrame: CGRect, backwards: Bool, paper: ReadingPaperStyle, background: NSColor, scale: CGFloat) {
        self.init(frame: frame, from: from, fromFrame: fromFrame, backwards: backwards, paper: paper, background: background, scale: scale)
        guard prepareTarget(to, in: toFrame) else { return nil }
    }

    /// Mount the old sheet before PDFKit changes pages. Metal starts only after
    /// the destination's native layout has settled behind this opaque cover.
    init?(frame: CGRect, from: PDFPage, fromFrame: CGRect, backwards: Bool, paper: ReadingPaperStyle, background: NSColor,
          scale: CGFloat, materialFrame: CGRect? = nil, noteMarginWidth: CGFloat = 0,
          oldNoteMargin: (image: CGImage, frame: CGRect)? = nil, connections: [PositionNoteConnection] = [], fitsVisibleSheets: Bool = false) {
        guard frame.width > 10, frame.height > 10, let (device, queue, context) = Self.renderer else { return nil }
        let pixelScale = min(max(1, scale), 4096 / max(frame.width, frame.height), sqrt(4_000_000 / (frame.width * frame.height)))
        let pixels = CGSize(width: max(2, floor(frame.width * pixelScale)), height: max(2, floor(frame.height * pixelScale)))
        let rect = CGRect(origin: .zero, size: pixels)
        let materialFrame = materialFrame ?? frame
        guard let old = Self.raster(from, in: fromFrame, surface: frame, material: materialFrame, extent: rect,
                                   scale: pixelScale, paper: paper, background: background, noteMarginWidth: noteMarginWidth, note: oldNoteMargin, connections: connections) else { return nil }
        self.queue = queue; imageContext = context; extent = rect; self.backwards = backwards
        self.pixelScale = pixelScale; self.materialFrame = materialFrame; self.paper = paper
        initialSurface = frame; self.fitsVisibleSheets = fitsVisibleSheets
        self.background = background; self.noteMarginWidth = noteMarginWidth; oldImage = CIImage(cgImage: old)
        originalPageFrame = fromFrame
        super.init(frame: frame, device: device)
        framebufferOnly = false; colorPixelFormat = .bgra8Unorm
        autoResizeDrawable = false; drawableSize = pixels
        preferredFramesPerSecond = 60; enableSetNeedsDisplay = false; isPaused = true
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false; layer?.masksToBounds = true
        poster.frame = bounds; poster.autoresizingMask = [.width, .height]; poster.imageScaling = .scaleAxesIndependently
        poster.image = NSImage(cgImage: old, size: frame.size); addSubview(poster)
        curl.backsideImage = CIImage(color: CIColor(color: paper.color) ?? .white).cropped(to: rect)
        curl.extent = rect; curl.shadowExtent = rect
        curl.radius = Float(pixels.width * 0.13); curl.angle = .pi - .pi / 10
        curl.shadowAmount = 0.42; curl.shadowSize = 0.13
        delegate = self
        setAccessibilityElement(false)
    }
    @discardableResult func prepareTarget(_ page: PDFPage, in pageFrame: CGRect, noteMarginWidth targetMarginWidth: CGFloat? = nil) -> Bool {
        guard !targetPrepared, !finished else { return false }
        let nextMargin = targetMarginWidth ?? noteMarginWidth
        if fitsVisibleSheets {
            // Cover the entire viewport while native PDFKit changes pages.
            // Once both geometries are known, curl their visible union so a
            // wider/rotated destination cannot appear beside the old sheet.
            var sourceSheet = originalPageFrame, targetSheet = pageFrame
            sourceSheet.size.width += noteMarginWidth; targetSheet.size.width += nextMargin
            let visible = sourceSheet.intersection(initialSurface).union(targetSheet.intersection(initialSurface))
            guard !visible.isNull, visible.width > 10, visible.height > 10 else { return false }
            frame = visible
            extent = CGRect(x: 0, y: 0, width: floor(visible.width * pixelScale), height: floor(visible.height * pixelScale))
            drawableSize = extent.size
            poster.autoresizingMask = []
            poster.frame = CGRect(x: initialSurface.minX - visible.minX, y: initialSurface.minY - visible.minY,
                width: initialSurface.width, height: initialSurface.height)
            curl.extent = extent; curl.shadowExtent = extent
            curl.backsideImage = CIImage(color: CIColor(color: paper.color) ?? .white).cropped(to: extent)
            curl.radius = Float(extent.width * 0.13)
        }
        guard
              let rendered = Self.raster(page, in: pageFrame, surface: frame, material: materialFrame, extent: extent,
                  scale: pixelScale, paper: paper, background: background, noteMarginWidth: nextMargin, note: nil) else { return false }
        targetRaster = rendered
        preparedPageFrame = pageFrame
        let next = CIImage(cgImage: rendered)
        let old = oldImage.transformed(by: CGAffineTransform(translationX: (initialSurface.minX - frame.minX) * pixelScale,
            y: (initialSurface.minY - frame.minY) * pixelScale)).cropped(to: extent)
        curl.inputImage = backwards ? next : old; curl.targetImage = backwards ? old : next
        targetPrepared = true; isPaused = false; return true
    }
    private static func raster(_ page: PDFPage, in pageFrame: CGRect, surface: CGRect, material: CGRect, extent: CGRect,
                               scale: CGFloat, paper: ReadingPaperStyle, background: NSColor, noteMarginWidth: CGFloat,
                               note: (image: CGImage, frame: CGRect)?, connections: [PositionNoteConnection] = []) -> CGImage? {
        guard let raw = page.pageRef,
              let canvas = CGContext(data: nil, width: Int(extent.width), height: Int(extent.height), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func local(_ r: CGRect) -> CGRect { CGRect(x: (r.minX - surface.minX) * scale, y: (r.minY - surface.minY) * scale, width: r.width * scale, height: r.height * scale) }
        canvas.setFillColor(background.cgColor); canvas.fill(extent)
        let location = local(pageFrame)
        var pageSize = page.bounds(for: .cropBox).size
        if abs(page.rotation) % 180 == 90 { pageSize = CGSize(width: pageSize.height, height: pageSize.width) }
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        canvas.saveGState(); canvas.clip(to: location); canvas.setFillColor(NSColor.white.cgColor); canvas.fill(location)
        // Normalize crop/rotation at the page's own size, then explicitly use
        // PDFKit's current viewport scale. The drawing transform alone can
        // retain unit scale for an enlarged rectangle and shrink visible glyphs
        // during the turn, even though its page frame is the right size.
        canvas.translateBy(x: location.minX, y: location.minY)
        canvas.scaleBy(x: location.width / pageSize.width, y: location.height / pageSize.height)
        canvas.concatenate(raw.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true))
        canvas.drawPDFPage(raw)
        canvas.restoreGState()
        // PDFAnnotation.draw already accounts for its page's crop origin and
        // rotation. Applying the raw PDF transform again would move it twice.
        if !page.annotations.isEmpty {
            canvas.saveGState(); canvas.clip(to: location)
            canvas.translateBy(x: location.minX, y: location.minY)
            canvas.scaleBy(x: location.width / pageSize.width, y: location.height / pageSize.height)
            for annotation in page.annotations where annotation.shouldDisplay { annotation.draw(with: .cropBox, in: canvas) }
            canvas.restoreGState()
        }
        var sheet = pageFrame
        sheet.size.width += noteMarginWidth
        if let texture = ReadingPaperAssets.image(paper)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            canvas.saveGState()
            canvas.clip(to: local(sheet)); canvas.setBlendMode(.multiply)
            let k = max(material.width / CGFloat(texture.width), material.height / CGFloat(texture.height))
            let textureRect = CGRect(x: material.midX - CGFloat(texture.width) * k / 2,
                                     y: material.midY - CGFloat(texture.height) * k / 2,
                                     width: CGFloat(texture.width) * k, height: CGFloat(texture.height) * k)
            canvas.draw(texture, in: local(textureRect)); canvas.restoreGState()
        }
        if !connections.isEmpty {
            canvas.saveGState()
            canvas.translateBy(x: -surface.minX * scale, y: (material.height - surface.minY) * scale)
            canvas.scaleBy(x: scale, y: -scale)
            canvas.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
            canvas.setLineWidth(0.7); canvas.setLineCap(.round); canvas.setLineJoin(.round)
            for connection in connections {
                canvas.addPath(connection.line.cgPath); canvas.strokePath()
                canvas.setFillColor(NSColor(Palette.accent).withAlphaComponent(0.5).cgColor)
                canvas.fillEllipse(in: CGRect(x: connection.start.x - 1.7, y: connection.start.y - 1.7, width: 3.4, height: 3.4))
            }
            canvas.restoreGState()
        }
        if let note { canvas.draw(note.image, in: local(note.frame)) }
        PDFBookEdges.paint(pageFrame: local(sheet), paper: paper, unitScale: scale, in: canvas)
        return canvas.makeImage()
    }
    required init(coder: NSCoder) { fatalError("Paper curl views are created programmatically") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    func draw(in view: MTKView) {
        guard !finished, targetPrepared, let drawable = currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        if began == nil { began = now }
        let t = min(1, (now - (began ?? now)) / 0.60)
        let eased = t * t * (3 - 2 * t)
        curl.time = Float(backwards ? 1 - eased : eased)
        guard let output = curl.outputImage?.cropped(to: extent) else { finish(); return }
        imageContext.render(output, to: drawable.texture, commandBuffer: buffer, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        if !firstFramePresented {
            firstFramePresented = true
            drawable.addPresentedHandler { [weak self] _ in Task { @MainActor in self?.poster.isHidden = true } }
        }
        if t >= 1 { buffer.addCompletedHandler { [weak self] _ in Task { @MainActor in self?.finish() } } }
        buffer.present(drawable); buffer.commit()
        renderedFrames += 1
        if progressSamples.count < 90 { progressSamples.append(t) }
    }
    func cancel() { finished = true; isPaused = true; delegate = nil; completion = nil; removeFromSuperview() }
    private func finish() {
        guard !finished else { return }; finished = true; isPaused = true
        if let targetRaster { poster.frame = bounds; poster.image = NSImage(cgImage: targetRaster, size: bounds.size); poster.isHidden = false }
        let done = completion; completion = nil
        DispatchQueue.main.async { done?() }
    }
}

/// A gutter inside the page and a few quiet leaves beyond its right edge.
/// These decorations never receive pointer events or change PDF coordinates.
@MainActor final class PDFBookEdges: NSView {
    var pageFrame = CGRect.zero { didSet { needsDisplay = true } }
    var paper = ReadingPaperStyle.plain { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Self.paint(pageFrame: pageFrame, paper: paper, in: context)
    }
    static func paint(pageFrame: CGRect, paper: ReadingPaperStyle, unitScale: CGFloat = 1, in context: CGContext) {
        guard !pageFrame.isEmpty else { return }
        let width = min(38 * unitScale, pageFrame.width * 0.045)
        let spine = CGRect(x: pageFrame.minX, y: pageFrame.minY, width: width, height: pageFrame.height)
        context.saveGState(); context.clip(to: spine)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.black.withAlphaComponent(0.13).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: spine.minX, y: spine.midY),
                end: CGPoint(x: spine.maxX, y: spine.midY), options: [])
        }
        context.restoreGState()
        for index in 0..<4 {
            let x = pageFrame.maxX + CGFloat(index) * 1.7 * unitScale
            let rect = CGRect(x: x, y: pageFrame.minY + CGFloat(index) * 1.3 * unitScale, width: 1.6 * unitScale, height: max(0, pageFrame.height - CGFloat(index) * 2.6 * unitScale))
            if let color = paper.color.blended(withFraction: CGFloat(index + 1) * 0.04, of: .gray) {
                context.setFillColor(color.cgColor); context.fill(rect)
            }
        }
    }
}
