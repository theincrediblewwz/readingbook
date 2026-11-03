import Foundation
#if os(macOS)
import AppKit
#endif

/// Independent from underline appearance; optional on legacy highlighters.
public struct ReaderHighlightAppearance: Codable, Hashable, Sendable {
    public var red: Double = 0.96
    public var green: Double = 0.79
    public var blue: Double = 0.21
    public var opacity: Double = 0.32
    public var saturation: Double = 1
    public var brightness: Double = 1
    public init() { }
    public var isValid: Bool {
        [red, green, blue, opacity, saturation, brightness].allSatisfy(\.isFinite)
            && [red, green, blue].allSatisfy { (0...1).contains($0) }
            && (0.05...0.8).contains(opacity) && (0...2).contains(saturation) && (0.5...1.5).contains(brightness)
    }
    #if os(macOS)
    public var nativeColor: NSColor {
        let rgb = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(calibratedHue: h, saturation: min(1, max(0, s * saturation)), brightness: min(1, max(0, b * brightness)), alpha: opacity)
    }
    #endif
}
