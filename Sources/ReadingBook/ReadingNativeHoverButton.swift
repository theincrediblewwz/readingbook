import AppKit

/// NSButtonCell's leading image layout spreads image and title across a wide
/// bezel. Draw a single centered label with the same four-point gap as SwiftUI.
@MainActor final class ReadingCompactAIButtonCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let title = NSAttributedString(string: "AI", attributes: [.font: font,
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor])
        let size = title.size(), width = 14 + 4 + size.width
        let x = cellFrame.midX - width / 2
        image?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))?.draw(
            in: NSRect(x: x, y: cellFrame.midY - 7, width: 14, height: 14), from: .zero,
            operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
        title.draw(in: NSRect(x: x + 18, y: cellFrame.midY - size.height / 2, width: size.width, height: size.height))
    }
}

/// Borderless AppKit controls need the same visible target as SwiftUI buttons.
/// Tracking follows the current window pointer, including a newly revealed bar.
@MainActor final class ReadingNativeHoverButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var readingHovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        updateHover()
    }
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { readingHovered = false; needsDisplay = true }
    private func updateHover() {
        let next = window.map { $0.isKeyWindow && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        if readingHovered != next { readingHovered = next; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        if !isBordered, isEnabled, readingHovered || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.17 : 0.085).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
        }
        super.draw(dirtyRect)
    }
}
