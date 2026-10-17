import Foundation

public enum NavigationOrbDock: String, Sendable { case topLeading, bottomLeading }

/// UI preference only; it never changes a book, source position, or graph layout.
public enum NavigationOrbGeometry {
    /// Reserved by the workspace shell. Every page and canvas receives its
    /// actual viewport after this channel, so navigation never covers content.
    public static let leadingInset: CGFloat = 64
    public static let buttonDiameter: CGFloat = 48

    public static func center(in viewport: CGSize, dock: NavigationOrbDock) -> CGPoint {
        let x = min(max(0, viewport.width / 2), leadingInset / 2)
        let top = min(max(0, viewport.height / 2), 124)
        let bottom = max(top, viewport.height - 48)
        return CGPoint(x: x, y: dock == .topLeading ? top : bottom)
    }
    public static func clamped(_ point: CGPoint, in viewport: CGSize) -> CGPoint {
        // The handle moves vertically inside its own channel, including while
        // the pointer is dragged over a document or a graph node.
        let inset = min(buttonDiameter / 2 + 2, max(0, viewport.height / 2))
        return CGPoint(x: center(in: viewport, dock: .topLeading).x,
                       y: min(max(inset, point.y), max(inset, viewport.height - inset)))
    }
    public static func nearest(to point: CGPoint, in viewport: CGSize) -> NavigationOrbDock {
        let top = center(in: viewport, dock: .topLeading), bottom = center(in: viewport, dock: .bottomLeading)
        return abs(point.y - top.y) <= abs(point.y - bottom.y) ? .topLeading : .bottomLeading
    }
}
