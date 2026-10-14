import SwiftUI
import AppKit

struct ReadingBookApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            WorkspaceView().environmentObject(store)
                .frame(minWidth: 800, minHeight: 600)
                .task { await store.load() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1480, height: 940)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入书籍…") { store.chooseBook() }.keyboardShortcut("o")
                Button("写下理解") { store.newDocument() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("保存文档") { Task { await store.saveCurrentDocument() } }.keyboardShortcut("s")
            }
            CommandMenu("阅读") {
                Button("预读并制定计划") { store.makePlan() }.disabled(store.book == nil || store.isBusy)
                Button("开始 / 继续精读") { store.startReading() }.disabled(store.book == nil || store.isBusy)
                Button("暂停任务") { store.pause() }.keyboardShortcut(".").disabled(!store.isBusy)
            }
            CommandMenu("工作台") {
                Button("原文阅读") { store.route = "reader" }.keyboardShortcut("1")
                Button("阅读流程") { store.route = "workflow" }.keyboardShortcut("2")
                Button("与书对话") { store.route = "query" }.keyboardShortcut("3")
                Button("我的理解") { store.route = "editor" }.keyboardShortcut("4")
            }
        }
        Settings { ProviderSettingsView().environmentObject(store).frame(width: 640, height: 660) }
    }
}

enum Palette {
    static let ink = adaptive(0x273831, dark: 0xE1E9E2)
    static let accent = adaptive(0x315D4D, dark: 0xA1CAB4)
    static let copper = adaptive(0x9D6037, dark: 0xD4A57A)
    static let paper = adaptive(0xFAFAF7, dark: 0x19211E)
    static let surface = adaptive(0xFFFFFF, dark: 0x232D28)
    static let line = adaptive(0xE0E7E1, dark: 0x3A4941)
    static let canvas = adaptive(0xF4F6F2, dark: 0x1C2520)
    private static func adaptive(_ light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct SoftPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line.opacity(0.8), lineWidth: 0.75))
    }
}
extension View {
    func softPanel() -> some View { modifier(SoftPanel()) }
    @ViewBuilder func readingGlass() -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16)) }
        else { self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
    }
}
