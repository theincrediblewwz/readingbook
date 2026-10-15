import Foundation

public enum NavigationOrbDock: String, Sendable { case topLeading, bottomLeading }

/// UI preference only; it never changes a book, source position, or graph layout.
public enum NavigationOrbGeometry {
    public static func center(in viewport: CGSize, dock: NavigationOrbDock) -> CGPoint {
        let x = min(max(0, viewport.width / 2), 42)
        let top = min(max(0, viewport.height / 2), 124)
        let bottom = max(top, viewport.height - 48)
        return CGPoint(x: x, y: dock == .topLeading ? top : bottom)
    }
    public static func clamped(_ point: CGPoint, in viewport: CGSize) -> CGPoint {
        let inset: CGFloat = 26
        return CGPoint(x: min(max(inset, point.x), max(inset, viewport.width - inset)),
                       y: min(max(inset, point.y), max(inset, viewport.height - inset)))
    }
    public static func nearest(to point: CGPoint, in viewport: CGSize) -> NavigationOrbDock {
        let top = center(in: viewport, dock: .topLeading), bottom = center(in: viewport, dock: .bottomLeading)
        return abs(point.y - top.y) <= abs(point.y - bottom.y) ? .topLeading : .bottomLeading
    }
}
