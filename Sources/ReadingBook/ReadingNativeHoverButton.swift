import AppKit

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
