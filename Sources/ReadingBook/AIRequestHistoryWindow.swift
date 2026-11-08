import AppKit
import SwiftUI

/// Modeless diagnostics: never changes the reader/companion panel's saved
/// frame, blocks its editor, or suspends an AI task when this window closes.
@MainActor final class AIRequestHistoryWindow: NSObject, NSWindowDelegate {
    private weak var store: AppStore?
    private var panel: NSWindow?
    private var state: AIProgressObservableState?

    init(store: AppStore) { self.store = store }

    func show(_ state: AIProgressObservableState) {
        guard let store else { return }
        if let panel, self.state === state { panel.makeKeyAndOrderFront(nil); return }
        let owner = NSApp.keyWindow
        let panel = self.panel ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let first = self.panel == nil
        self.panel = panel; self.state = state
        panel.title = "请求记录与详情"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.minSize = NSSize(width: 680, height: 440)
        panel.backgroundColor = .clear; panel.isOpaque = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.contentView = NSHostingView(rootView: AIRequestHistoryView(state: state, onClose: { [weak self] in self?.close() })
            .environmentObject(store))
        if first {
            if let screen = owner?.screen ?? NSScreen.main {
                let space = screen.visibleFrame
                let size = NSSize(width: min(900, space.width - 48), height: min(700, space.height - 64))
                panel.setFrame(NSRect(x: space.midX - size.width / 2, y: space.midY - size.height / 2, width: size.width, height: size.height), display: false)
            } else { panel.center() }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        panel?.contentView = nil; panel = nil; state = nil
        if store?.requestHistoryWindow === self { store?.requestHistoryWindow = nil }
    }
}

@MainActor extension AppStore {
    func showAIRequestHistory(_ state: AIProgressObservableState) {
        if requestHistoryWindow == nil { requestHistoryWindow = AIRequestHistoryWindow(store: self) }
        requestHistoryWindow?.show(state)
    }
}
