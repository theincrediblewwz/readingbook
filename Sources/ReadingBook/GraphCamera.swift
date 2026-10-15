import SwiftUI

/// The viewport is a camera over existing world coordinates; moving it never
/// rewrites the user's graph. A very small minimum supports fitting old, widely
/// separated nodes without creating an enormous backing view.
struct GraphCamera {
    static let minimumScale: CGFloat = 0.00001
    static let maximumScale: CGFloat = 4
    var center = CGPoint.zero
    var scale: CGFloat = 1

    func screen(_ point: CGPoint, in viewport: CGSize) -> CGPoint {
        CGPoint(x: (point.x - center.x) * scale + viewport.width / 2,
                y: (point.y - center.y) * scale + viewport.height / 2)
    }
    func world(_ point: CGPoint, in viewport: CGSize) -> CGPoint {
        CGPoint(x: (point.x - viewport.width / 2) / scale + center.x,
                y: (point.y - viewport.height / 2) / scale + center.y)
    }
    mutating func pan(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        center.x -= delta.width / scale; center.y -= delta.height / scale
    }
    mutating func zoom(by factor: CGFloat, at anchor: CGPoint, in viewport: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let fixed = world(anchor, in: viewport)
        scale = min(Self.maximumScale, max(Self.minimumScale, scale * factor))
        center = CGPoint(x: fixed.x - (anchor.x - viewport.width / 2) / scale,
                         y: fixed.y - (anchor.y - viewport.height / 2) / scale)
    }
    mutating func focus(_ point: CGPoint, in viewport: CGSize, obscuredLeadingWidth: CGFloat) {
        let obstruction = min(max(0, obscuredLeadingWidth), max(0, viewport.width - 80))
        center = CGPoint(x: point.x - obstruction / (2 * scale), y: point.y)
    }
    mutating func fit(_ bounds: CGRect, in viewport: CGSize, obscuredLeadingWidth: CGFloat) {
        guard viewport.width > 0, viewport.height > 0, !bounds.isNull else { return }
        let obstruction = min(max(0, obscuredLeadingWidth), max(0, viewport.width - 80))
        let available = CGSize(width: max(80, viewport.width - obstruction - 80), height: max(80, viewport.height - 120))
        scale = min(1, max(Self.minimumScale, min(available.width / max(1, bounds.width), available.height / max(1, bounds.height))))
        focus(CGPoint(x: bounds.midX, y: bounds.midY), in: viewport, obscuredLeadingWidth: obstruction)
    }
}
