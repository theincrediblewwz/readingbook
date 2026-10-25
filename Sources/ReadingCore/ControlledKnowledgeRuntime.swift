import Foundation

struct ControlledIdentityMap {
    var values: [String: String] = [:]
    let operationID: String
    let existingIDs: Set<String>
    init(operationID: String, project: BookProject) {
        self.operationID = operationID
        existingIDs = Set(project.types.map(\.id) + project.entities.map(\.id) + project.events.map(\.id) + project.relations.map(\.id)
            + project.documents.map(\.id) + project.nodes.map(\.id) + project.edges.map(\.id) + (project.graphGroups ?? []).map(\.id)
            + (project.temporalKnowledge?.anchors ?? []).map(\.id) + (project.readingExperience?.anchors ?? []).map(\.id))
    }
    mutating func register(_ clientID: String, kind: String, hostID: String? = nil) throws {
        try ControlledChangeCoding.requireID(clientID)
        guard values[clientID] == nil, !existingIDs.contains(clientID), values.count < 512 else { throw ControlledChangeError.invalid("客户端 ID 重复、与既有对象混淆或批次过大：\(clientID)") }
        let generated = try hostID ?? ("w-" + String(BookImporter.sha256(Data("\(operationID)|\(kind)|\(clientID)".utf8)).prefix(40)))
        values[clientID] = generated
    }
    func resolve(_ id: String) -> String { values[id] ?? id }
}

public enum ControlledKnowledgeRuntime {
    /// Automatic reading uses this pure transaction. The host supplies a stable
    /// operation ID; model arguments cannot disable receipts or choose authority.
    @discardableResult public static func apply(_ changes: ControlledKnowledgeChanges, to project: inout BookProject, allowedUnitIDs: Set<String>, operationID: String) throws -> [String: String] {
        try ControlledChangeCoding.requireID(operationID)
        try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project)
        var identity = ControlledIdentityMap(operationID: operationID, project: project), candidate = project
        try apply(changes, to: &candidate, allowedUnitIDs: allowedUnitIDs, requiresReceipts: true, identity: &identity)
        project = candidate
        return identity.values
    }

    static func apply(_ changes: ControlledKnowledgeChanges, to project: inout BookProject, allowedUnitIDs: Set<String>, requiresReceipts: Bool, identity: inout ControlledIdentityMap) throws {
        guard !allowedUnitIDs.isEmpty, allowedUnitIDs.isSubset(of: Set(project.units.map(\.id))), try ControlledChangeCoding.data(changes).count <= 262_144 else { throw ControlledChangeError.invalid("知识批次须有获准原文，且不能超过256 KiB。") }
        if requiresReceipts { try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project) }
        let counts = [(changes.types ?? []).count, (changes.entities ?? []).count, (changes.events ?? []).count, (changes.relations ?? []).count,
                      (changes.anchors ?? []).count, (changes.presences ?? []).count, (changes.participations ?? []).count, (changes.eventMetadata ?? []).count,
                      (changes.relationMetadata ?? []).count, (changes.layers ?? []).count, (changes.alignments ?? []).count]
        guard counts.allSatisfy({ $0 <= 128 }), counts.reduce(0, +) <= 256 else { throw ControlledChangeError.invalid("单个知识批次最多256项，每类最多128项。") }
        func registerNew(_ ids: [String]?, records: [String], existing: Set<String>, kind: String, map: inout ControlledIdentityMap) throws {
            let new = ids ?? []
            guard Set(records).count == records.count, Set(new).count == new.count, Set(new).isSubset(of: Set(records)), Set(new).isDisjoint(with: existing) else { throw ControlledChangeError.invalid("新增 ID 清单重复、越界或试图覆盖既有对象。") }
            for id in records { try ControlledChangeCoding.requireID(id); guard new.contains(id) || existing.contains(id) else { throw ControlledChangeError.invalid("未知对象须显式列入新增 ID 清单：\(id)") } }
            for id in new { try map.register(id, kind: kind) }
        }
        try registerNew(changes.newTypeIDs, records: (changes.types ?? []).map(\.id), existing: Set(project.types.map(\.id)), kind: "type", map: &identity)
        try registerNew(changes.newEntityIDs, records: (changes.entities ?? []).map(\.id), existing: Set(project.entities.map(\.id)), kind: "entity", map: &identity)
        try registerNew(changes.newEventIDs, records: (changes.events ?? []).map(\.id), existing: Set(project.events.map(\.id)), kind: "event", map: &identity)
        try registerNew(changes.newRelationIDs, records: (changes.relations ?? []).map(\.id), existing: Set(project.relations.map(\.id)), kind: "relation", map: &identity)
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func evidence(_ values: [Evidence]) throws {
            guard !values.isEmpty, values.count <= 64, Set(values).count == values.count else { throw ControlledChangeError.invalid("知识事实须有不重复的原文证据。") }
            for value in values {
                guard allowedUnitIDs.contains(value.unitID), let unit = units[value.unitID], !value.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      unit.text.range(of: value.quote, options: .literal) != nil else { throw ControlledChangeError.denied("知识证据超出获准原文或不能精确匹配。") }
            }
        }
        for var type in changes.types ?? [] {
            type.id = identity.resolve(type.id)
            try ControlledChangeCoding.text(type.name, maximum: 1600)
            guard type.fields.count <= 64, Set(type.fields.map(\.key)).count == type.fields.count else { throw ControlledChangeError.invalid("类型字段重复或过多。") }
            for field in type.fields { try ControlledChangeCoding.requireID(field.key); try ControlledChangeCoding.text(field.label, maximum: 1600) }
            if let old = project.types.first(where: { $0.id == type.id }) { guard old == type else { throw ControlledChangeError.conflict("不能覆盖已有类型定义。") } }
            else { project.types.append(type) }
        }
        for var entity in changes.entities ?? [] {
            entity.id = identity.resolve(entity.id); entity.typeID = identity.resolve(entity.typeID)
            guard let type = project.types.first(where: { $0.id == entity.typeID }), entity.properties.count <= 64,
                  Set(entity.properties.keys).isSubset(of: Set(type.fields.map(\.key))), entity.aliases.count <= 64,
                  (entity.latitude == nil) == (entity.longitude == nil), entity.latitude.map({ $0.isFinite && (-90...90).contains($0) }) ?? true,
                  entity.longitude.map({ $0.isFinite && (-180...180).contains($0) }) ?? true else { throw ControlledChangeError.invalid("实体类型、字段或坐标不合法。") }
            try ControlledChangeCoding.text(entity.name, maximum: 1600); try ControlledChangeCoding.text(entity.summary, maximum: 131_072, empty: true)
            try evidence(entity.evidence)
            if let index = project.entities.firstIndex(where: { $0.id == entity.id }) {
                var old = project.entities[index]
                guard old.typeID == entity.typeID, old.latitude == nil || entity.latitude == nil || old.latitude == entity.latitude,
                      old.longitude == nil || entity.longitude == nil || old.longitude == entity.longitude else { throw ControlledChangeError.conflict("不能改写已有实体类型或冲突坐标。") }
                old.aliases = union(old.aliases, entity.aliases + (old.name == entity.name ? [] : [entity.name]))
                old.summary = merge(old.summary, entity.summary)
                for (key, value) in entity.properties { old.properties[key] = merge(old.properties[key] ?? "", value) }
                old.latitude = old.latitude ?? entity.latitude; old.longitude = old.longitude ?? entity.longitude
                if let note = entity.locationNote { old.locationNote = merge(old.locationNote ?? "", note) }
                old.evidence = union(old.evidence, entity.evidence); project.entities[index] = old
                entity = old
            } else { project.entities.append(entity) }
            for field in type.fields where field.required {
                guard !(entity.properties[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ControlledChangeError.invalid("实体缺少类型要求的字段。") }
            }
        }
        for var event in changes.events ?? [] {
            event.id = identity.resolve(event.id); event.placeIDs = event.placeIDs.map(identity.resolve); event.participantIDs = event.participantIDs.map(identity.resolve)
            try ControlledChangeCoding.text(event.name, maximum: 1600); try evidence(event.evidence)
            let entityIDs = Set(project.entities.map(\.id))
            guard Set(event.placeIDs + event.participantIDs).isSubset(of: entityIDs), event.startYear.map({ (-1_000_000_000_000...1_000_000_000_000).contains($0) }) ?? true,
                  event.endYear.map({ (-1_000_000_000_000...1_000_000_000_000).contains($0) }) ?? true else { throw ControlledChangeError.invalid("事件实体引用或年份无效。") }
            if let index = project.events.firstIndex(where: { $0.id == event.id }) {
                var old = project.events[index]
                guard old.startYear == nil || event.startYear == nil || old.startYear == event.startYear,
                      old.endYear == nil || event.endYear == nil || old.endYear == event.endYear else { throw ControlledChangeError.conflict("事件年份与既有记录冲突。") }
                old.startYear = old.startYear ?? event.startYear; old.endYear = old.endYear ?? event.endYear
                old.summary = merge(old.summary, event.summary)
                if old.name != event.name { old.summary = merge(old.summary, "其他名称：" + event.name) }
                if event.dateText != "时间待考" { old.dateText = old.dateText == "时间待考" ? event.dateText : merge(old.dateText, event.dateText) }
                old.placeIDs = union(old.placeIDs, event.placeIDs); old.participantIDs = union(old.participantIDs, event.participantIDs)
                old.evidence = union(old.evidence, event.evidence); project.events[index] = old; event = old
            } else { project.events.append(event) }
            if let first = event.startYear, let last = event.endYear, first > last { throw ControlledChangeError.invalid("事件结束不能早于开始。") }
        }
        for var relation in changes.relations ?? [] {
            relation.id = identity.resolve(relation.id); relation.fromID = identity.resolve(relation.fromID); relation.toID = identity.resolve(relation.toID)
            try ControlledChangeCoding.text(relation.label, maximum: 1600); try evidence(relation.evidence)
            let targets = Set(project.entities.map(\.id)).union(project.events.map(\.id)).union(project.documents.map(\.id))
            guard targets.contains(relation.fromID), targets.contains(relation.toID) else { throw ControlledChangeError.invalid("知识关系引用了不存在的对象。") }
            if let index = project.relations.firstIndex(where: { $0.id == relation.id }) {
                guard project.relations[index].fromID == relation.fromID, project.relations[index].toID == relation.toID,
                      project.relations[index].label == relation.label else { throw ControlledChangeError.conflict("不能用同一关系 ID 改写含义或端点。") }
                project.relations[index].evidence = union(project.relations[index].evidence, relation.evidence)
            } else { project.relations.append(relation) }
        }
        let hasTemporal = !(changes.anchors ?? []).isEmpty || !(changes.presences ?? []).isEmpty || !(changes.participations ?? []).isEmpty || !(changes.eventMetadata ?? []).isEmpty || !(changes.relationMetadata ?? []).isEmpty
        var temporal = project.temporalKnowledge ?? TemporalKnowledgeState()
        for request in changes.anchors ?? [] {
            guard allowedUnitIDs.contains(request.unitID) else { throw ControlledChangeError.denied("新锚点超出获准原文。") }
            let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: request.unitID, quote: request.quote, prefix: request.prefix ?? "", suffix: request.suffix ?? "", in: project)
            try identity.register(request.clientID, kind: "anchor", hostID: anchor.id)
            try appendImmutable(anchor, to: &temporal.anchors)
        }
        func registerRecords<T: Identifiable>(_ records: [T], existing: [T], kind: String, map: inout ControlledIdentityMap) throws where T.ID == String {
            guard Set(records.map(\.id)).count == records.count else { throw ControlledChangeError.invalid("知识记录 ID 重复。") }
            let known = Set(existing.map(\.id))
            for record in records where !known.contains(record.id) { try map.register(record.id, kind: kind) }
        }
        try registerRecords(changes.presences ?? [], existing: temporal.presences, kind: "presence", map: &identity)
        try registerRecords(changes.participations ?? [], existing: temporal.participations, kind: "participation", map: &identity)
        try registerRecords(changes.relationMetadata ?? [], existing: temporal.relationMetadata, kind: "relation-time", map: &identity)
        for var presence in changes.presences ?? [] {
            presence.id = identity.resolve(presence.id); presence.entityID = identity.resolve(presence.entityID)
            presence.placeID = presence.placeID.map(identity.resolve); presence.eventID = presence.eventID.map(identity.resolve); presence.sourceAnchorIDs = presence.sourceAnchorIDs.map(identity.resolve)
            try appendImmutable(presence, to: &temporal.presences)
        }
        for var participation in changes.participations ?? [] {
            participation.id = identity.resolve(participation.id); participation.entityID = identity.resolve(participation.entityID)
            participation.eventID = identity.resolve(participation.eventID); participation.sourceAnchorIDs = participation.sourceAnchorIDs.map(identity.resolve)
            try appendImmutable(participation, to: &temporal.participations)
        }
        for var metadata in changes.eventMetadata ?? [] {
            metadata.eventID = identity.resolve(metadata.eventID); metadata.typeID = metadata.typeID.map(identity.resolve); metadata.parentEventID = metadata.parentEventID.map(identity.resolve)
            metadata.sourceAnchorIDs = metadata.sourceAnchorIDs.map(identity.resolve); try appendImmutable(metadata, to: &temporal.eventMetadata)
        }
        for var metadata in changes.relationMetadata ?? [] {
            metadata.id = identity.resolve(metadata.id); metadata.relationID = identity.resolve(metadata.relationID)
            metadata.sourceAnchorIDs = metadata.sourceAnchorIDs.map(identity.resolve); try appendImmutable(metadata, to: &temporal.relationMetadata)
        }
        let allAnchors = Dictionary(((project.readingExperience?.anchors ?? []) + temporal.anchors).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for ids in (changes.presences ?? []).map(\.sourceAnchorIDs) + (changes.participations ?? []).map(\.sourceAnchorIDs) + (changes.eventMetadata ?? []).map(\.sourceAnchorIDs) + (changes.relationMetadata ?? []).map(\.sourceAnchorIDs) {
            guard ids.allSatisfy({ id in allAnchors[identity.resolve(id)].map { allowedUnitIDs.contains($0.unitID) } ?? false }) else { throw ControlledChangeError.denied("新时态记录引用了获准原文之外的锚点。") }
        }
        if hasTemporal { project.temporalKnowledge = temporal }
        if !(changes.layers ?? []).isEmpty || !(changes.alignments ?? []).isEmpty {
            try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project)
            var experience = project.readingExperience ?? ReadingExperienceState()
            try registerRecords(changes.layers ?? [], existing: experience.layers, kind: "layer", map: &identity)
            try registerRecords(changes.alignments ?? [], existing: experience.alignments, kind: "alignment", map: &identity)
            for var layer in changes.layers ?? [] {
                layer.id = identity.resolve(layer.id); layer.sourceAnchorIDs = layer.sourceAnchorIDs.map(identity.resolve); layer.sourceLabel = "AI 生成 · 待核对"
                for id in layer.sourceAnchorIDs { guard let anchor = allAnchors[id] else { throw ControlledChangeError.invalid("释义缺少真实原文锚点。") }; try appendImmutable(anchor, to: &experience.anchors) }
                try appendImmutable(layer, to: &experience.layers)
            }
            for var alignment in changes.alignments ?? [] {
                alignment.id = identity.resolve(alignment.id); alignment.sourceAnchorIDs = alignment.sourceAnchorIDs.map(identity.resolve); alignment.status = "needs-review"
                for id in alignment.sourceAnchorIDs { guard let anchor = allAnchors[id] else { throw ControlledChangeError.invalid("资料对读缺少真实原文锚点。") }; try appendImmutable(anchor, to: &experience.anchors) }
                try appendImmutable(alignment, to: &experience.alignments)
            }
            try ReadingExperienceTools.validateTransition(from: project.readingExperience, to: experience, allowedUnitIDs: allowedUnitIDs, in: project)
            project.readingExperience = experience
        }
        try TemporalKnowledgeRuntime.validateStoredState(in: project)
    }

    static func appendImmutable<T: Codable & Identifiable>(_ value: T, to values: inout [T]) throws where T.ID == String {
        if let old = values.first(where: { $0.id == value.id }) {
            guard try ControlledChangeCoding.data(old) == ControlledChangeCoding.data(value) else { throw ControlledChangeError.conflict("不能改写已有知识记录：\(value.id)") }
        } else { values.append(value) }
    }
    private static func union<T: Hashable>(_ first: [T], _ second: [T]) -> [T] { var seen = Set(first); return first + second.filter { seen.insert($0).inserted } }
    private static func merge(_ first: String, _ second: String) -> String {
        if second.isEmpty || first == second || ("\n\n" + first + "\n\n").contains("\n\n" + second + "\n\n") { return first }
        return first.isEmpty ? second : first + "\n\n" + second
    }
}
