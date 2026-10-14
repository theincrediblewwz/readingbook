import SwiftUI
import AppKit

@main
struct ReadingBookApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            WorkspaceView().environmentObject(store)
                .frame(minWidth: 800, minHeight: 600)
                .task { await store.load() }
        }
        .windowStyle(.hiddenTitleBar)
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
        }
        Settings { ProviderSettingsView().environmentObject(store).frame(width: 660, height: 760) }
    }
}

enum Palette {
    static let ink = Color(red: 0.19, green: 0.23, blue: 0.23)
    static let accent = Color(red: 0.25, green: 0.42, blue: 0.37)
    static let copper = Color(red: 0.69, green: 0.40, blue: 0.25)
    static let paper = Color(nsColor: .textBackgroundColor)
}

struct SoftPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
}
extension View {
    func softPanel() -> some View { modifier(SoftPanel()) }
    @ViewBuilder func readingGlass() -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16)) }
        else { self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
    }
}
