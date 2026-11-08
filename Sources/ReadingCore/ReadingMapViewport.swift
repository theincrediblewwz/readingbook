import Foundation

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
    public init(partID: String, latitude: Double, longitude: Double, latitudeDelta: Double, longitudeDelta: Double,
                objectIDs: [String], visibleRouteIDs: [String], projectedRouteIDs: [String]) {
        self.partID = partID; self.latitude = latitude; self.longitude = longitude
        self.latitudeDelta = latitudeDelta; self.longitudeDelta = longitudeDelta; self.objectIDs = objectIDs
        self.visibleRouteIDs = visibleRouteIDs; self.projectedRouteIDs = projectedRouteIDs
    }
    public var isValid: Bool {
        !partID.isEmpty && partID.utf8.count <= 256 && latitude.isFinite && abs(latitude) <= 90
        && longitude.isFinite && abs(longitude) <= 180 && latitudeDelta.isFinite && (0...180).contains(latitudeDelta)
        && longitudeDelta.isFinite && (0...360).contains(longitudeDelta)
        && objectIDs.count <= 10_000 && visibleRouteIDs.count <= 1024 && projectedRouteIDs.count <= 1024
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
