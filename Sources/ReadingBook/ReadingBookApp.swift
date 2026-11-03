import SwiftUI
import AppKit

struct ReadingBookApp: App {
    @NSApplicationDelegateAdaptor(ReadingBookApplicationDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var typography = ReadingTypographySettings()
    var body: some Scene {
        Window("ReadingBook", id: "main") {
            WorkspaceView().environmentObject(store).environmentObject(typography).modifier(ReadingPreferencesEnvironment())
                .background(FrostWindowAppearance())
                .frame(minWidth: 800, minHeight: 600)
                .task { await store.load() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1480, height: 940)
        .commands {
            ReaderKeyboardCommands()
            CommandGroup(before: .windowArrangement) {
                Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
            }
        }
        Settings { AppSettingsView().environmentObject(store).environmentObject(typography).modifier(ReadingPreferencesEnvironment()).frame(minWidth: 760, idealWidth: 960, minHeight: 600, idealHeight: 720) }
    }
}

/// Leave About/settings/quit, native editing (including IME and undo), and
/// window controls. Feature navigation lives in the workspace's own menus.
@MainActor enum ReadingMenuPolicy {
    static func apply(to menu: NSMenu) {
        for (index, item) in menu.items.enumerated().reversed() {
            guard index != 0 else { continue }
            let actions = Set((item.submenu?.items ?? []).compactMap { $0.action.map(NSStringFromSelector) })
            let editing = !actions.isDisjoint(with: ["cut:", "copy:", "paste:", "undo:"])
            let windows = !actions.isDisjoint(with: ["performMiniaturize:", "miniaturize:", "arrangeInFront:", "toggleFullScreen:"])
            let localizedFallback = ["Edit", "编辑", "Window", "窗口"].contains(item.title)
            if !editing && !windows && !localizedFallback { menu.removeItem(item) }
        }
    }
}
@MainActor final class ReadingBookApplicationDelegate: NSObject, NSApplicationDelegate {
    private var menuObserver: NSObjectProtocol?
    private var scheduled = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard note.object as? NSMenu === NSApp.mainMenu else { return }
                self?.scheduleMenuUpdate()
            }
        }
        scheduleMenuUpdate()
    }
    func applicationDidBecomeActive(_ notification: Notification) { scheduleMenuUpdate() }
    private func scheduleMenuUpdate() {
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            if let menu = NSApp.mainMenu { ReadingMenuPolicy.apply(to: menu) }
        }
    }
}

enum Palette {
    static let ink = adaptive(0x26313C, dark: 0xE6EDF9)
    static let accent = adaptive(0x3569D5, dark: 0x8BAEFF)
    static let copper = adaptive(0x9C6827, dark: 0xE0B778)
    static let paper = adaptive(0xFFFFFF, dark: 0x171D28)
    static let surface = adaptive(0xF9FBFF, dark: 0x202A3B)
    static let line = adaptive(0xDCE4F1, dark: 0x36445C)
    static let canvas = adaptive(0xF5F8FF, dark: 0x151D2A)
    private static func adaptive(_ light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct SoftPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).background(Palette.paper, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line.opacity(0.8), lineWidth: 0.75))
    }
}
extension View {
    func softPanel() -> some View { modifier(SoftPanel()) }
}
