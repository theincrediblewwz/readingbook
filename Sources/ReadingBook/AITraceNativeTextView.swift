import AppKit
import SwiftUI

/// A fixed viewport keeps long diagnostics out of SwiftUI's ideal-size text
/// measurement. TextKit lays out the visible region and supports native copy.
struct AITraceNativeTextView: NSViewRepresentable {
    let text: String
    final class Coordinator { var displayed: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.importsGraphics = false; view.drawsBackground = false; view.allowsUndo = false
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]; view.textContainerInset = NSSize(width: 12, height: 12)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.font = .systemFont(ofSize: 13); view.textColor = .labelColor
        view.setAccessibilityLabel("收发文字")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.displayed != text, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.displayed = text
        view.string = text
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
