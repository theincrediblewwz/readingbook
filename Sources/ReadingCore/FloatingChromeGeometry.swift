import Foundation

/// Layout-only placement for settled floating controls. It never changes a
/// user's saved camera, panel origin, book content or interaction coordinates.
public enum FloatingChromeGeometry {
    /// Preserve the preferred origin when clear; otherwise choose the nearest
    /// complete slot around the actual obstacles. A crowded surface returns nil
    /// so its host can offer a compact form or keep its existing recovery entry.
    public static func place(size: CGSize, preferredOrigin: CGPoint, within bounds: CGRect,
                             avoiding obstacles: [CGRect], gap: CGFloat = 12) -> CGRect? {
        guard valid(bounds), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= bounds.width, size.height <= bounds.height else { return nil }
        let padding = gap.isFinite ? max(0, gap) : 12
        let blocked = obstacles.compactMap { obstacle -> CGRect? in
            guard valid(obstacle) else { return nil }
            let expanded = obstacle.insetBy(dx: -padding, dy: -padding)
            guard valid(expanded) else { return nil }
            let clipped = expanded.intersection(bounds)
            return valid(clipped) ? clipped : nil
        }
        let maxX = bounds.maxX - size.width, maxY = bounds.maxY - size.height
        func x(_ value: CGFloat) -> CGFloat { min(max(bounds.minX, value.isFinite ? value : bounds.minX), maxX) }
        func y(_ value: CGFloat) -> CGFloat { min(max(bounds.minY, value.isFinite ? value : bounds.minY), maxY) }
        let preferred = CGPoint(x: x(preferredOrigin.x), y: y(preferredOrigin.y))
        var xs = [preferred.x, bounds.minX, maxX], ys = [preferred.y, bounds.minY, maxY]
        for obstacle in blocked {
            xs += [x(obstacle.minX - size.width), x(obstacle.maxX)]
            ys += [y(obstacle.minY - size.height), y(obstacle.maxY)]
        }
        var best: CGRect?, bestDistance = CGFloat.greatestFiniteMagnitude
        for candidateY in ys {
            for candidateX in xs {
                let frame = CGRect(origin: CGPoint(x: candidateX, y: candidateY), size: size)
                guard !blocked.contains(where: { $0.intersects(frame) }) else { continue }
                let dx = frame.minX - preferred.x, dy = frame.minY - preferred.y
                let distance = dx * dx + dy * dy
                if best == nil || distance < bestDistance { best = frame; bestDistance = distance }
            }
        }
        return best
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty &&
        [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
