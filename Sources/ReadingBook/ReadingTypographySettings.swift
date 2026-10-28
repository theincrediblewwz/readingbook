import AppKit
import SwiftUI
import ReadingCore

@MainActor final class ReadingTypographySettings: ObservableObject {
    private static let key = "reading.typography.v1"
    @Published private var preferences: ReadingTypographyPreferences
    private let defaults: UserDefaults
    let availableFontFamilies: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.key)
        let legacy = (defaults.object(forKey: "reading.companionTextScale") as? NSNumber)?.doubleValue
        preferences = ReadingTypographyPreferences.restored(from: data, legacyCompanionScale: legacy)
        availableFontFamilies = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // Save the migration marker immediately, including when the old scale was 1.
        if data == nil, let encoded = try? JSONEncoder().encode(preferences) { defaults.set(encoded, forKey: Self.key) }
    }

    func style(for context: ReadingTextContext) -> ReadingTextStyle { preferences.style(for: context) }
    func setFamily(_ family: String, for context: ReadingTextContext) {
        var style = style(for: context); style.family = family; update(style, for: context)
    }
    func setPointSize(_ size: Double, for context: ReadingTextContext) {
        var style = style(for: context); style.pointSize = size; update(style, for: context)
    }
    func reset(_ context: ReadingTextContext) {
        var next = preferences; next.reset(context); save(next)
    }
    func resetAll() { var next = preferences; next.resetAll(); save(next) }

    func font(for context: ReadingTextContext, weight: Font.Weight = .regular) -> Font {
        let style = style(for: context)
        if style.family == "system" || style.family == "sans" { return .system(size: style.pointSize, weight: weight) }
        if style.family == "monospaced" { return .system(size: style.pointSize, weight: weight, design: .monospaced) }
        return .custom(nsFont(for: context).fontName, size: style.pointSize).weight(weight)
    }

    func nsFont(for context: ReadingTextContext) -> NSFont {
        let style = style(for: context), size = CGFloat(style.pointSize)
        switch style.family {
        case "system", "sans": return NSFont.systemFont(ofSize: size)
        case "monospaced": return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "serif": return NSFont(name: "Songti SC", size: size) ?? NSFont(name: "STSong", size: size) ?? NSFont.systemFont(ofSize: size)
        default: return NSFontManager.shared.font(withFamily: style.family, traits: [], weight: 5, size: size) ?? NSFont.systemFont(ofSize: size)
        }
    }

    func cssFamily(for context: ReadingTextContext) -> String {
        switch style(for: context).family {
        case "system", "sans": return "-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif"
        case "serif": return "'Songti SC', 'STSong', 'Noto Serif CJK SC', serif"
        case "monospaced": return "ui-monospace, 'SFMono-Regular', 'Menlo', monospace"
        default:
            let family = style(for: context).family
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "'\(family)', -apple-system, 'PingFang SC', sans-serif"
        }
    }

    private func update(_ style: ReadingTextStyle, for context: ReadingTextContext) {
        var next = preferences; next.set(style, for: context); save(next)
    }
    private func save(_ next: ReadingTypographyPreferences) {
        guard next != preferences, let data = try? JSONEncoder().encode(next) else { return }
        preferences = next; defaults.set(data, forKey: Self.key)
    }
}

private struct ReadingTextContextKey: EnvironmentKey {
    static let defaultValue: ReadingTextContext = .knowledge
}
extension EnvironmentValues {
    var readingTextContext: ReadingTextContext {
        get { self[ReadingTextContextKey.self] }
        set { self[ReadingTextContextKey.self] = newValue }
    }
}
extension View {
    func readingTextContext(_ context: ReadingTextContext) -> some View { environment(\.readingTextContext, context) }
}
