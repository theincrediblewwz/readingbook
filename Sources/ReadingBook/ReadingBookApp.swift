import SwiftUI
import AppKit

struct ReadingBookApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("ReadingBook", id: "main") {
            WorkspaceView().environmentObject(store)
                .background(FrostWindowAppearance())
                .frame(minWidth: 800, minHeight: 600)
                .task { await store.load() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1480, height: 940)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入书籍…") { store.chooseBook() }.keyboardShortcut("o")
                Button("新建笔记") { store.newDocument() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("保存文档") { Task { await store.saveCurrentDocument() } }.keyboardShortcut("s")
            }
            CommandMenu("阅读") {
                Button("预读并制定计划") { store.makePlan() }.disabled(store.book == nil || store.isBusy)
                Button("开始 / 继续精读") { store.startReading() }.disabled(store.book == nil || store.isBusy)
                Button("暂停任务") { store.pause() }.keyboardShortcut(".").disabled(!store.isBusy)
            }
            CommandMenu("工作台") {
                Button("原文阅读") { store.requestedWorkspaceRoute = "reader" }.keyboardShortcut("1")
                Button("阅读流程") { store.requestedWorkspaceRoute = "workflow" }.keyboardShortcut("2")
                Button("与书对话") { store.requestedWorkspaceRoute = "query" }.keyboardShortcut("3")
                Button("我的笔记") { store.requestedWorkspaceRoute = "editor" }.keyboardShortcut("4")
            }
        }
        Settings { ProviderSettingsView().environmentObject(store).frame(minWidth: 760, idealWidth: 1060, minHeight: 620, idealHeight: 760) }
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
