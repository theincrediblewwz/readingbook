import SwiftUI
import AppKit

@MainActor enum AppDataLocations {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReadingBook", isDirectory: true)
    }
    static var rootURL: URL {
        guard let path = UserDefaults.standard.string(forKey: "library.root.path.v1"), path.hasPrefix("/") else { return defaultRoot }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    static var isCustomRoot: Bool { UserDefaults.standard.string(forKey: "library.root.path.v1") != nil }
    static var configuredRootAvailable: Bool {
        guard isCustomRoot else { return true }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &directory) && directory.boolValue
    }
    static func selectRoot(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: "library.root.path.v1")
    }
}

private struct ReadingReducedMotionKey: EnvironmentKey { static let defaultValue = false }
private struct ReadingReducedTransparencyKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var readingReduceMotion: Bool {
        get { self[ReadingReducedMotionKey.self] }
        set { self[ReadingReducedMotionKey.self] = newValue }
    }
    var readingReduceTransparency: Bool {
        get { self[ReadingReducedTransparencyKey.self] }
        set { self[ReadingReducedTransparencyKey.self] = newValue }
    }
}
struct ReadingPreferencesEnvironment: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemMotion
    @Environment(\.accessibilityReduceTransparency) private var systemTransparency
    @AppStorage("appearance.reduceMotion") private var motion = false
    @AppStorage("appearance.reduceTransparency") private var transparency = false
    @AppStorage("appearance.colorScheme") private var appearance = "system"
    func body(content: Content) -> some View {
        content.environment(\.readingReduceMotion, systemMotion || motion)
            .environment(\.readingReduceTransparency, systemTransparency || transparency)
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
    }
}
