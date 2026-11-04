import AppKit
import Foundation
@testable import ReadingBook

@MainActor private final class Runner: NSObject, NSApplicationDelegate {
    let policyDelegate = ReadingBookApplicationDelegate()
    var checks: [String: Bool] = [:]
    var output: URL!
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try finish(nil) } catch { try? finish(error.localizedDescription) }
            NSApp.terminate(nil)
        }
    }
    func item(_ title: String, _ actions: [String] = []) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for action in actions { submenu.addItem(NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "")) }
        value.submenu = submenu; return value
    }
    func check(_ name: String, _ passed: Bool) throws { checks[name] = passed; guard passed else { throw NSError(domain: name, code: 1) } }
    func drain() async throws { try await Task.sleep(for: .milliseconds(40)) }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/ai-history-preparation-20261104/"), Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw NSError(domain: "isolation", code: 1) }
        let menu = NSMenu(title: "main"), app = item("ReadingBook"), edit = item("Edit", ["undo:", "copy:", "paste:"]), window = item("Window", ["performMiniaturize:"])
        [app, edit, window].forEach { menu.addItem($0) }; NSApp.mainMenu = menu
        policyDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try await drain()
        try check("applicationVisible", !app.isHidden && menu.items.first === app)
        try check("editingVisible", !edit.isHidden && edit.submenu?.items.contains { $0.action == NSSelectorFromString("undo:") } == true)
        try check("windowVisible", !window.isHidden)
        let file = item("File"), view = item("View"), help = item("Help")
        menu.addItem(file); try check("fileHiddenSynchronously", file.isHidden)
        menu.addItem(view); try check("viewHiddenSynchronously", view.isHidden)
        menu.addItem(help); try check("helpHiddenSynchronously", help.isHidden)
        try check("structuralRemovalDeferred", menu.items.contains { $0 === file } && menu.items.contains { $0 === view })
        try await drain()
        try check("unwantedRemovedAfterRebuild", !menu.items.contains { ["File", "View", "Help"].contains($0.title) })
        let localizedEdit = item("编辑"), localizedWindow = item("窗口")
        menu.addItem(localizedEdit); menu.addItem(localizedWindow)
        try check("localizedMenusVisible", !localizedEdit.isHidden && !localizedWindow.isHidden)
        let nativeEdit = item("Native input", ["cut:"]), nativeWindow = item("Native window", ["toggleFullScreen:"])
        menu.addItem(nativeEdit); menu.addItem(nativeWindow)
        try check("nativeActionsVisible", !nativeEdit.isHidden && !nativeWindow.isHidden)
        let incomplete = item(""); menu.addItem(incomplete)
        try check("incompleteHiddenUntilClassified", incomplete.isHidden)
        incomplete.submenu?.addItem(NSMenuItem(title: "copy", action: NSSelectorFromString("copy:"), keyEquivalent: ""))
        try await drain()
        try check("lateNativeActionsRestoreVisibility", menu.items.contains { $0 === incomplete } && !incomplete.isHidden)
        let explicitlyHidden = item("Edit"); explicitlyHidden.isHidden = true; menu.addItem(explicitlyHidden); try await drain()
        try check("frameworkHiddenStatePreserved", explicitlyHidden.isHidden)
        menu.addItem(file); try check("sameItemReinsertedHidden", file.isHidden); try await drain()
        var allHidden = true
        for index in 0..<60 { let value = item(index.isMultiple(of: 2) ? "View" : "Help"); menu.addItem(value); allHidden = allHidden && value.isHidden }
        try check("repeatedRebuildHiddenImmediately", allHidden); try await drain()
        try check("repeatedRebuildLeavesOnlyRetained", menu.items.allSatisfy { $0 === app || $0 === edit || $0 === window || $0 === localizedEdit || $0 === localizedWindow || $0 === nativeEdit || $0 === nativeWindow || $0 === incomplete || $0 === explicitlyHidden })
        let unrelated = NSMenu(title: "not-main"), unrelatedFile = item("File"); unrelated.addItem(unrelatedFile)
        try check("unrelatedMenuNotFiltered", !unrelatedFile.isHidden)
        edit.submenu?.addItem(NSMenuItem(title: "paste", action: NSSelectorFromString("paste:"), keyEquivalent: "")); try await drain()
        try check("editingSubmenuPreserved", edit.submenu?.items.contains { $0.action == NSSelectorFromString("paste:") } == true && !edit.isHidden)
        weak var releasedItem: NSMenuItem?
        autoreleasepool { let temporary = NSMenu(title: "temporary"); temporary.addItem(item("Application")); let hidden = item("Help"); temporary.addItem(hidden); releasedItem = hidden; ReadingMenuPolicy.prepareForDisplay(temporary) }
        try await drain(); try check("hiddenTrackingDoesNotRetainItems", releasedItem == nil)
        menu.addItem(item("File"))
        let replacement = NSMenu(title: "replacement"), replacementApp = item("ReadingBook"), replacementEdit = item("Edit")
        replacement.addItem(replacementApp); replacement.addItem(replacementEdit); NSApp.mainMenu = replacement; try await drain()
        try check("queuedCleanupUsesCurrentMainMenu", NSApp.mainMenu === replacement && replacement.items.first === replacementApp && !replacementEdit.isHidden)
    }
    func finish(_ error: String?) throws {
        let result: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error as Any? ?? NSNull(), "checks": checks, "realNetworkRequests": 0, "originalLibraryUsed": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
}
@main struct Main { static func main() { let app = NSApplication.shared; let runner = Runner(); app.delegate = runner; app.setActivationPolicy(.regular); app.run(); _ = runner } }
