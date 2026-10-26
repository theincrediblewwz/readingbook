import Foundation

/// Local display preferences only. Coordinates have a top-left origin and
/// normalized positions survive resizing without changing any reading data.
public enum FloatingLauncherGeometry {
    public static func clampedCenter(_ center: CGPoint, viewport: CGSize, control: CGSize, margin: CGFloat = 8) -> CGPoint {
        func dimension(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
        let width = dimension(viewport.width), height = dimension(viewport.height)
        let gap = margin.isFinite ? max(0, margin) : 8
        let insetX = min(width / 2, dimension(control.width) / 2 + gap)
        let insetY = min(height / 2, dimension(control.height) / 2 + gap)
        return CGPoint(x: min(max(insetX, center.x.isFinite ? center.x : width / 2), width - insetX),
                       y: min(max(insetY, center.y.isFinite ? center.y : height / 2), height - insetY))
    }

    public static func normalizedPosition(_ center: CGPoint, viewport: CGSize, control: CGSize) -> WorkspacePoint? {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              center.x.isFinite, center.y.isFinite else { return nil }
        let point = clampedCenter(center, viewport: viewport, control: control)
        return WorkspacePoint(x: Double(point.x / viewport.width), y: Double(point.y / viewport.height))
    }

    public static func restoredCenter(_ position: WorkspacePoint?, viewport: CGSize, control: CGSize) -> CGPoint? {
        guard let position, position.isValid, (0...1).contains(position.x), (0...1).contains(position.y),
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else { return nil }
        return clampedCenter(CGPoint(x: CGFloat(position.x) * viewport.width, y: CGFloat(position.y) * viewport.height),
                             viewport: viewport, control: control)
    }
}
