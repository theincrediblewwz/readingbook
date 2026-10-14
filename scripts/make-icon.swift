import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Pass an iconset directory") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot allocate icon") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current?.imageInterpolation = .high
    let rect = NSRect(x: 42 * scale, y: 42 * scale, width: 940 * scale, height: 940 * scale)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 210 * scale, yRadius: 210 * scale)
    NSColor(calibratedRed: 0.20, green: 0.34, blue: 0.30, alpha: 1).setFill(); shape.fill()
    let book = NSBezierPath(roundedRect: NSRect(x: 240 * scale, y: 220 * scale, width: 540 * scale, height: 595 * scale), xRadius: 36 * scale, yRadius: 36 * scale)
    NSColor(calibratedRed: 0.95, green: 0.92, blue: 0.84, alpha: 1).setFill(); book.fill()
    let spine = NSBezierPath(); spine.move(to: NSPoint(x: 325 * scale, y: 220 * scale)); spine.line(to: NSPoint(x: 325 * scale, y: 815 * scale)); spine.lineWidth = 5 * scale
    NSColor(calibratedRed: 0.20, green: 0.34, blue: 0.30, alpha: 0.4).setStroke(); spine.stroke()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 270 * scale, weight: .light), .foregroundColor: NSColor(calibratedRed: 0.20, green: 0.34, blue: 0.30, alpha: 1)]
    NSAttributedString(string: "阅", attributes: attrs).draw(at: NSPoint(x: 390 * scale, y: 380 * scale))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
}
