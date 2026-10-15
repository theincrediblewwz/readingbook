import AppKit
import SwiftUI

/// Keep real traffic-light controls, with content underneath a transparent titlebar.
struct FrostWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowProbe { WindowProbe() }
    func updateNSView(_ view: WindowProbe, context: Context) { view.configureWindow() }
    final class WindowProbe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureWindow() }
        func configureWindow() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .windowBackgroundColor
            window.toolbar = nil
            window.isMovableByWindowBackground = false
        }
    }
}
