import Foundation

/// Resize directions use top-left reading coordinates, independently of the
/// panel's remembered position or the side it originally opened on.
public enum FloatingPanelResizeDirection: CaseIterable, Hashable, Sendable {
    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    public var movesLeading: Bool { self == .leading || self == .topLeading || self == .bottomLeading }
    public var movesTrailing: Bool { self == .trailing || self == .topTrailing || self == .bottomTrailing }
    public var movesTop: Bool { self == .top || self == .topLeading || self == .topTrailing }
    public var movesBottom: Bool { self == .bottom || self == .bottomLeading || self == .bottomTrailing }
}

/// The opposite edge stays fixed; resizing one axis never changes the other.
/// A crowded viewport may be smaller than the usual minimum, but never pushes
/// a title or an active edge outside the actual reading bounds.
public enum FloatingPanelResizeGeometry {
    public static func resizedFrame(from original: CGRect, delta: CGSize,
                                    direction: FloatingPanelResizeDirection, in bounds: CGRect,
                                    minimum: CGSize = CGSize(width: 320, height: 260)) -> CGRect {
        guard !bounds.isNull, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width >= 0, bounds.height >= 0 else { return .zero }
        func extent(_ value: CGFloat, fallback: CGFloat, available: CGFloat) -> CGFloat {
            min(available, max(0, value.isFinite ? value : (fallback.isFinite ? fallback : 0)))
        }
        let width = extent(original.width, fallback: minimum.width, available: bounds.width)
        let height = extent(original.height, fallback: minimum.height, available: bounds.height)
        let x = min(max(bounds.minX, original.minX.isFinite ? original.minX : bounds.minX), bounds.maxX - width)
        let y = min(max(bounds.minY, original.minY.isFinite ? original.minY : bounds.minY), bounds.maxY - height)
        let start = CGRect(x: x, y: y, width: width, height: height)
        let dx = delta.width.isFinite ? delta.width : 0, dy = delta.height.isFinite ? delta.height : 0
        let minimumWidth = minimum.width.isFinite ? max(0, minimum.width) : 320
        let minimumHeight = minimum.height.isFinite ? max(0, minimum.height) : 260
        var left = start.minX, right = start.maxX, top = start.minY, bottom = start.maxY
        if direction.movesLeading {
            let lower = min(minimumWidth, start.maxX - bounds.minX)
            left = min(start.maxX - lower, max(bounds.minX, start.minX + dx))
        } else if direction.movesTrailing {
            let lower = min(minimumWidth, bounds.maxX - start.minX)
            right = max(start.minX + lower, min(bounds.maxX, start.maxX + dx))
        }
        if direction.movesTop {
            let lower = min(minimumHeight, start.maxY - bounds.minY)
            top = min(start.maxY - lower, max(bounds.minY, start.minY + dy))
        } else if direction.movesBottom {
            let lower = min(minimumHeight, bounds.maxY - start.minY)
            bottom = max(start.minY + lower, min(bounds.maxY, start.maxY + dy))
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
