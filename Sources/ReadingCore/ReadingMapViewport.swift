import Foundation

public struct ReadingMapMarkerGroup: Codable, Hashable, Sendable {
    public var id: String
    public var objectIDs: [String]
    public var routeIDs: [String]
    public init(id: String, objectIDs: [String], routeIDs: [String]) { self.id = id; self.objectIDs = objectIDs; self.routeIDs = routeIDs }
    public var isValid: Bool { !id.isEmpty && id.utf8.count <= 1024 && objectIDs.count <= 10_000 && routeIDs.count <= 1024 }
}

/// Ephemeral renderer observations, not saved geography or analysis. The host
/// reports settled cameras only; model-facing tools reapply the query boundary.
public struct ReadingMapViewport: Codable, Hashable, Sendable {
    public var partID: String
    public var latitude: Double
    public var longitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double
    public var objectIDs: [String]
    public var visibleRouteIDs: [String]
    public var projectedRouteIDs: [String]
    public var markerGroups: [ReadingMapMarkerGroup]?
    public init(partID: String, latitude: Double, longitude: Double, latitudeDelta: Double, longitudeDelta: Double,
                objectIDs: [String], visibleRouteIDs: [String], projectedRouteIDs: [String], markerGroups: [ReadingMapMarkerGroup]? = nil) {
        self.partID = partID; self.latitude = latitude; self.longitude = longitude
        self.latitudeDelta = latitudeDelta; self.longitudeDelta = longitudeDelta; self.objectIDs = objectIDs
        self.visibleRouteIDs = visibleRouteIDs; self.projectedRouteIDs = projectedRouteIDs
        self.markerGroups = markerGroups
    }
    public var isValid: Bool {
        !partID.isEmpty && partID.utf8.count <= 256 && latitude.isFinite && abs(latitude) <= 90
        && longitude.isFinite && abs(longitude) <= 180 && latitudeDelta.isFinite && (0...180).contains(latitudeDelta)
        && longitudeDelta.isFinite && (0...360).contains(longitudeDelta)
        && objectIDs.count <= 10_000 && visibleRouteIDs.count <= 1024 && projectedRouteIDs.count <= 1024
        && (markerGroups?.count ?? 0) <= 512 && (markerGroups ?? []).allSatisfy(\.isValid)
        && (markerGroups ?? []).reduce(0, { $0 + $1.objectIDs.count + $1.routeIDs.count }) <= 10_000
    }
}

public struct ReadingViewTimeWindow: Codable, Hashable, Sendable {
    public var groupID: String
    public var axis: String
    public var from: Double
    public var to: Double
    public var current: Double
    public init(groupID: String, axis: String, from: Double, to: Double, current: Double) {
        self.groupID = groupID; self.axis = axis; self.from = from; self.to = to; self.current = current
    }
    public var isValid: Bool {
        !groupID.isEmpty && groupID.utf8.count <= 256 && !axis.isEmpty && axis.utf8.count <= 256
        && [from, to, current].allSatisfy { $0.isFinite && abs($0) <= 1_000_000_000_000 }
        && from <= current && current <= to
    }
}

/// Screen-space clipping after the map has projected its coordinates. Cut out
/// floating cards before declaring a point or any portion of a route visible.
public enum SpatialViewportVisibility {
    /// Largest unobscured rectangle, used only when explicitly fitting a map.
    /// Sweep horizontal edges and merge vertical blockers instead of sampling
    /// pixels or rebuilding knowledge as the camera moves.
    public static func availableRect(in viewport: CGRect, excluding occlusions: [CGRect], padding: CGFloat = 20) -> CGRect? {
        guard !viewport.isNull, !viewport.isInfinite, viewport.width > 0, viewport.height > 0,
              [viewport.minX, viewport.minY, viewport.maxX, viewport.maxY].allSatisfy(\.isFinite),
              padding.isFinite, padding >= 0, occlusions.count <= 64,
              occlusions.allSatisfy({ !$0.isNull && !$0.isInfinite && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) }) else { return nil }
        let bounds = viewport.insetBy(dx: padding, dy: padding)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let blocks = occlusions.filter { !$0.isEmpty }.map { $0.insetBy(dx: -padding, dy: -padding).intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        let xs = Array(Set([bounds.minX, bounds.maxX] + blocks.flatMap { [$0.minX, $0.maxX] })).sorted()
        var best: CGRect?
        func consider(_ rect: CGRect) {
            guard rect.width > 0, rect.height > 0 else { return }
            let area = rect.width * rect.height, oldArea = best.map { $0.width * $0.height } ?? -1
            let distance = abs(rect.midX - bounds.midX) + abs(rect.midY - bounds.midY)
            let oldDistance = best.map { abs($0.midX - bounds.midX) + abs($0.midY - bounds.midY) } ?? .infinity
            if area > oldArea || area == oldArea && distance < oldDistance { best = rect }
        }
        for (index, left) in xs.enumerated() {
            for right in xs.dropFirst(index + 1) where right > left {
                let covered = blocks.filter { $0.minX < right && $0.maxX > left }.sorted { $0.minY < $1.minY }
                var top = bounds.minY
                for block in covered {
                    if block.minY > top { consider(CGRect(x: left, y: top, width: right - left, height: block.minY - top)) }
                    top = max(top, block.maxY)
                }
                if top < bounds.maxY { consider(CGRect(x: left, y: top, width: right - left, height: bounds.maxY - top)) }
            }
        }
        return best
    }
    public static func contains(_ point: CGPoint, in viewport: CGRect, excluding occlusions: [CGRect]) -> Bool {
        point.x.isFinite && point.y.isFinite && viewport.contains(point) && !occlusions.contains { $0.contains(point) }
    }
    public static func intersects(_ path: [CGPoint], viewport: CGRect, excluding occlusions: [CGRect]) -> Bool {
        guard path.count > 1, viewport.width > 0, viewport.height > 0 else { return false }
        for (a, b) in zip(path, path.dropFirst()) {
            guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite,
                  let interval = clip(a, b, rect: viewport) else { continue }
            var visible = [interval]
            for rect in occlusions {
                guard let covered = clip(a, b, rect: rect) else { continue }
                visible = visible.flatMap { range -> [ClosedRange<Double>] in
                    if covered.upperBound < range.lowerBound || covered.lowerBound > range.upperBound { return [range] }
                    var remainder: [ClosedRange<Double>] = []
                    if covered.lowerBound > range.lowerBound { remainder.append(range.lowerBound...min(range.upperBound, covered.lowerBound)) }
                    if covered.upperBound < range.upperBound { remainder.append(max(range.lowerBound, covered.upperBound)...range.upperBound) }
                    return remainder
                }
                if visible.isEmpty { break }
            }
            if visible.contains(where: { $0.upperBound - $0.lowerBound > 0.000001 }) { return true }
        }
        return false
    }
    private static func clip(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> ClosedRange<Double>? {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y
        var lower = 0.0, upper = 1.0
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 { if q < 0 { return nil }; continue }
            let t = q / p
            if p < 0 { lower = max(lower, t) } else { upper = min(upper, t) }
            if lower > upper { return nil }
        }
        return lower...upper
    }
}
