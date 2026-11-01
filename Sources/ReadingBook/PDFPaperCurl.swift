import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import PDFKit

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
    private let extent: CGRect
    private let backwards: Bool
    private var began: CFTimeInterval?
    private var finished = false
    var completion: (() -> Void)?
    private(set) var renderedFrames = 0
    private(set) var progressSamples: [Double] = []
    static var supported: Bool { renderer != nil }

    init?(frame: CGRect, from: PDFPage, fromFrame: CGRect, to: PDFPage, toFrame: CGRect, backwards: Bool, paper: ReadingPaperStyle, background: NSColor, scale: CGFloat) {
        guard frame.width > 10, frame.height > 10, let (device, queue, context) = Self.renderer else { return nil }
        let pixelScale = min(max(1, scale), 4096 / max(frame.width, frame.height), sqrt(4_000_000 / (frame.width * frame.height)))
        let pixels = CGSize(width: max(2, floor(frame.width * pixelScale)), height: max(2, floor(frame.height * pixelScale)))
        let rect = CGRect(origin: .zero, size: pixels)
        func image(_ page: PDFPage, in pageFrame: CGRect) -> CIImage? {
            let pagePixels = CGSize(width: max(2, pageFrame.width * pixelScale), height: max(2, pageFrame.height * pixelScale))
            let native = page.thumbnail(of: pagePixels, for: .cropBox)
            guard let cg = native.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let canvas = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            canvas.setFillColor(background.cgColor); canvas.fill(rect)
            let location = CGRect(x: (pageFrame.minX - frame.minX) * pixelScale, y: (pageFrame.minY - frame.minY) * pixelScale,
                                  width: pageFrame.width * pixelScale, height: pageFrame.height * pixelScale)
            canvas.draw(cg, in: location)
            guard let rendered = canvas.makeImage() else { return nil }
            var result = CIImage(cgImage: rendered)
            if let texture = ReadingPaperAssets.image(paper)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let material = CIImage(cgImage: texture)
                let sheet = material.transformed(by: .init(scaleX: location.width / material.extent.width, y: location.height / material.extent.height))
                    .transformed(by: .init(translationX: location.minX, y: location.minY)).cropped(to: location)
                let background = sheet.composited(over: CIImage(color: .white).cropped(to: rect))
                result = result.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: background])
            }
            return result
        }
        guard let old = image(from, in: fromFrame), let next = image(to, in: toFrame) else { return nil }
        self.queue = queue; imageContext = context; extent = rect; self.backwards = backwards
        super.init(frame: frame, device: device)
        framebufferOnly = false; colorPixelFormat = .bgra8Unorm
        autoResizeDrawable = false; drawableSize = pixels
        preferredFramesPerSecond = 60; enableSetNeedsDisplay = false; isPaused = false
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        curl.inputImage = backwards ? next : old; curl.targetImage = backwards ? old : next
        curl.backsideImage = CIImage(color: CIColor(color: paper.color) ?? .white).cropped(to: rect)
        curl.extent = rect; curl.shadowExtent = rect
        curl.radius = Float(pixels.width * 0.13); curl.angle = .pi - .pi / 10
        curl.shadowAmount = 0.42; curl.shadowSize = 0.13
        delegate = self
        setAccessibilityElement(false)
    }
    required init(coder: NSCoder) { fatalError("Paper curl views are created programmatically") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    func draw(in view: MTKView) {
        guard !finished, let drawable = currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        if began == nil { began = now }
        let t = min(1, (now - (began ?? now)) / 0.60)
        let eased = t * t * (3 - 2 * t)
        curl.time = Float(backwards ? 1 - eased : eased)
        guard let output = curl.outputImage?.cropped(to: extent) else { finish(); return }
        imageContext.render(output, to: drawable.texture, commandBuffer: buffer, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        buffer.present(drawable); buffer.commit()
        renderedFrames += 1
        if progressSamples.count < 90 { progressSamples.append(t) }
        if t >= 1 { finish() }
    }
    func cancel() { finished = true; isPaused = true; delegate = nil; completion = nil; removeFromSuperview() }
    private func finish() {
        guard !finished else { return }; finished = true; isPaused = true
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
        guard !pageFrame.isEmpty else { return }
        let width = min(38, pageFrame.width * 0.045)
        NSGradient(starting: NSColor.black.withAlphaComponent(0.13), ending: .clear)?
            .draw(in: CGRect(x: pageFrame.minX, y: pageFrame.minY, width: width, height: pageFrame.height), angle: 0)
        for index in 0..<4 {
            let x = pageFrame.maxX + CGFloat(index) * 1.7
            let rect = CGRect(x: x, y: pageFrame.minY + CGFloat(index) * 1.3, width: 1.6, height: max(0, pageFrame.height - CGFloat(index) * 2.6))
            paper.color.blended(withFraction: CGFloat(index + 1) * 0.04, of: .gray)?.setFill(); rect.fill()
        }
    }
}
