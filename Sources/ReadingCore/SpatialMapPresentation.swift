import Foundation

/// Display assets are independent of a book's schema. Unknown action kinds
/// remain valid shared knowledge and use the neutral asset.
public struct SpatialMarkerAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let tint: String
    public let aliases: [String]
}
public enum SpatialMarkerAssets {
    public static let all: [SpatialMarkerAsset] = [
        .init(id: "fire", title: "火攻", symbol: "flame.fill", tint: "fire", aliases: ["火攻", "纵火", "縱火", "fire", "fire_attack"]),
        .init(id: "battle", title: "交战", symbol: "crossed-swords", tint: "battle", aliases: ["战斗", "戰鬥", "交战", "交戰", "进攻", "進攻", "battle", "attack", "伏击", "伏擊", "设伏", "設伏"]),
        .init(id: "retreat", title: "撤退", symbol: "arrow.uturn.backward", tint: "retreat", aliases: ["撤退", "退军", "退軍", "脱身", "脫身", "retreat", "withdrawal"]),
        .init(id: "march", title: "行军", symbol: "figure.walk", tint: "march", aliases: ["行军", "行軍", "进兵", "進兵", "移兵", "调兵", "調兵", "movement", "march"]),
        .init(id: "water", title: "渡河", symbol: "sailboat.fill", tint: "water", aliases: ["渡河", "密渡", "渡江", "航行", "water", "crossing", "naval"]),
        .init(id: "camp", title: "驻营", symbol: "tent.fill", tint: "camp", aliases: ["驻营", "駐營", "进驻", "進駐", "下寨", "驻扎", "駐紮", "camp"]),
        .init(id: "meeting", title: "会见", symbol: "person.2.fill", tint: "meeting", aliases: ["会盟", "會盟", "会见", "會見", "meeting", "alliance"]),
        .init(id: "arrival", title: "抵达", symbol: "flag.fill", tint: "march", aliases: ["抵达", "抵達", "arrival"]),
        .init(id: "transport", title: "运输", symbol: "shippingbox.fill", tint: "camp", aliases: ["运输", "運輸", "运粮", "運糧", "transport", "supply"]),
        .init(id: "observation", title: "观测", symbol: "binoculars.fill", tint: "water", aliases: ["observation", "观测", "觀測"]),
        .init(id: "measurement", title: "测量", symbol: "ruler", tint: "water", aliases: ["measurement", "测量", "測量"]),
        .init(id: "repair", title: "修复", symbol: "wrench.and.screwdriver.fill", tint: "camp", aliases: ["repair", "修复", "修復"]),
        .init(id: "warning", title: "警示", symbol: "exclamationmark.triangle.fill", tint: "fire", aliases: ["warning", "警示"]),
        .init(id: "sample", title: "采样", symbol: "leaf.fill", tint: "retreat", aliases: ["sample", "采样", "採樣"]),
        .init(id: "person", title: "人物", symbol: "person.fill", tint: "neutral", aliases: ["person", "presence"]),
        .init(id: "place", title: "地点", symbol: "smallcircle.filled.circle", tint: "neutral", aliases: ["place", "entityLocation"]),
        .init(id: "group", title: "一组记录", symbol: "square.stack.3d.up.fill", tint: "neutral", aliases: []),
        .init(id: "event", title: "事件", symbol: "diamond.fill", tint: "neutral", aliases: ["event", "eventLocation"])
    ]
    public static var selectable: [SpatialMarkerAsset] { all.filter { $0.id != "group" } }
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    private static let byKind: [String: SpatialMarkerAsset] = {
        var result: [String: SpatialMarkerAsset] = [:]
        for asset in all { for key in [asset.id] + asset.aliases { if result[key.lowercased()] == nil { result[key.lowercased()] = asset } } }
        return result
    }()
    public static func asset(_ id: String) -> SpatialMarkerAsset { byID[id] ?? byID["event"]! }
    public static func validate(_ mappings: [String: String]) throws {
        guard mappings.count <= 32, mappings.allSatisfy({ kind, id in
            !kind.isEmpty && kind == kind.trimmingCharacters(in: .whitespacesAndNewlines) && kind.utf8.count <= 80 && byID[id] != nil && id != "group"
        }) else { throw ReadingError.invalid("地图markerAssets最多32项；键为实际kind（1至80字节），值须为素材目录中的ID。分组图标由显示器自动选择。") }
    }
    /// Title fallback chooses a visual hint, never writes an event category.
    public static func resolve(kind: String, title: String = "", fallback: String = "event", mappings: [String: String]? = nil) -> SpatialMarkerAsset {
        let key = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let id = mappings?[kind], let chosen = byID[id], id != "group" { return chosen }
        if let exact = byKind[key],
           !["event", "place", "group"].contains(exact.id) { return exact }
        if mappings == nil, fallback != "place", fallback != "person" {
            let text = String(title.prefix(160)).lowercased()
            if let hint = all.prefix(9).first(where: { asset in asset.aliases.contains { $0.count >= 2 && text.contains($0.lowercased()) } }) { return hint }
        }
        return asset(fallback)
    }
}

/// An annotation's geographic identity never changes when its screen layout
/// changes. These values are transient; no new facts or coordinates are saved.
public struct SpatialMarkerSeed: Identifiable, Hashable, Sendable {
    public var id: String
    public var objectID: String?
    public var routeID: String?
    public var title: String
    public var subtitle: String
    public var coordinate: SpatialCoordinate
    public var assetID: String
    public var affinityID: String?
    public var affinityTitle: String?
    public init(id: String, objectID: String? = nil, routeID: String? = nil, title: String, subtitle: String = "",
                coordinate: SpatialCoordinate, assetID: String, affinityID: String? = nil, affinityTitle: String? = nil) {
        self.id = id; self.objectID = objectID; self.routeID = routeID; self.title = title; self.subtitle = subtitle
        self.coordinate = coordinate; self.assetID = assetID; self.affinityID = affinityID; self.affinityTitle = affinityTitle
    }
}
public struct SpatialMarkerScreenPoint: Sendable {
    public var seed: SpatialMarkerSeed
    public var x: Double
    public var y: Double
    public init(seed: SpatialMarkerSeed, x: Double, y: Double) { self.seed = seed; self.x = x; self.y = y }
}
public struct SpatialMarkerNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var members: [SpatialMarkerSeed]
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public var showsTitle: Bool = false
    public var isSelected: Bool = false
    public var coordinate: SpatialCoordinate { members[0].coordinate }
    public var isGroup: Bool { members.count > 1 }
    public var title: String { isGroup ? (members[0].affinityTitle ?? "同处记录") : members[0].title }
    public var assetID: String { isGroup ? "group" : members[0].assetID }
}
public struct SpatialMarkerLayout: Sendable {
    public var nodes: [SpatialMarkerNode]
    public var candidateCount: Int
    public var distanceChecks: Int
    public var overlapChecks: Int = 0
}

public enum SpatialMarkerPacking {
    public static let maximumMarkers = 2048
    /// A presentation ceiling is not a book-data ceiling. Keep selected records
    /// first; callers disclose the partial display and can narrow their scope.
    public static func boundedSeeds(_ seeds: [SpatialMarkerSeed], selectedObjectIDs: Set<String> = [], selectedRouteID: String? = nil) -> [SpatialMarkerSeed] {
        guard seeds.count > maximumMarkers else { return seeds }
        let selected: (SpatialMarkerSeed) -> Bool = { $0.objectID.map(selectedObjectIDs.contains) == true || ($0.routeID != nil && $0.routeID == selectedRouteID) }
        let priority = Array(seeds.lazy.filter(selected).prefix(maximumMarkers))
        return priority + seeds.lazy.filter { !selected($0) }.prefix(maximumMarkers - priority.count)
    }
    /// Distance decisions use actual projected points. Buckets only accelerate
    /// neighbour lookup: moving across a bucket edge cannot change a decision.
    /// Each group is bounded around a stable leader, never a transitive chain
    /// that could turn nearby records into a continent-sized "battle".
    public static func layout(_ input: [SpatialMarkerScreenPoint], width: Double, height: Double,
                              selectedObjectIDs: Set<String> = [], selectedRouteID: String? = nil,
                              radius: Double = 42, showTitles: Bool = false, retainOffscreen: Bool = false) -> SpatialMarkerLayout {
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 10_000_000, height <= 10_000_000,
              radius.isFinite, radius >= 24, radius <= 100,
              input.count <= maximumMarkers else { return .init(nodes: [], candidateCount: 0, distanceChecks: 0) }
        struct Cell: Hashable { let x: Int; let y: Int; let affinity: String }
        struct Group { var leader: SpatialMarkerScreenPoint; var members: [SpatialMarkerSeed] }
        let points = input.filter { $0.x.isFinite && $0.y.isFinite && $0.seed.coordinate.latitude.isFinite && $0.seed.coordinate.longitude.isFinite
            && abs($0.seed.coordinate.latitude) <= 90 && abs($0.seed.coordinate.longitude) <= 180
            && !$0.seed.id.isEmpty && abs($0.x) <= 10_000_000 && abs($0.y) <= 10_000_000
            && (retainOffscreen || ($0.x >= -radius && $0.x <= width + radius && $0.y >= -radius && $0.y <= height + radius)) }
            .sorted { $0.seed.id < $1.seed.id }
        var seen = Set<String>(), groups: [Group] = [], cells: [Cell: [Int]] = [:], selected: [SpatialMarkerScreenPoint] = [], checks = 0
        func isSelected(_ seed: SpatialMarkerSeed) -> Bool { seed.objectID.map(selectedObjectIDs.contains) == true || (seed.routeID != nil && seed.routeID == selectedRouteID) }
        for point in points where seen.insert(point.seed.id).inserted {
            if isSelected(point.seed) { selected.append(point); continue }
            let x = Int(floor(point.x / radius)), y = Int(floor(point.y / radius)), affinity = point.seed.affinityID ?? ""
            var best: Int?, distance = radius * radius
            for dx in -1...1 { for dy in -1...1 {
                for index in cells[Cell(x: x + dx, y: y + dy, affinity: affinity)] ?? [] {
                    checks += 1
                    let leader = groups[index].leader, dx = point.x - leader.x, dy = point.y - leader.y, value = dx * dx + dy * dy
                    if value < distance || (value == distance && (best == nil || index < best!)) { best = index; distance = value }
                }
            } }
            if let best { groups[best].members.append(point.seed) }
            else { let index = groups.count; groups.append(.init(leader: point, members: [point.seed])); cells[Cell(x: x, y: y, affinity: affinity), default: []].append(index) }
        }
        var occupied = MarkerRectIndex(), nodes: [SpatialMarkerNode] = []
        // Reserve selected labels before ordinary labels or group badges.
        for point in selected {
            var node = SpatialMarkerNode(id: point.seed.id, members: [point.seed], showsTitle: true, isSelected: true)
            let frame = CGRect(x: point.x - 18, y: point.y - 22, width: 172, height: 44)
            if frame.maxX > width { node.offsetX = -min(140, max(0, frame.maxX - width)) }
            occupied.insert(frame.offsetBy(dx: node.offsetX, dy: 0)); nodes.append(node)
        }
        for group in groups {
            var node = SpatialMarkerNode(id: (group.members.count > 1 ? "group:" : "") + group.leader.seed.id, members: group.members)
            let x = group.leader.x, y = group.leader.y, size = group.members.count > 1 ? 68.0 : 32.0
            var frame = CGRect(x: x - size / 2, y: y - 22, width: size, height: 44)
            for offset in [0.0, -48, 48, -96, 96] {
                let candidate = frame.offsetBy(dx: 0, dy: offset)
                if candidate.minY >= 0, candidate.maxY <= height, !occupied.intersects(candidate) { node.offsetY = offset; frame = candidate; break }
            }
            if showTitles, !node.isGroup {
                let label = CGRect(x: frame.minX, y: frame.minY, width: 172, height: 44)
                if label.maxX <= width, !occupied.intersects(label) { node.showsTitle = true; frame = label }
            }
            occupied.insert(frame); nodes.append(node)
        }
        return .init(nodes: nodes, candidateCount: seen.count, distanceChecks: checks, overlapChecks: occupied.checks)
    }
    public static func bootstrap(_ seeds: [SpatialMarkerSeed], selectedObjectIDs: Set<String> = [], selectedRouteID: String? = nil) -> [SpatialMarkerNode] {
        boundedSeeds(seeds, selectedObjectIDs: selectedObjectIDs, selectedRouteID: selectedRouteID).map { seed in
            let chosen = seed.objectID.map(selectedObjectIDs.contains) == true || (seed.routeID != nil && seed.routeID == selectedRouteID)
            return .init(id: seed.id, members: [seed], showsTitle: chosen, isSelected: chosen)
        }
    }
}

/// Annotation labels also use local buckets; avoiding an all-pairs label scan
/// matters just as much as accelerating geographic clustering.
private struct MarkerRectIndex {
    private struct Cell: Hashable { let x: Int; let y: Int }
    private var buckets: [Cell: [Int]] = [:]
    private var rects: [CGRect] = []
    var checks = 0
    private func cells(_ rect: CGRect) -> [Cell] {
        (Int(floor(rect.minX / 64))...Int(floor(rect.maxX / 64))).flatMap { x in
            (Int(floor(rect.minY / 64))...Int(floor(rect.maxY / 64))).map { Cell(x: x, y: $0) }
        }
    }
    mutating func insert(_ rect: CGRect) {
        let index = rects.count; rects.append(rect)
        for cell in cells(rect) { buckets[cell, default: []].append(index) }
    }
    mutating func intersects(_ rect: CGRect) -> Bool {
        var seen = Set<Int>()
        for cell in cells(rect) { for index in buckets[cell] ?? [] where seen.insert(index).inserted {
            checks += 1
            if rects[index].intersects(rect) { return true }
        } }
        return false
    }
}

public enum SpatialMarkerSeeds {
    public static func familyRoots(objects: [TypedObject]) -> [String: String] {
        let events = objects.filter { $0.kind == .event }
        return familyRoots(eventIDs: Set(events.map(\.id)), parents: Dictionary(events.compactMap { event in
            guard let parents = event.references["parentEvent"], parents.count == 1 else { return nil }
            return (event.id, parents[0])
        }, uniquingKeysWith: { first, _ in first }))
    }
    /// Shared parent facts define a display family, independently of title or
    /// subject. Only admitted event IDs may contribute ancestors or labels.
    /// Resolve each chain once; invalid cycles do not become named families.
    public static func familyRoots(eventIDs: Set<String>, parents: [String: String]) -> [String: String] {
        var resolved: [String: String] = [:], invalid = Set<String>()
        for id in eventIDs.sorted() where resolved[id] == nil && !invalid.contains(id) {
            var path = [String](), visited = Set<String>(), cursor = id, root: String?
            while true {
                if let known = resolved[cursor] { root = known; break }
                if invalid.contains(cursor) || !visited.insert(cursor).inserted { break }
                path.append(cursor)
                guard let parent = parents[cursor], eventIDs.contains(parent) else { root = cursor; break }
                cursor = parent
            }
            for member in path {
                if let root { resolved[member] = root }
                else { invalid.insert(member) }
            }
        }
        let linkedRoots = Set(parents.compactMap { child, parent -> String? in
            guard eventIDs.contains(child), eventIDs.contains(parent), child != parent else { return nil }
            return resolved[child]
        })
        return resolved.filter { linkedRoots.contains($0.value) }
    }

    public static func make(points: [CompositionMapPoint], routes: [SpatialRoute], mappings: [String: String]? = nil) -> [SpatialMarkerSeed] {
        let byObject = Dictionary(points.map { ($0.targetID, $0) }, uniquingKeysWith: { first, _ in first })
        let objects = points.map { point in
            let fallback = point.kind == "presence" ? "person" : point.kind == "entityLocation" ? "place" : "event"
            return SpatialMarkerSeed(id: point.id, objectID: point.targetID, title: point.title, subtitle: point.subtitle,
                coordinate: .init(latitude: point.latitude, longitude: point.longitude),
                assetID: SpatialMarkerAssets.resolve(kind: point.markerKind ?? point.kind, title: point.title, fallback: fallback, mappings: mappings).id,
                affinityID: point.affinityID, affinityTitle: point.affinityTitle)
        }
        return objects + routes.compactMap { route in
            guard let coordinate = route.coordinates.dropFirst().first else { return nil }
            let event = route.eventID.flatMap { byObject[$0] }
            return SpatialMarkerSeed(id: "route:" + route.id, routeID: route.relationID, title: route.title,
                subtitle: route.actorNames.joined(separator: "、") + " · " + route.placeNames.joined(separator: " → "),
                coordinate: coordinate, assetID: SpatialMarkerAssets.resolve(kind: route.kind, title: route.title, mappings: mappings).id,
                affinityID: route.affinityID ?? event?.affinityID, affinityTitle: route.affinityTitle ?? event?.affinityTitle)
        }
    }
}
