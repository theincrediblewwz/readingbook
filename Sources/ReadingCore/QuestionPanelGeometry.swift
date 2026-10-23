import Foundation

public enum QuestionPanelResizeCorner: Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

/// Geometry only: the host supplies the safe reading rectangle, so a question
/// never reserves a layout column or changes PDF pagination and magnification.
public enum QuestionPanelGeometry {
    public static let defaultSize = CGSize(width: 440, height: 184)
    public static let minimumSize = CGSize(width: 340, height: 156)
    public static let maximumSize = CGSize(width: 760, height: 480)
    public static let orbSize = CGSize(width: 58, height: 58)

    public static func availableBounds(_ available: CGRect, viewport: CGSize) -> CGRect {
        let window = CGRect(x: 0, y: 0, width: positive(viewport.width), height: positive(viewport.height))
        guard [available.minX, available.minY, available.width, available.height].allSatisfy(\.isFinite),
              available.width >= 0, available.height >= 0 else { return window }
        let intersection = available.intersection(window)
        return intersection.isNull ? CGRect(x: window.midX, y: window.midY, width: 0, height: 0) : intersection
    }

    public static func fittedSize(requested: CGSize, in bounds: CGRect,
                                  minimum: CGSize = minimumSize, maximum: CGSize = maximumSize) -> CGSize {
        func fit(_ request: CGFloat, minimum: CGFloat, maximum: CGFloat, available: CGFloat, fallback: CGFloat) -> CGFloat {
            let upper = min(positive(available), maximum.isFinite ? positive(maximum) : fallback)
            let lower = min(upper, positive(minimum))
            return min(upper, max(lower, request.isFinite ? request : fallback))
        }
        return CGSize(width: fit(requested.width, minimum: minimum.width, maximum: maximum.width, available: bounds.width, fallback: defaultSize.width),
                      height: fit(requested.height, minimum: minimum.height, maximum: maximum.height, available: bounds.height, fallback: defaultSize.height))
    }

    public static func frame(at dock: FloatingPanelDock, in bounds: CGRect, panel: CGSize) -> CGRect {
        let size = fittedSize(requested: panel, in: bounds, minimum: .zero, maximum: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let right = bounds.maxX - size.width, bottom = bounds.maxY - size.height
        let origin: CGPoint
        switch dock {
        case .topLeading: origin = bounds.origin
        case .topTrailing: origin = CGPoint(x: right, y: bounds.minY)
        case .bottomLeading: origin = CGPoint(x: bounds.minX, y: bottom)
        case .bottomCenter: origin = CGPoint(x: bounds.midX - size.width / 2, y: bottom)
        case .bottomTrailing: origin = CGPoint(x: right, y: bottom)
        }
        return CGRect(origin: origin, size: size)
    }

    public static func clampedFrame(_ requested: CGRect, in bounds: CGRect) -> CGRect {
        let size = fittedSize(requested: requested.size, in: bounds, minimum: .zero, maximum: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let x = requested.minX.isFinite ? requested.minX : bounds.minX
        let y = requested.minY.isFinite ? requested.minY : bounds.minY
        return CGRect(x: min(max(bounds.minX, x), bounds.maxX - size.width),
                      y: min(max(bounds.minY, y), bounds.maxY - size.height), width: size.width, height: size.height)
    }

    public static func nearest(to center: CGPoint, in bounds: CGRect, panel: CGSize,
                               preferred: FloatingPanelDock = .bottomTrailing) -> FloatingPanelDock {
        guard center.x.isFinite, center.y.isFinite else { return preferred }
        let candidates = [preferred] + FloatingPanelDock.allCases.filter { $0 != preferred }
        return candidates.min { first, second in
            let a = frame(at: first, in: bounds, panel: panel), b = frame(at: second, in: bounds, panel: panel)
            return hypot(a.midX - center.x, a.midY - center.y) < hypot(b.midX - center.x, b.midY - center.y)
        } ?? preferred
    }

    public static func resizeCorner(for dock: FloatingPanelDock) -> QuestionPanelResizeCorner {
        switch dock {
        case .topLeading: return .bottomTrailing
        case .topTrailing: return .bottomLeading
        case .bottomLeading, .bottomCenter: return .topTrailing
        case .bottomTrailing: return .topLeading
        }
    }

    /// The corner opposite the pointer stays fixed. At the default lower-right
    /// dock the upper-left grip grows into free space rather than off the window.
    public static func resizedFrame(from original: CGRect, delta: CGSize, corner: QuestionPanelResizeCorner, in bounds: CGRect,
                                    minimum: CGSize = minimumSize, maximum: CGSize = maximumSize) -> CGRect {
        let start = clampedFrame(original, in: bounds)
        let leading = corner == .topLeading || corner == .bottomLeading
        let top = corner == .topLeading || corner == .topTrailing
        let anchor = CGPoint(x: leading ? start.maxX : start.minX, y: top ? start.maxY : start.minY)
        let dx = delta.width.isFinite ? delta.width : 0, dy = delta.height.isFinite ? delta.height : 0
        let requested = CGSize(width: start.width + (leading ? -dx : dx), height: start.height + (top ? -dy : dy))
        let capacity = CGRect(x: 0, y: 0, width: leading ? anchor.x - bounds.minX : bounds.maxX - anchor.x,
                              height: top ? anchor.y - bounds.minY : bounds.maxY - anchor.y)
        let size = fittedSize(requested: requested, in: capacity, minimum: minimum, maximum: maximum)
        return CGRect(x: leading ? anchor.x - size.width : anchor.x, y: top ? anchor.y - size.height : anchor.y,
                      width: size.width, height: size.height)
    }

    private static func positive(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
}
