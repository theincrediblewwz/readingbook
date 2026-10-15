import Foundation

/// A display preference, independent of a book's knowledge and time filters.
public enum FloatingPanelDock: String, CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomCenter, bottomTrailing
}

/// Shared geometry for a floating panel. All coordinates use a top-left origin.
public enum FloatingPanelGeometry {
    public static func frame(at dock: FloatingPanelDock, viewport: CGSize, panel: CGSize,
                             margin: CGFloat = 16, topControlReserve: CGFloat = 56) -> CGRect {
        let size = fittedSize(panel, viewport: viewport, margin: margin)
        let left = margin, right = max(left, viewport.width - margin - size.width)
        let top = margin, bottom = max(top, viewport.height - margin - size.height)
        let origin: CGPoint
        switch dock {
        case .topLeading: origin = CGPoint(x: left, y: top)
        case .topTrailing:
            // MapKit's compass and zoom controls occupy the upper-right edge.
            origin = CGPoint(x: max(left, viewport.width - margin - topControlReserve - size.width), y: top)
        case .bottomLeading: origin = CGPoint(x: left, y: bottom)
        case .bottomCenter: origin = CGPoint(x: max(left, (viewport.width - size.width) / 2), y: bottom)
        case .bottomTrailing: origin = CGPoint(x: right, y: bottom)
        }
        return CGRect(origin: origin, size: size)
    }

    public static func clampedCenter(_ center: CGPoint, viewport: CGSize, panel: CGSize,
                                     margin: CGFloat = 16) -> CGPoint {
        let size = fittedSize(panel, viewport: viewport, margin: margin)
        return CGPoint(x: min(max(margin + size.width / 2, center.x), max(margin + size.width / 2, viewport.width - margin - size.width / 2)),
                       y: min(max(margin + size.height / 2, center.y), max(margin + size.height / 2, viewport.height - margin - size.height / 2)))
    }

    public static func nearest(to center: CGPoint, viewport: CGSize, panel: CGSize,
                               preferred: FloatingPanelDock = .bottomCenter) -> FloatingPanelDock {
        // Keep the previous dock when narrow windows make several targets equal.
        let candidates = [preferred] + FloatingPanelDock.allCases.filter { $0 != preferred }
        return candidates.min { first, second in
            let a = frame(at: first, viewport: viewport, panel: panel)
            let b = frame(at: second, viewport: viewport, panel: panel)
            return hypot(a.midX - center.x, a.midY - center.y) < hypot(b.midX - center.x, b.midY - center.y)
        } ?? preferred
    }

    /// The largest rectangular area left around the real panel, for map focus.
    public static func unobscuredMapRect(viewport: CGSize, panel: CGRect, gap: CGFloat = 20) -> CGRect {
        let map = CGRect(origin: .zero, size: CGSize(width: max(0, viewport.width), height: max(0, viewport.height)))
        let blocked = panel.insetBy(dx: -gap, dy: -gap).intersection(map)
        guard !blocked.isNull else { return map }
        let candidates = [
            CGRect(x: 0, y: 0, width: map.width, height: max(0, blocked.minY)),
            CGRect(x: 0, y: blocked.maxY, width: map.width, height: max(0, map.height - blocked.maxY)),
            CGRect(x: 0, y: 0, width: max(0, blocked.minX), height: map.height),
            CGRect(x: blocked.maxX, y: 0, width: max(0, map.width - blocked.maxX), height: map.height)
        ]
        return candidates.max { $0.width * $0.height < $1.width * $1.height } ?? map
    }

    private static func fittedSize(_ panel: CGSize, viewport: CGSize, margin: CGFloat) -> CGSize {
        CGSize(width: min(max(0, panel.width), max(0, viewport.width - margin * 2)),
               height: min(max(0, panel.height), max(0, viewport.height - margin * 2)))
    }
}
