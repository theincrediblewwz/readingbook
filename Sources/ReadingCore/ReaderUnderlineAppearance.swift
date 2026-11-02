import Foundation

/// Optional appearance on a source-anchored mark. Old projects decode without
/// it; changing a style never changes the source quote, range or line boxes.
public struct ReaderUnderlineAppearance: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double
    public var thickness: Double
    public var waveLength: Double
    public var highlighter: Bool
    public var glow: Bool
    public init(red: Double = 0.16, green: Double = 0.42, blue: Double = 0.75, opacity: Double = 0.8,
                thickness: Double = 0.8, waveLength: Double = 6, highlighter: Bool = false, glow: Bool = false) {
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
        self.thickness = thickness; self.waveLength = waveLength; self.highlighter = highlighter; self.glow = glow
    }
    public var isValid: Bool {
        [red, green, blue, opacity, thickness, waveLength].allSatisfy(\.isFinite)
            && (0...1).contains(red) && (0...1).contains(green) && (0...1).contains(blue)
            && (0.15...1).contains(opacity) && (0.35...4).contains(thickness) && (2...18).contains(waveLength)
    }
}
