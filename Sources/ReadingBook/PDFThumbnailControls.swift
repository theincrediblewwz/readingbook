import AppKit
import ReadingCore

@MainActor final class PDFThumbnailDensityButton: NSButton {
    let density: PDFThumbnailDensity
    var selectedDensity = false { didSet { contentTintColor = selectedDensity ? .controlAccentColor : .secondaryLabelColor; setAccessibilityValue(selectedDensity ? "已选中" : "未选中"); needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(_ density: PDFThumbnailDensity, target: AnyObject, action: Selector) {
        self.density = density
        super.init(frame: .zero)
        title = density == .small ? "小" : density == .medium ? "中" : "大"
        self.target = target; self.action = action
        isBordered = false; font = .systemFont(ofSize: 12, weight: .medium)
        setAccessibilityLabel(title + "缩略图"); toolTip = title + "缩略图；拉宽面板会自动增加每行页数。"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if selectedDensity || hovered || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.22 : selectedDensity ? 0.13 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 9, yRadius: 9).fill()
        }
        super.draw(dirtyRect)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}

@MainActor final class PDFThumbnailResizeHandle: NSView {
    var onBegin: (() -> CGFloat)?
    var onResize: ((CGFloat) -> Void)?
    var onFinish: (() -> Void)?
    private var start: (x: CGFloat, width: CGFloat)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) { start = (event.locationInWindow.x, onBegin?() ?? 420) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onResize?(start.width + event.locationInWindow.x - start.x)
    }
    override func mouseUp(with event: NSEvent) { start = nil; onFinish?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 14, width: 2, height: 28), xRadius: 1, yRadius: 1).fill()
    }
}
