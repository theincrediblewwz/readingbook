import Foundation

extension CompositionDefinition {
    /// A direct map under an overlay can use the whole viewport. Nested rows
    /// and columns retain their document-scrolling behavior.
    public var canvasMapPart: CompositionPart? {
        guard let root = layout.first(where: { $0.id == rootID }), root.kind == .overlay,
              let first = root.children.first, let node = layout.first(where: { $0.id == first }), node.kind == .part,
              let part = parts.first(where: { $0.id == node.partID }), part.primitive == .map else { return nil }
        return part
    }
    public func parts(inLayout id: String) -> [CompositionPart] {
        var visited = Set<String>()
        func walk(_ id: String) -> [CompositionPart] {
            guard visited.count < 48, visited.insert(id).inserted, let node = layout.first(where: { $0.id == id }) else { return [] }
            if node.kind == .part { return parts.filter { $0.id == node.partID } }
            return node.children.flatMap(walk)
        }
        return walk(id)
    }
}

/// Screen geometry only. Moving a card never rewrites map coordinates or facts.
public enum CompositionCanvasLayout {
    public static func docked(size: CGSize, in viewport: CGSize, dock: FloatingPanelDock) -> CGRect {
        let bounds = usable(viewport), size = fitted(size, in: bounds)
        let x: CGFloat, y: CGFloat
        switch dock {
        case .topLeading: x = bounds.minX; y = bounds.minY
        case .topTrailing: x = bounds.maxX - size.width; y = bounds.minY
        case .bottomLeading: x = bounds.minX; y = bounds.maxY - size.height
        case .bottomTrailing: x = bounds.maxX - size.width; y = bounds.maxY - size.height
        case .bottomCenter: x = bounds.midX - size.width / 2; y = bounds.maxY - size.height
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
    public static func contextual(size: CGSize, near anchor: CGPoint?, in viewport: CGSize, avoiding: [CGRect] = []) -> CGRect {
        let bounds = usable(viewport), size = fitted(size, in: bounds)
        let point = anchor.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let gap: CGFloat = 28
        let origins = [CGPoint(x: point.x + gap, y: point.y - size.height / 2),
                       CGPoint(x: point.x - gap - size.width, y: point.y - size.height / 2),
                       CGPoint(x: point.x - size.width / 2, y: point.y - gap - size.height),
                       CGPoint(x: point.x - size.width / 2, y: point.y + gap),
                       CGPoint(x: bounds.maxX - size.width, y: bounds.minY),
                       CGPoint(x: bounds.minX, y: bounds.minY)]
        let candidates = origins.map { origin in CGRect(x: min(bounds.maxX - size.width, max(bounds.minX, origin.x)),
            y: min(bounds.maxY - size.height, max(bounds.minY, origin.y)), width: size.width, height: size.height) }
        func score(_ rect: CGRect) -> CGFloat {
            let overlap = avoiding.reduce(CGFloat.zero) { total, other in
                let intersection = rect.intersection(other)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
            let coversAnchor: CGFloat = rect.insetBy(dx: -12, dy: -12).contains(point) ? size.width * size.height : 0
            let distance = hypot(rect.midX - point.x, rect.midY - point.y)
            return overlap * 8 + coversAnchor * 4 + distance
        }
        return candidates.min { score($0) < score($1) }!
    }
    private static func usable(_ viewport: CGSize) -> CGRect {
        let width = viewport.width.isFinite ? max(1, viewport.width) : 1
        let height = viewport.height.isFinite ? max(1, viewport.height) : 1
        let inset = min(12, width / 10, height / 10, max(0, width - 1) / 2, max(0, height - 1) / 2)
        return CGRect(x: inset, y: inset, width: max(1, width - 2 * inset), height: max(1, height - 2 * inset))
    }
    private static func fitted(_ size: CGSize, in bounds: CGRect) -> CGSize {
        CGSize(width: min(bounds.width, size.width.isFinite ? max(1, size.width) : bounds.width),
               height: min(bounds.height, size.height.isFinite ? max(1, size.height) : bounds.height))
    }
}
