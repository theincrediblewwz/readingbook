import Foundation

public struct ReadingUnderlineSegment: Equatable, Sendable {
    public let start: CGPoint
    public let end: CGPoint
}

/// Operates after PDF-page points have been converted into display points.
/// The normal points away from the text, so flips, page rotations and zoom do
/// not move the line into the selection or magnify its clearance.
public enum ReadingUnderlineGeometry {
    public static func outside(edgeStart: CGPoint, edgeEnd: CGPoint, contentCenter: CGPoint,
                               gap: Double = 1.5, lineWidth: Double = 1) -> ReadingUnderlineSegment? {
        guard [Double(edgeStart.x), Double(edgeStart.y), Double(edgeEnd.x), Double(edgeEnd.y), Double(contentCenter.x), Double(contentCenter.y), gap, lineWidth].allSatisfy(\.isFinite),
              gap >= 0, lineWidth > 0 else { return nil }
        let dx = edgeEnd.x - edgeStart.x, dy = edgeEnd.y - edgeStart.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 0.001 else { return nil }
        var nx = -dy / length, ny = dx / length
        let midpoint = CGPoint(x: (edgeStart.x + edgeEnd.x) / 2, y: (edgeStart.y + edgeEnd.y) / 2)
        let inward = nx * (contentCenter.x - midpoint.x) + ny * (contentCenter.y - midpoint.y)
        guard inward.isFinite, abs(inward) > 0.001 else { return nil }
        if inward > 0 { nx = -nx; ny = -ny }
        let distance = CGFloat(gap + lineWidth / 2)
        let start = CGPoint(x: edgeStart.x + nx * distance, y: edgeStart.y + ny * distance)
        let end = CGPoint(x: edgeEnd.x + nx * distance, y: edgeEnd.y + ny * distance)
        guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite) else { return nil }
        return ReadingUnderlineSegment(start: start, end: end)
    }
}
