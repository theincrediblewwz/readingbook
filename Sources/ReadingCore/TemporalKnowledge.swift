import Foundation

public enum BookGenre: String, Codable, CaseIterable, Hashable, Sendable { case history, warfare, fiction, argument, textbook }

/// Reader-editable classification. It does not assert that a novel is history.
public struct BookProfile: Codable, Hashable, Sendable {
    public var genres: [BookGenre]
    public var customGenres: [String]
    public var entityTypeIDs: [String]
    public var locationTypeIDs: [String]
    public var methodIDs: [String]
    public var rendererIDs: [String]
    public var timeSystem: String?
    public var avoidsSpoilers: Bool
    public init(genres: [BookGenre] = [], customGenres: [String] = [], entityTypeIDs: [String] = [], locationTypeIDs: [String] = [], methodIDs: [String] = [], rendererIDs: [String] = [], timeSystem: String? = nil, avoidsSpoilers: Bool = true) {
        self.genres = genres; self.customGenres = customGenres; self.entityTypeIDs = entityTypeIDs; self.locationTypeIDs = locationTypeIDs
        self.methodIDs = methodIDs; self.rendererIDs = rendererIDs; self.timeSystem = timeSystem; self.avoidsSpoilers = avoidsSpoilers
    }
}

public enum KnowledgeAssertion: String, Codable, Hashable, Sendable { case explicit, inferred, unknown }
public enum TemporalPrecision: String, Codable, Hashable, Sendable { case unknown, year, month, day, narrative }
public enum TemporalUncertainty: String, Codable, Hashable, Sendable { case exact, approximate, disputed, unknown }
public enum TemporalExtentKind: String, Codable, Hashable, Sendable { case point, interval, uncertainRange }

/// Numeric dates are comparable only inside the same explicitly named calendar.
/// Source labels such as a reign year remain in sourceText; no conversion is inferred.
public struct TemporalDate: Codable, Hashable, Sendable {
    public var year: Int
    public var month: Int?
    public var day: Int?
    public init(year: Int, month: Int? = nil, day: Int? = nil) { self.year = year; self.month = month; self.day = day }
}

public struct TemporalExtent: Codable, Hashable, Sendable {
    public var sourceText: String
    public var calendar: String?
    public var start: TemporalDate?
    public var end: TemporalDate?
    public var precision: TemporalPrecision
    public var uncertainty: TemporalUncertainty
    public var kind: TemporalExtentKind
    public var narrativeStart: Int?
    public var narrativeEnd: Int?
    public init(sourceText: String = "", calendar: String? = nil, start: TemporalDate? = nil, end: TemporalDate? = nil, precision: TemporalPrecision = .unknown, uncertainty: TemporalUncertainty = .unknown, kind: TemporalExtentKind = .point, narrativeStart: Int? = nil, narrativeEnd: Int? = nil) {
        self.sourceText = sourceText; self.calendar = calendar; self.start = start; self.end = end
        self.precision = precision; self.uncertainty = uncertainty; self.kind = kind
        self.narrativeStart = narrativeStart; self.narrativeEnd = narrativeEnd
    }
}

public enum TemporalQueryPoint: Hashable, Sendable {
    case date(TemporalDate, calendar: String)
    case narrative(Int)
}
public enum TemporalMatch: String, Codable, Hashable, Sendable { case matches, possible, unknown, outside }

/// Participation alone never grants a location. Only an independently anchored
/// explicit presence can become a footprint; no event participant × place join.
public struct EntityPresence: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var entityID: String
    public var placeID: String?
    public var eventID: String?
    public var extent: TemporalExtent
    public var action: String
    public var sourceAnchorIDs: [String]
    public var assertion: KnowledgeAssertion
    public var explanation: String
    public init(id: String, entityID: String, placeID: String? = nil, eventID: String? = nil, extent: TemporalExtent = TemporalExtent(), action: String, sourceAnchorIDs: [String], assertion: KnowledgeAssertion = .unknown, explanation: String = "") {
        self.id = id; self.entityID = entityID; self.placeID = placeID; self.eventID = eventID; self.extent = extent; self.action = action
        self.sourceAnchorIDs = sourceAnchorIDs; self.assertion = assertion; self.explanation = explanation
    }
}

public struct Participation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var entityID: String
    public var eventID: String
    public var role: String
    public var extent: TemporalExtent?
    public var sourceAnchorIDs: [String]
    public var assertion: KnowledgeAssertion
    public var explanation: String
    public init(id: String, entityID: String, eventID: String, role: String, extent: TemporalExtent? = nil, sourceAnchorIDs: [String], assertion: KnowledgeAssertion = .unknown, explanation: String = "") {
        self.id = id; self.entityID = entityID; self.eventID = eventID; self.role = role; self.extent = extent
        self.sourceAnchorIDs = sourceAnchorIDs; self.assertion = assertion; self.explanation = explanation
    }
}

public struct EventTemporalMetadata: Codable, Identifiable, Hashable, Sendable {
    public var id: String { eventID }
    public var eventID: String
    public var typeID: String?
    public var kind: String
    public var parentEventID: String?
    public var phaseOrder: Int?
    public var extent: TemporalExtent?
    public var sourceAnchorIDs: [String]
    public var assertion: KnowledgeAssertion
    public var explanation: String
    public init(eventID: String, typeID: String? = nil, kind: String = "event", parentEventID: String? = nil, phaseOrder: Int? = nil, extent: TemporalExtent? = nil, sourceAnchorIDs: [String], assertion: KnowledgeAssertion = .unknown, explanation: String = "") {
        self.eventID = eventID; self.typeID = typeID; self.kind = kind; self.parentEventID = parentEventID; self.phaseOrder = phaseOrder; self.extent = extent
        self.sourceAnchorIDs = sourceAnchorIDs; self.assertion = assertion; self.explanation = explanation
    }
}

/// Multiple disjoint validity intervals may name the same knowledge relation.
public struct RelationTemporalMetadata: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var relationID: String
    public var validity: TemporalExtent
    public var sourceAnchorIDs: [String]
    public var assertion: KnowledgeAssertion
    public var explanation: String
    public init(id: String, relationID: String, validity: TemporalExtent, sourceAnchorIDs: [String], assertion: KnowledgeAssertion = .unknown, explanation: String = "") {
        self.id = id; self.relationID = relationID; self.validity = validity; self.sourceAnchorIDs = sourceAnchorIDs; self.assertion = assertion; self.explanation = explanation
    }
}

/// Optional sidecar metadata. Legacy entities/events/relations and their IDs stay
/// canonical; simply opening an old book never synthesizes these records.
public struct TemporalKnowledgeState: Codable, Hashable, Sendable {
    public var schemaVersion: Int = 1
    public var profile: BookProfile?
    public var anchors: [SourceAnchor]
    public var presences: [EntityPresence]
    public var participations: [Participation]
    public var eventMetadata: [EventTemporalMetadata]
    public var relationMetadata: [RelationTemporalMetadata]
    public init(profile: BookProfile? = nil, anchors: [SourceAnchor] = [], presences: [EntityPresence] = [], participations: [Participation] = [], eventMetadata: [EventTemporalMetadata] = [], relationMetadata: [RelationTemporalMetadata] = []) {
        self.profile = profile; self.anchors = anchors; self.presences = presences; self.participations = participations
        self.eventMetadata = eventMetadata; self.relationMetadata = relationMetadata
    }
}

public enum TypedObjectKind: String, Codable, Hashable, Sendable { case entity, event, document }
public struct TypedObject: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var typeID: String
    public var kind: TypedObjectKind
    public var name: String
    public var summary: String
    public var aliases: [String]
    public var fields: [String: String]
    public var latitude: Double?
    public var longitude: Double?
    public var locationNote: String?
    public var references: [String: [String]]
    public var withheldReferenceCount: Int
    public var evidence: [Evidence]
    public var sourceAnchorIDs: [String]
    public var temporalExtent: TemporalExtent?
    public var assertion: KnowledgeAssertion?
    /// Content hash of the complete read adapter, not an invented persisted revision.
    public var version: String
}

/// A spoiler boundary is explicit caller policy, not inferred from processed
/// coverage. All provenance of a returned summary must lie inside the whitelist.
public struct KnowledgeReadBoundary: Hashable, Sendable {
    public var allowedUnitIDs: Set<String>?
    public init(allowedUnitIDs: Set<String>) { self.allowedUnitIDs = allowedUnitIDs }
    private init() { allowedUnitIDs = nil }
    public static var all: KnowledgeReadBoundary { KnowledgeReadBoundary() }
    public static func processed(in project: BookProject) -> KnowledgeReadBoundary {
        KnowledgeReadBoundary(allowedUnitIDs: Set(project.units.filter { project.coverage[$0.id]?.status == .completed }.map(\.id)))
    }
    /// This is a reader-selected source-order cutoff, not proof all earlier pages were read.
    public static func throughSourceUnit(_ unitID: String, in project: BookProject) throws -> KnowledgeReadBoundary {
        guard let unit = project.units.first(where: { $0.id == unitID }) else { throw ReadingError.invalid("剧透边界引用了不存在的原文单元。") }
        return KnowledgeReadBoundary(allowedUnitIDs: Set(project.units.filter { $0.order <= unit.order }.map(\.id)))
    }
}

public struct TemporalEventSnapshot: Codable, Hashable, Sendable {
    public var object: TypedObject
    public var metadata: EventTemporalMetadata?
    public var extent: TemporalExtent
    public var match: TemporalMatch
    public var participations: [Participation]
    public var presences: [EntityPresence]
    public var participantMatch: TemporalMatch?
}
public struct TemporalRelationSnapshot: Codable, Hashable, Sendable {
    public var relation: KnowledgeRelation
    public var metadata: RelationTemporalMetadata?
    public var match: TemporalMatch
}
public struct EntityTimeSnapshot: Codable, Sendable {
    public var object: TypedObject?
    public var presences: [EntityPresence]
    public var uncertainPresences: [EntityPresence]
    public var footprints: [EntityPresence]
    public var participations: [Participation]
    public var uncertainParticipations: [Participation]
    public var events: [TemporalEventSnapshot]
    public var relations: [TemporalRelationSnapshot]
}

public enum TemporalKnowledgeRuntime {
    public static func objects(in project: BookProject, boundary: KnowledgeReadBoundary) throws -> [TypedObject] {
        let anchors = anchorIndex(in: project)
        let referenceIDs = visibleReferenceIDs(in: project, boundary: boundary)
        let metadata = Dictionary((project.temporalKnowledge?.eventMetadata ?? []).map { ($0.eventID, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TypedObject] = []
        for entity in project.entities where admits(entity.evidence, boundary: boundary) {
            result.append(try adapt(entity))
        }
        for event in project.events where admits(event.evidence, boundary: boundary) {
            result.append(try adapt(event, metadata: metadata[event.id], anchors: anchors, boundary: boundary, referenceIDs: referenceIDs))
        }
        for document in project.activeDocuments where admits(document.evidence, boundary: boundary) {
            result.append(try adapt(document, referenceIDs: referenceIDs))
        }
        return result
    }

    public static func object(id: String, in project: BookProject, boundary: KnowledgeReadBoundary) throws -> TypedObject? {
        if let entity = project.entities.first(where: { $0.id == id }), admits(entity.evidence, boundary: boundary) { return try adapt(entity) }
        if let event = project.events.first(where: { $0.id == id }), admits(event.evidence, boundary: boundary) {
            return try adapt(event, metadata: project.temporalKnowledge?.eventMetadata.first { $0.eventID == id }, anchors: anchorIndex(in: project), boundary: boundary, referenceIDs: visibleReferenceIDs(in: project, boundary: boundary))
        }
        if let document = project.activeDocuments.first(where: { $0.id == id }), admits(document.evidence, boundary: boundary) { return try adapt(document, referenceIDs: visibleReferenceIDs(in: project, boundary: boundary)) }
        return nil
    }

    public static func events(in project: BookProject, entityID: String? = nil, placeID: String? = nil, at point: TemporalQueryPoint? = nil, boundary: KnowledgeReadBoundary) throws -> [TemporalEventSnapshot] {
        try validate(point: point)
        let anchors = anchorIndex(in: project)
        let referenceIDs = visibleReferenceIDs(in: project, boundary: boundary)
        if let entityID, let referenceIDs, !referenceIDs.contains(entityID) { return [] }
        if let placeID, let referenceIDs, !referenceIDs.contains(placeID) { return [] }
        let allMetadata = Dictionary((project.temporalKnowledge?.eventMetadata ?? []).map { ($0.eventID, $0) }, uniquingKeysWith: { first, _ in first })
        let participationByEvent = Dictionary(grouping: (project.temporalKnowledge?.participations ?? []).filter { $0.entityID == entityID && admits($0.sourceAnchorIDs, anchors: anchors, boundary: boundary) }, by: \.eventID)
        let presenceByEvent = Dictionary(grouping: (project.temporalKnowledge?.presences ?? []).filter { $0.entityID == entityID && $0.eventID != nil && ($0.placeID.map { referenceIDs?.contains($0) ?? true } ?? true) && admits($0.sourceAnchorIDs, anchors: anchors, boundary: boundary) }, by: { $0.eventID ?? "" })
        return try project.events.compactMap { event in
            guard admits(event.evidence, boundary: boundary), placeID.map({ event.placeIDs.contains($0) }) ?? true else { return nil }
            var participations: [Participation] = [], presences: [EntityPresence] = [], participantMatch: TemporalMatch?
            if let entityID {
                let participation = participationByEvent[event.id] ?? [], presence = presenceByEvent[event.id] ?? []
                if !participation.isEmpty || !presence.isEmpty {
                    participations = participation.filter { $0.extent.map { match($0, at: point) } != .outside }
                    presences = presence.filter { match($0.extent, at: point) != .outside }
                    // A broad campaign date cannot override a person's narrower
                    // participation interval, including legacy participant arrays.
                    guard !participations.isEmpty || !presences.isEmpty else { return nil }
                    let states = participations.map { value in value.extent.map { assertedMatch($0, assertion: value.assertion, at: point) } ?? .unknown }
                        + presences.map { assertedMatch($0.extent, assertion: $0.assertion, at: point) }
                    participantMatch = states.contains(.matches) ? .matches : (states.contains(.possible) ? .possible : .unknown)
                } else {
                    guard event.participantIDs.contains(entityID) else { return nil }
                    participantMatch = .unknown
                }
            }
            let metadata = visibleMetadata(allMetadata[event.id], anchors: anchors, boundary: boundary, referenceIDs: referenceIDs)
            let extent = metadata?.extent ?? legacyExtent(event)
            var state = assertedMatch(extent, assertion: metadata?.assertion, at: point)
            guard state != .outside else { return nil }
            if point != nil, let participantMatch {
                if participantMatch == .unknown { state = .unknown }
                else if participantMatch == .possible, state == .matches { state = .possible }
            }
            let object = try adapt(event, metadata: metadata, anchors: anchors, boundary: boundary, referenceIDs: referenceIDs)
            return TemporalEventSnapshot(object: object, metadata: metadata, extent: extent, match: state, participations: participations, presences: presences, participantMatch: participantMatch)
        }
    }

    public static func relations(objectID: String, in project: BookProject, at point: TemporalQueryPoint? = nil, boundary: KnowledgeReadBoundary) throws -> [TemporalRelationSnapshot] {
        try relationSnapshots(objectID: objectID, in: project, at: point, boundary: boundary)
    }

    public static func relations(in project: BookProject, at point: TemporalQueryPoint? = nil, boundary: KnowledgeReadBoundary) throws -> [TemporalRelationSnapshot] {
        try relationSnapshots(objectID: nil, in: project, at: point, boundary: boundary)
    }

    private static func relationSnapshots(objectID: String?, in project: BookProject, at point: TemporalQueryPoint?, boundary: KnowledgeReadBoundary) throws -> [TemporalRelationSnapshot] {
        try validate(point: point)
        let anchors = anchorIndex(in: project)
        let visibleIDs = visibleObjectIDs(in: project, boundary: boundary)
        let metadata = Dictionary(grouping: project.temporalKnowledge?.relationMetadata ?? [], by: \.relationID)
        return project.relations.filter { relation in (objectID.map { relation.fromID == $0 || relation.toID == $0 } ?? true) && visibleIDs.contains(relation.fromID) && visibleIDs.contains(relation.toID) && admits(relation.evidence, boundary: boundary) }.flatMap { relation -> [TemporalRelationSnapshot] in
            let all = metadata[relation.id] ?? []
            let visible = all.filter { admits($0.sourceAnchorIDs, anchors: anchors, boundary: boundary) }
            if visible.isEmpty {
                // Do not expose a future validity assertion as a timeless known relation.
                return all.isEmpty ? [TemporalRelationSnapshot(relation: relation, metadata: nil, match: .unknown)] : []
            }
            return visible.compactMap { metadata in
                let state = assertedMatch(metadata.validity, assertion: metadata.assertion, at: point)
                return state == .outside ? nil : TemporalRelationSnapshot(relation: relation, metadata: metadata, match: state)
            }
        }
    }

    public static func entitySnapshot(entityID: String, in project: BookProject, at point: TemporalQueryPoint? = nil, boundary: KnowledgeReadBoundary) throws -> EntityTimeSnapshot {
        try validate(point: point)
        let anchors = anchorIndex(in: project)
        let visibleIDs = visibleObjectIDs(in: project, boundary: boundary)
        let adaptedObject = try object(id: entityID, in: project, boundary: boundary)
        let entity = adaptedObject?.kind == .entity ? adaptedObject : nil
        guard entity != nil else { return EntityTimeSnapshot(object: nil, presences: [], uncertainPresences: [], footprints: [], participations: [], uncertainParticipations: [], events: [], relations: []) }
        let presences = (project.temporalKnowledge?.presences ?? []).filter {
            $0.entityID == entityID && ($0.placeID.map(visibleIDs.contains) ?? true) && ($0.eventID.map(visibleIDs.contains) ?? true) && admits($0.sourceAnchorIDs, anchors: anchors, boundary: boundary)
        }
        let exact = presences.filter { match($0.extent, at: point) == .matches && $0.assertion == .explicit }
        let exactIDs = Set(exact.map(\.id))
        let uncertain = presences.filter { match($0.extent, at: point) != .outside && !exactIDs.contains($0.id) }
        let participants = (project.temporalKnowledge?.participations ?? []).filter { $0.entityID == entityID && visibleIDs.contains($0.eventID) && admits($0.sourceAnchorIDs, anchors: anchors, boundary: boundary) }
        let exactParticipants = participants.filter { $0.extent.map { match($0, at: point) } == .matches && $0.assertion == .explicit }
        let exactParticipantIDs = Set(exactParticipants.map(\.id))
        let uncertainParticipants = participants.filter { $0.extent.map { match($0, at: point) } != .outside && !exactParticipantIDs.contains($0.id) }
        return EntityTimeSnapshot(object: entity, presences: exact, uncertainPresences: uncertain,
            footprints: (point == nil ? presences : exact).filter { $0.assertion == .explicit && $0.placeID != nil }, participations: exactParticipants, uncertainParticipations: uncertainParticipants,
            events: try events(in: project, entityID: entityID, at: point, boundary: boundary), relations: try relations(objectID: entityID, in: project, at: point, boundary: boundary))
    }

    public static func match(_ extent: TemporalExtent, at point: TemporalQueryPoint?) -> TemporalMatch {
        guard let point else { return extent.precision == .unknown ? .unknown : (extent.uncertainty == .exact ? .matches : .possible) }
        switch point {
        case .narrative(let value):
            guard let start = extent.narrativeStart else { return .unknown }
            if value < start { return .outside }
            if let end = extent.narrativeEnd {
                if value > end { return .outside }
            } else if extent.kind != .interval, value > start { return .outside }
            if extent.kind == .uncertainRange { return .possible }
            return extent.uncertainty == .exact ? .matches : .possible
        case .date(let date, let calendar):
            guard extent.calendar == calendar, extent.precision != .unknown, extent.precision != .narrative else { return .unknown }
            guard extent.start != nil || extent.end != nil else { return .unknown }
            let lower = extent.start.map { dateKey($0, upper: false) }
            let upper = (extent.end ?? (extent.kind == .interval ? nil : extent.start)).map { dateKey($0, upper: true) }
            let queryLower = dateKey(date, upper: false), queryUpper = dateKey(date, upper: true)
            if let lower, queryUpper < lower { return .outside }
            if let upper, queryLower > upper { return .outside }
            let fineQuery = date.day != nil ? 3 : (date.month != nil ? 2 : 1)
            let precision = extent.precision == .day ? 3 : (extent.precision == .month ? 2 : 1)
            if extent.kind == .uncertainRange || extent.uncertainty != .exact || fineQuery > precision { return .possible }
            return .matches
        }
    }

    private struct DateKey: Comparable {
        var year: Int; var month: Int; var day: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            if lhs.month != rhs.month { return lhs.month < rhs.month }
            return lhs.day < rhs.day
        }
    }
    private static func dateKey(_ date: TemporalDate, upper: Bool) -> DateKey {
        // Coarse bounds cover supported ordinal values in custom calendars;
        // they are comparison sentinels, never fabricated display dates.
        DateKey(year: date.year, month: date.month ?? (upper ? 64 : 1), day: date.day ?? (upper ? 128 : 1))
    }
    private static func legacyExtent(_ event: KnowledgeEvent) -> TemporalExtent {
        // Old years have no named calendar or precision contract. Preserve them
        // for display without claiming they match a newly named calendar.
        TemporalExtent(sourceText: event.dateText, start: event.startYear.map { TemporalDate(year: $0) }, end: event.endYear.map { TemporalDate(year: $0) }, precision: event.startYear == nil && event.endYear == nil ? .unknown : .year, uncertainty: .unknown, kind: .interval)
    }
    private static func versioned(_ object: TypedObject) throws -> TypedObject {
        var object = object; object.version = ""; let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        object.version = try BookImporter.sha256(encoder.encode(object)); return object
    }
    private static func adapt(_ entity: KnowledgeEntity) throws -> TypedObject {
        return try versioned(TypedObject(id: entity.id, typeID: entity.typeID, kind: .entity, name: entity.name, summary: entity.summary, aliases: entity.aliases, fields: entity.properties,
            latitude: entity.latitude, longitude: entity.longitude, locationNote: entity.locationNote,
            references: [:], withheldReferenceCount: 0, evidence: entity.evidence, sourceAnchorIDs: [], temporalExtent: nil, assertion: nil, version: ""))
    }
    private static func adapt(_ event: KnowledgeEvent, metadata: EventTemporalMetadata?, anchors: [String: SourceAnchor], boundary: KnowledgeReadBoundary, referenceIDs: Set<String>?) throws -> TypedObject {
        // A hidden extension must not leak parent/phase/type information.
        let visible = visibleMetadata(metadata, anchors: anchors, boundary: boundary, referenceIDs: referenceIDs)
        var references = ["places": event.placeIDs, "participants": event.participantIDs]
        if let parent = visible?.parentEventID { references["parentEvent"] = [parent] }
        let total = references.values.reduce(0) { $0 + $1.count }
        if let referenceIDs { references = references.mapValues { $0.filter(referenceIDs.contains) } }
        var fields = ["dateText": event.dateText]
        if let kind = visible?.kind { fields["kind"] = kind }
        if let order = visible?.phaseOrder { fields["phaseOrder"] = String(order) }
        return try versioned(TypedObject(id: event.id, typeID: visible?.typeID ?? "event", kind: .event, name: event.name, summary: event.summary, aliases: [], fields: fields,
            latitude: nil, longitude: nil, locationNote: nil,
            references: references, withheldReferenceCount: total - references.values.reduce(0) { $0 + $1.count }, evidence: event.evidence, sourceAnchorIDs: visible?.sourceAnchorIDs ?? [], temporalExtent: visible?.extent ?? legacyExtent(event), assertion: visible?.assertion, version: ""))
    }
    private static func adapt(_ document: DocumentRecord, referenceIDs: Set<String>?) throws -> TypedObject {
        // A catalogue only: this never reads or copies the Markdown body.
        let links = document.linkedIDs.filter { referenceIDs?.contains($0) ?? true }
        return try versioned(TypedObject(id: document.id, typeID: "document", kind: .document, name: document.title, summary: "", aliases: [], fields: ["origin": document.origin],
            latitude: nil, longitude: nil, locationNote: nil,
            references: ["linkedObjects": links], withheldReferenceCount: document.linkedIDs.count - links.count, evidence: document.evidence, sourceAnchorIDs: [], temporalExtent: nil, assertion: nil, version: ""))
    }
    private static func visibleObjectIDs(in project: BookProject, boundary: KnowledgeReadBoundary) -> Set<String> {
        Set(project.entities.filter { admits($0.evidence, boundary: boundary) }.map(\.id)
            + project.events.filter { admits($0.evidence, boundary: boundary) }.map(\.id)
            + project.activeDocuments.filter { admits($0.evidence, boundary: boundary) }.map(\.id))
    }
    private static func visibleReferenceIDs(in project: BookProject, boundary: KnowledgeReadBoundary) -> Set<String>? {
        guard let allowed = boundary.allowedUnitIDs else { return nil }
        let insights = project.insights.filter { !$0.unitIDs.isEmpty && Set($0.unitIDs).isSubset(of: allowed) }.map(\.id)
        return visibleObjectIDs(in: project, boundary: boundary).union(allowed).union(insights)
    }
    private static func visibleMetadata(_ metadata: EventTemporalMetadata?, anchors: [String: SourceAnchor], boundary: KnowledgeReadBoundary, referenceIDs: Set<String>?) -> EventTemporalMetadata? {
        guard let metadata, admits(metadata.sourceAnchorIDs, anchors: anchors, boundary: boundary),
              metadata.parentEventID.map({ referenceIDs?.contains($0) ?? true }) ?? true else { return nil }
        return metadata
    }
    private static func assertedMatch(_ extent: TemporalExtent, assertion: KnowledgeAssertion?, at point: TemporalQueryPoint?) -> TemporalMatch {
        let result = match(extent, at: point)
        guard result != .outside else { return result }
        if assertion == .unknown { return .unknown }
        return assertion == .inferred && result == .matches ? .possible : result
    }
    private static func anchorIndex(in project: BookProject) -> [String: SourceAnchor] {
        Dictionary(((project.readingExperience?.anchors ?? []) + (project.temporalKnowledge?.anchors ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private static func admits(_ evidence: [Evidence], boundary: KnowledgeReadBoundary) -> Bool {
        guard let allowed = boundary.allowedUnitIDs else { return true }
        return !evidence.isEmpty && evidence.allSatisfy { allowed.contains($0.unitID) }
    }
    private static func admits(_ ids: [String], anchors: [String: SourceAnchor], boundary: KnowledgeReadBoundary) -> Bool {
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { id in anchors[id].map { admits([Evidence(unitID: $0.unitID, quote: $0.quote)], boundary: boundary) } ?? false }
    }
    private static func validate(point: TemporalQueryPoint?) throws {
        switch point {
        case .date(let date, let calendar): try validateDate(date, calendar: calendar); try text(calendar, maximum: 80)
        case .narrative(let order): guard (0...1_000_000_000).contains(order) else { throw invalid("叙事位置超出范围。") }
        case nil: break
        }
    }
}

public extension TemporalKnowledgeRuntime {
    /// Called by the package writer/loader. No state means no migration and no
    /// new restrictions on old records that predate the temporal contract.
    static func validateStoredState(in project: BookProject) throws {
        guard let state = project.temporalKnowledge else { return }
        guard state.schemaVersion == 1 else { throw invalid("不支持的时态知识版本。") }
        let entities = Dictionary(project.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let events = Set(project.events.map(\.id)), relations = Set(project.relations.map(\.id))
        let types = Set(project.types.map(\.id)), methods = Set(project.methods.map(\.id))
        try ids(state.anchors.map(\.id), maximum: 100_000)
        try ids(state.presences.map(\.id), maximum: 100_000)
        try ids(state.participations.map(\.id), maximum: 100_000)
        try ids(state.eventMetadata.map(\.id), maximum: 100_000)
        try ids(state.relationMetadata.map(\.id), maximum: 200_000)
        if let profile = state.profile { try validateProfile(profile, typeIDs: types, methodIDs: methods) }
        var anchors = Dictionary((project.readingExperience?.anchors ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolvedAnchorIDs = Set<String>()
        for anchor in state.anchors {
            if let old = anchors[anchor.id], old != anchor { throw invalid("同一原文锚点 ID 对应不同内容。") }
            guard let unit = units[anchor.unitID] else { throw invalid("出现记录的原文单元不存在。") }
            // Resolve in a one-unit view to avoid a full-book linear lookup for
            // every anchor. This preserves the real book ID/source fingerprint.
            var scoped = project; scoped.units = [unit]
            _ = try ReadingExperienceRuntime.resolve(anchor, in: scoped)
            anchors[anchor.id] = anchor
            resolvedAnchorIDs.insert(anchor.id)
        }
        func provenance(_ ids: [String], _ assertion: KnowledgeAssertion, _ explanation: String, extent: TemporalExtent? = nil) throws {
            try Self.ids(ids, maximum: 64)
            guard !ids.isEmpty, ids.allSatisfy({ anchors[$0] != nil }) else { throw invalid("时态事实须引用本书可解析的原文锚点。") }
            for id in ids where !resolvedAnchorIDs.contains(id) {
                guard let anchor = anchors[id], let unit = units[anchor.unitID] else { throw invalid("时态事实的原文锚点无法解析。") }
                var scoped = project; scoped.units = [unit]
                _ = try ReadingExperienceRuntime.resolve(anchor, in: scoped)
                resolvedAnchorIDs.insert(id)
            }
            try text(explanation, maximum: 4000, allowEmpty: assertion == .explicit)
            if let label = extent?.sourceText, !label.isEmpty {
                guard ids.contains(where: { anchors[$0]?.quote.range(of: label, options: .literal) != nil }) else { throw invalid("原文时间表述必须确实出现在所引用的原文锚点中。") }
            }
        }
        for presence in state.presences {
            guard entities[presence.entityID] != nil,
                  presence.eventID.map(events.contains) ?? true else { throw invalid("出现记录引用了不存在的实体或事件。") }
            if let placeID = presence.placeID {
                guard let place = entities[placeID], placeID != presence.entityID,
                      place.typeID == "place" || (state.profile?.locationTypeIDs.contains(place.typeID) ?? false) else { throw invalid("出现地点须引用已声明的地点实体，不能把任意参与者当地点。") }
            }
            try text(presence.action, maximum: 4000)
            try validateExtent(presence.extent)
            try provenance(presence.sourceAnchorIDs, presence.assertion, presence.explanation, extent: presence.extent)
        }
        for participation in state.participations {
            guard entities[participation.entityID] != nil, events.contains(participation.eventID) else { throw invalid("参与记录引用了不存在的实体或事件。") }
            try text(participation.role, maximum: 400)
            if let extent = participation.extent { try validateExtent(extent) }
            try provenance(participation.sourceAnchorIDs, participation.assertion, participation.explanation, extent: participation.extent)
        }
        var parents: [String: String] = [:]
        for event in state.eventMetadata {
            guard events.contains(event.eventID), event.typeID.map(types.contains) ?? true else { throw invalid("事件扩展引用了不存在的事件或类型。") }
            try text(event.kind, maximum: 80)
            if let parent = event.parentEventID {
                guard events.contains(parent), parent != event.eventID else { throw invalid("战役阶段的父事件不存在或指向自身。") }
                parents[event.eventID] = parent
            }
            if let order = event.phaseOrder {
                guard event.parentEventID != nil, (0...1_000_000).contains(order) else { throw invalid("阶段顺序须属于父事件且在合法范围内。") }
            }
            if let extent = event.extent { try validateExtent(extent) }
            try provenance(event.sourceAnchorIDs, event.assertion, event.explanation, extent: event.extent)
        }
        // Iterative cycle detection remains bounded for very deep event trees.
        var completed = Set<String>()
        for id in parents.keys where !completed.contains(id) {
            var chain = Set<String>(), current = id
            while !completed.contains(current), let next = parents[current] {
                guard chain.insert(current).inserted else { throw invalid("战役与阶段的父事件不能成环。") }
                current = next
            }
            completed.formUnion(chain)
        }
        for relation in state.relationMetadata {
            guard relations.contains(relation.relationID) else { throw invalid("关系有效期引用了不存在的关系。") }
            try validateExtent(relation.validity)
            try provenance(relation.sourceAnchorIDs, relation.assertion, relation.explanation, extent: relation.validity)
        }
    }

    static func validateExtent(_ extent: TemporalExtent) throws {
        try text(extent.sourceText, maximum: 4000, allowEmpty: true)
        if let calendar = extent.calendar { try text(calendar, maximum: 80) }
        if extent.precision != .unknown { try text(extent.sourceText, maximum: 4000) }
        for date in [extent.start, extent.end].compactMap({ $0 }) { try validateDate(date, calendar: extent.calendar) }
        if let start = extent.start, let end = extent.end, dateKey(start, upper: false) > dateKey(end, upper: true) { throw invalid("时间范围的结束早于开始。") }
        for order in [extent.narrativeStart, extent.narrativeEnd].compactMap({ $0 }) {
            guard (0...1_000_000_000).contains(order) else { throw invalid("叙事次序超出范围。") }
        }
        if let end = extent.narrativeEnd {
            guard let start = extent.narrativeStart, end >= start else { throw invalid("叙事范围的结束早于开始或缺少起点。") }
        }
        switch extent.precision {
        case .unknown:
            guard extent.start == nil, extent.end == nil, extent.narrativeStart == nil, extent.narrativeEnd == nil,
                  extent.uncertainty == .unknown else { throw invalid("未知时间不能附带伪造的数字时间或精确性。") }
        case .narrative:
            guard extent.start == nil, extent.end == nil, extent.narrativeStart != nil else { throw invalid("叙事时间须有叙事位置，不能伪装成历法日期。") }
            if extent.kind == .uncertainRange {
                guard extent.narrativeEnd != nil, extent.uncertainty != .exact else { throw invalid("叙事不确定范围须有两端，且不能标成精确位置。") }
            }
        case .year, .month, .day:
            guard extent.calendar != nil, extent.start != nil || extent.end != nil else { throw invalid("数字时间须明确历法与至少一个边界。") }
            for date in [extent.start, extent.end].compactMap({ $0 }) {
                switch extent.precision {
                case .year: guard date.month == nil, date.day == nil else { throw invalid("年份精度不能保存月日。") }
                case .month: guard date.month != nil, date.day == nil else { throw invalid("月份精度须有月份且不能保存具体日。") }
                case .day: guard date.month != nil, date.day != nil else { throw invalid("日期精度须保留完整月日。") }
                default: break
                }
            }
            if extent.kind == .point {
                guard let start = extent.start, extent.end == nil || extent.end == start else { throw invalid("时间点不能包含不同的起止日期；请显式声明区间或不确定范围。") }
            }
            if extent.kind == .uncertainRange {
                guard extent.start != nil, extent.end != nil, extent.uncertainty != .exact else { throw invalid("不确定范围须有两端，且不能标成精确时间。") }
            }
        }
        if extent.kind == .point, let end = extent.narrativeEnd, end != extent.narrativeStart { throw invalid("叙事时间点不能包含一个区间。") }
    }

    private static func validateDate(_ date: TemporalDate, calendar: String? = nil) throws {
        guard (-1_000_000_000_000...1_000_000_000_000).contains(date.year),
              date.month.map({ (1...64).contains($0) }) ?? true,
              date.day.map({ (1...128).contains($0) }) ?? true,
              date.day == nil || date.month != nil else { throw invalid("日期数字或精度无效。") }
        if ["gregorian", "proleptic-gregorian"].contains(calendar ?? ""), let month = date.month, let day = date.day {
            guard month <= 12 else { throw invalid("公历月份不存在。") }
            let leap = date.year % 4 == 0 && (date.year % 100 != 0 || date.year % 400 == 0)
            let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard day <= lengths[month - 1] else { throw invalid("公历日期不存在。") }
        }
        if ["gregorian", "proleptic-gregorian"].contains(calendar ?? ""), let month = date.month, month > 12 { throw invalid("公历月份不存在。") }
    }
    static func validateProfile(_ profile: BookProfile, typeIDs: Set<String>, methodIDs: Set<String>) throws {
        guard profile.genres.count <= BookGenre.allCases.count, Set(profile.genres).count == profile.genres.count,
              profile.customGenres.count <= 16, Set(profile.customGenres.map { $0.lowercased() }).count == profile.customGenres.count else { throw invalid("书籍分类重复或过多。") }
        for genre in profile.customGenres { try text(genre, maximum: 80) }
        try ids(profile.entityTypeIDs, maximum: 128); try ids(profile.locationTypeIDs, maximum: 128)
        try ids(profile.methodIDs, maximum: 32); try ids(profile.rendererIDs, maximum: 32)
        guard Set(profile.entityTypeIDs + profile.locationTypeIDs).isSubset(of: typeIDs), Set(profile.methodIDs).isSubset(of: methodIDs) else { throw invalid("书籍分类引用了不存在的类型或读书法。") }
        if let calendar = profile.timeSystem { try text(calendar, maximum: 80) }
    }
    private static func ids(_ values: [String], maximum: Int) throws {
        guard values.count <= maximum, Set(values).count == values.count,
              values.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil }) else { throw invalid("记录标识重复、过多或格式错误。") }
    }
    private static func text(_ value: String, maximum: Int, allowEmpty: Bool = false) throws {
        guard value.count <= maximum, !value.contains("\0"), allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("文本为空、含空字符或超过长度限制。") }
    }
    private static func invalid(_ message: String) -> ReadingError { .invalid("时态知识：" + message) }
}
