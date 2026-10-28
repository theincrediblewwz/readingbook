import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Pass an iconset directory") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
struct SymbolCatalog: Decodable { let glyphs: [String: [[Double]]] }
let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/ReadingBook/Resources/Brand/symbols.json")
let catalog = try JSONDecoder().decode(SymbolCatalog.self, from: Data(contentsOf: source))
func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func glyph(_ name: String, origin: CGPoint, scale: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + CGFloat(x) * scale, y: origin.y + (24 - CGFloat(y)) * scale) }
    for c in catalog.glyphs[name] ?? [] {
        switch Int(c[0]) {
        case 0: path.move(to: point(c[1], c[2]))
        case 1: path.line(to: point(c[1], c[2]))
        case 2: path.curve(to: point(c[5], c[6]), controlPoint1: point(c[1], c[2]), controlPoint2: point(c[3], c[4]))
        case 3: path.close()
        case 4: path.appendOval(in: CGRect(x: origin.x + CGFloat(c[1]) * scale, y: origin.y + (24 - CGFloat(c[2]) - CGFloat(c[4])) * scale, width: CGFloat(c[3]) * scale, height: CGFloat(c[4]) * scale))
        default: break
        }
    }
    path.lineWidth = 1.2 * scale; path.lineCapStyle = .round; path.lineJoinStyle = .round
    return path
}
let sizes = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]
for (name, size) in sizes {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot allocate icon") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    let s = CGFloat(size) / 1024
    let plate = NSBezierPath(roundedRect: CGRect(x: 64*s, y: 64*s, width: 896*s, height: 896*s), xRadius: 205*s, yRadius: 205*s)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 24*s; shadow.shadowOffset = NSSize(width: 0, height: -8*s)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); color(0x3569D5).setFill(); plate.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x245BC7), ending: color(0x638AF1))?.draw(in: plate, angle: 90)
    color(0xFFFFFF).withAlphaComponent(0.14).setStroke(); plate.lineWidth = max(0.5, 2*s); plate.stroke()
    let origin = CGPoint(x: 152*s, y: 152*s), scale = 30*s
    color(0xFFFFFF).setFill(); glyph("plateLeft", origin: origin, scale: scale).fill()
    color(0xE9F0FF).setFill(); glyph("plateRight", origin: origin, scale: scale).fill()
    let crease = NSBezierPath(); crease.move(to: CGPoint(x: 512*s,y: 242*s)); crease.line(to: CGPoint(x: 512*s,y: 677*s))
    color(0x3569D5).withAlphaComponent(0.32).setStroke(); crease.lineWidth = 4*s; crease.stroke()
    color(0xBFD3FF).setFill(); glyph("markAccent", origin: origin, scale: scale).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
}
