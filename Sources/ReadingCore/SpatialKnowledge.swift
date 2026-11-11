import Foundation

/// A directional shared relation between existing places. This is knowledge,
/// not a second map database or a saved copy of its participants.
public struct SpatialRelation: Codable, Hashable, Sendable {
    public var kind: String
    public var actorIDs: [String]
    public var viaPlaceIDs: [String]
    public var eventID: String?
    public init(kind: String = "movement", actorIDs: [String] = [], viaPlaceIDs: [String] = [], eventID: String? = nil) {
        self.kind = kind; self.actorIDs = actorIDs; self.viaPlaceIDs = viaPlaceIDs; self.eventID = eventID
    }
    public var referenceIDs: [String] { actorIDs + viaPlaceIDs + [eventID].compactMap { $0 } }
}

public struct SpatialCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

public struct SpatialRoute: Identifiable, Hashable, Sendable {
    public var id: String
    public var relationID: String
    public var eventID: String?
    public var title: String
    public var kind: String
    public var actorIDs: [String]
    public var actorNames: [String]
    public var placeIDs: [String]
    public var placeNames: [String]
    public var coordinates: [SpatialCoordinate]
    public var assertion: KnowledgeAssertion
    public var timeMatch: TemporalMatch
    public var extent: TemporalExtent
    public var explanation: String
    public var evidence: [Evidence]
    public var locationNotes: [String]
    /// Transient display grouping derived from admitted event metadata.
    public var affinityID: String? = nil
    public var affinityTitle: String? = nil
    public var isUncertain: Bool { assertion != .explicit || timeMatch == .possible || timeMatch == .unknown }
}

public enum SpatialKnowledgeRuntime {
    /// Respects the same source/object boundary as every other component.
    /// No participant-by-place inference, geocoding or interpolation is hidden here.
    public static func routes(in project: BookProject, boundary: KnowledgeReadBoundary = .all,
                              at point: TemporalQueryPoint? = nil, within window: TemporalQueryWindow? = nil,
                              actorID: String? = nil, eventIDs: Set<String>? = nil,
                              relevantObjectIDs: Set<String>? = nil, relationIDs: Set<String>? = nil, limit: Int = 128) throws -> [SpatialRoute] {
        guard (1...128).contains(limit) else { throw ReadingError.invalid("地图路线数量应在1–128之间。") }
        try Task.checkCancellation()
        guard project.temporalKnowledge?.relationMetadata.contains(where: { $0.spatial != nil }) == true else { return [] }
        let objects = try TemporalKnowledgeRuntime.objects(in: project, boundary: boundary)
        let byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let anchors = Dictionary(((project.readingExperience?.anchors ?? []) + (project.temporalKnowledge?.anchors ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let records = try window.map { try TemporalKnowledgeRuntime.relations(in: project, within: $0, boundary: boundary) }
            ?? TemporalKnowledgeRuntime.relations(in: project, at: point, boundary: boundary)
        let locations = TemporalKnowledgeRuntime.locationEntityIDs(in: project, boundary: boundary)
        // objects already contains admitted, parent-redacted adapters. Reuse
        // them instead of rebuilding every event snapshot/version a second time.
        let families = SpatialMarkerSeeds.familyRoots(objects: objects)
        let filteringTime = point != nil || window != nil
        var result: [SpatialRoute] = [], undated: [SpatialRoute] = []
        for record in records {
            try Task.checkCancellation()
            guard let metadata = record.metadata, let spatial = metadata.spatial,
                  relationIDs.map({ $0.contains(record.relation.id) }) ?? true,
                  actorID.map({ spatial.actorIDs.contains($0) }) ?? true,
                  eventIDs.map({ allowed in spatial.eventID.map { allowed.contains($0) } ?? false }) ?? true else { continue }
            // Incomparable/unknown dates are not outside the chosen period.
            // Keep them visibly uncertain, consistently with timeline events.
            // An associated event is not permission to borrow its date.
            let unresolved = filteringTime && record.match == .unknown
            if unresolved && undated.count == limit { continue }
            let ids = [record.relation.fromID] + spatial.viaPlaceIDs + [record.relation.toID]
            guard spatial.referenceIDs.allSatisfy({ byID[$0] != nil }),
                  relevantObjectIDs.map({ !$0.isDisjoint(with: ids + spatial.actorIDs + [spatial.eventID].compactMap { $0 }) }) ?? true else { continue }
            let places = ids.compactMap { byID[$0] }
            guard places.count == ids.count, places.allSatisfy({ locations.contains($0.id) && $0.latitude != nil && $0.longitude != nil }) else { continue }
            let coordinates = places.compactMap { p -> SpatialCoordinate? in
                guard let lat = p.latitude, let lon = p.longitude, lat.isFinite, lon.isFinite,
                      (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
                return .init(latitude: lat, longitude: lon)
            }
            guard coordinates.count == places.count else { continue }
            var evidence = record.relation.evidence
            for id in metadata.sourceAnchorIDs {
                if let anchor = anchors[id] {
                    let item = Evidence(unitID: anchor.unitID, quote: anchor.quote)
                    if !evidence.contains(item) { evidence.append(item) }
                }
            }
            let route = SpatialRoute(id: metadata.id, relationID: record.relation.id, eventID: spatial.eventID,
                title: record.relation.label, kind: spatial.kind, actorIDs: spatial.actorIDs,
                actorNames: spatial.actorIDs.compactMap { byID[$0]?.name }, placeIDs: ids, placeNames: places.map(\.name),
                coordinates: coordinates, assertion: metadata.assertion, timeMatch: record.match,
                extent: metadata.validity, explanation: metadata.explanation, evidence: evidence,
                locationNotes: places.map { $0.locationNote ?? "现代地理参考位置" },
                affinityID: spatial.eventID.flatMap { families[$0] },
                affinityTitle: spatial.eventID.flatMap { families[$0] }.flatMap { byID[$0]?.name })
            if unresolved { undated.append(route) } else { result.append(route) }
            if result.count == limit { break }
        }
        // Unresolved routes cannot crowd known matching routes out of the cap.
        return result + undated.prefix(limit - result.count)
    }
}

/// Geographic geometry stays attached to the route as the map pans/rotates.
public enum SpatialRouteGeometry {
    public static func arrowhead(_ path: [SpatialCoordinate]) -> [SpatialCoordinate] {
        guard let end = path.last, path.count > 1 else { return [] }
        let radians = Double.pi / 180, radius = 6_371_000.0
        for start in path.dropLast().reversed() {
            let a = start.latitude * radians, b = end.latitude * radians, delta = (end.longitude - start.longitude) * radians
            let h = pow(sin((b-a)/2), 2) + cos(a) * cos(b) * pow(sin(delta/2), 2)
            let distance = radius * 2 * asin(sqrt(min(1, max(0, h))))
            guard distance.isFinite else { return [] }
            if distance < 1 { continue }
            let heading = atan2(sin(delta)*cos(b), cos(a)*sin(b)-sin(a)*cos(b)*cos(delta))
            func move(_ origin: SpatialCoordinate, bearing: Double, meters: Double) -> SpatialCoordinate {
                let lat = origin.latitude*radians, lon = origin.longitude*radians, arc = meters/radius
                let next = asin(sin(lat)*cos(arc)+cos(lat)*sin(arc)*cos(bearing))
                let lng = lon + atan2(sin(bearing)*sin(arc)*cos(lat), cos(arc)-sin(lat)*sin(next))
                let normalized = (lng/radians + 540).truncatingRemainder(dividingBy: 360) - 180
                return .init(latitude: next/radians, longitude: normalized)
            }
            let tip = move(start, bearing: heading, meters: distance*0.82)
            let length = min(distance*0.15, max(30, min(5000, distance*0.07)))
            let base = move(tip, bearing: heading + .pi, meters: length)
            return [tip, move(base, bearing: heading + .pi/2, meters: length*0.55), move(base, bearing: heading - .pi/2, meters: length*0.55)]
        }
        return []
    }
}
