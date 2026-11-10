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
    public static func controls(in viewport: CGSize) -> CGRect {
        docked(size: CGSize(width: 158, height: 52), in: viewport, dock: .topTrailing)
    }

    /// Compute once for drawing, hit testing and map occlusion. At most seven
    /// direct cards; candidate positions depend on cards, never on map nodes.
    public static func frames(in definition: CompositionDefinition, viewport: CGSize,
                              collapsed: Set<String> = [], visible: Set<String>? = nil,
                              anchors: [String: CGPoint] = [:]) -> [String: CGRect] {
        guard definition.canvasMapPart != nil,
              let root = definition.layout.first(where: { $0.id == definition.rootID }) else { return [:] }
        let nodes = root.children.dropFirst().compactMap { id in definition.layout.first { $0.id == id } }
            .filter { visible?.contains($0.id) ?? true }
        var result: [String: CGRect] = [:], obstacles = [controls(in: viewport)]
        for contextual in [false, true] {
            for node in nodes where (node.presentation == .contextual) == contextual {
                let parts = definition.parts(inLayout: node.id)
                let isCollapsed = parts.count == 1 && collapsed.contains(parts[0].id)
                let primitive = parts.count == 1 ? parts[0].primitive : nil
                let timeline = primitive == .timeline
                let defaultHeight: CGFloat = timeline ? 248 : (primitive == .objectList ? 304 : 336)
                let size = CGSize(width: min(contextual ? 430 : (timeline ? 760 : 680),
                    max(timeline ? 520 : 260, viewport.width * (node.fraction ?? 0.4))),
                    height: isCollapsed ? 60 : min(CGFloat(node.preferredHeight ?? Double(defaultHeight)), max(120, viewport.height * 0.65)))
                let frame: CGRect
                if contextual {
                    frame = self.contextual(size: size, near: parts.compactMap { anchors[$0.selectionGroup] }.first,
                        in: viewport, avoiding: obstacles)
                } else {
                    frame = docked(size: size, in: viewport, dock: node.dock ?? .bottomLeading, avoiding: obstacles)
                }
                result[node.id] = frame; obstacles.append(frame)
            }
        }
        return result
    }

    public static func docked(size: CGSize, in viewport: CGSize, dock: FloatingPanelDock, avoiding: [CGRect] = []) -> CGRect {
        let bounds = usable(viewport), size = fitted(size, in: bounds)
        let x: CGFloat, y: CGFloat
        switch dock {
        case .topLeading: x = bounds.minX; y = bounds.minY
        case .topTrailing: x = bounds.maxX - size.width; y = bounds.minY
        case .bottomLeading: x = bounds.minX; y = bounds.maxY - size.height
        case .bottomTrailing: x = bounds.maxX - size.width; y = bounds.maxY - size.height
        case .bottomCenter: x = bounds.midX - size.width / 2; y = bounds.maxY - size.height
        }
        let origin = CGPoint(x: x, y: y)
        return best(size: size, bounds: bounds, origins: [origin], avoiding: avoiding, reference: origin, anchor: nil)
    }
    public static func contextual(size: CGSize, near anchor: CGPoint?, in viewport: CGSize, avoiding: [CGRect] = []) -> CGRect {
        let bounds = usable(viewport), size = fitted(size, in: bounds)
        let point = anchor.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let gap: CGFloat = 28
        let origins = [CGPoint(x: point.x + gap, y: point.y - size.height / 2),
                       CGPoint(x: point.x - gap - size.width, y: point.y - size.height / 2),
                       CGPoint(x: point.x - size.width / 2, y: point.y - gap - size.height),
                       CGPoint(x: point.x - size.width / 2, y: point.y + gap)]
        return best(size: size, bounds: bounds, origins: origins, avoiding: avoiding,
                    reference: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), anchor: point)
    }
    private static func best(size: CGSize, bounds: CGRect, origins: [CGPoint], avoiding: [CGRect], reference: CGPoint, anchor: CGPoint?) -> CGRect {
        let obstacles = avoiding.filter { !$0.isNull && !$0.isInfinite && $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite }
        // Obstacle edges make usable space below the toolbar and beside other
        // cards discoverable even when the anchor is near a viewport corner.
        var xs = [bounds.minX, bounds.maxX - size.width] + origins.map(\.x)
        var ys = [bounds.minY, bounds.maxY - size.height] + origins.map(\.y)
        for rect in obstacles.prefix(8) {
            xs += [rect.minX - size.width - 12, rect.maxX + 12]
            ys += [rect.minY - size.height - 12, rect.maxY + 12]
        }
        xs = Array(Set(xs.map { min(bounds.maxX - size.width, max(bounds.minX, $0)) })).sorted()
        ys = Array(Set(ys.map { min(bounds.maxY - size.height, max(bounds.minY, $0)) })).sorted()
        var winner = CGRect(origin: bounds.origin, size: size), minimum = CGFloat.infinity
        for x in xs { for y in ys {
            let rect = CGRect(x: x, y: y, width: size.width, height: size.height)
            let overlap = obstacles.reduce(CGFloat.zero) { total, other in
                let intersection = rect.intersection(other)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
            let coversAnchor: CGFloat = anchor.map { rect.insetBy(dx: -12, dy: -12).contains($0) } == true ? size.width * size.height : 0
            let score = overlap * 100 + coversAnchor * 4 + hypot(rect.minX - reference.x, rect.minY - reference.y)
            if score < minimum { winner = rect; minimum = score }
        } }
        return winner
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
