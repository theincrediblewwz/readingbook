import Foundation

/// Ordinary removal keeps active arrays valid and retains only its exact delta.
/// Snapshots are host state, never an AI write capability or a Markdown backup.
public enum ManualTrashRuntime {
    public static func trashing(kind: ManualTrashKind, id: String, viewIDs: [String] = [], in project: BookProject) throws -> BookProject {
        try validateStoredState(in: project)
        var state = project.manualTrash ?? ManualTrashState()
        guard state.items.count < 200, state.revision < Int.max else { throw invalid("回收站已满或版本超过上限；原内容没有移除。请先恢复已有条目。") }
        try identifier(id)
        var result: BookProject
        let title: String
        switch kind {
        case .entity:
            title = project.entities.first { $0.id == id }?.name ?? id; result = try KnowledgeDeletion.removingEntity(id: id, from: project)
        case .event:
            title = project.events.first { $0.id == id }?.name ?? id; result = try KnowledgeDeletion.removingEvent(id: id, from: project)
        case .relation:
            title = project.relations.first { $0.id == id }?.label ?? id; result = try KnowledgeDeletion.removingRelation(id: id, from: project)
        case .node:
            title = project.nodes.first { $0.id == id }.map { nodeTitle($0, in: project) } ?? id; result = try KnowledgeDeletion.removingCanvasNode(id: id, from: project)
        case .edge:
            title = project.edges.first { $0.id == id }?.label ?? id; result = try KnowledgeDeletion.removingCanvasEdge(id: id, from: project)
        case .view:
            guard let view = project.views.first(where: { $0.id == id }) else { throw invalid("要移除的组件入口不存在。") }
            let ids = viewIDs.isEmpty ? [id] : viewIDs
            guard ids.count <= 128, Set(ids).count == ids.count, ids.contains(id), Set(ids).isSubset(of: Set(project.views.map(\.id))) else { throw invalid("要移除的组件集合无效。") }
            title = view.title; result = project; let removed = Set(ids); result.views.removeAll { removed.contains($0.id) }
        }
        let patches = try diff(from: project, to: result)
        guard !patches.isEmpty else { throw invalid("没有可回收的改动。") }
        let units = try sourceUnits(for: patches, in: project)
        let byID = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var hashes: [String: String] = [:]
        for unitID in units {
            guard let unit = byID[unitID] else { throw invalid("回收内容的原文依赖不存在；原内容没有移除。") }
            hashes[unitID] = try BookImporter.sha256(Data(unit.text.utf8))
        }
        let neededTypes = try typeIDs(for: patches)
        let item = ManualTrashItem(id: UUID().uuidString, kind: kind, rootID: id, title: displayTitle(title, kind: kind, id: id), deletedAt: Date(),
            sourceHash: project.sourceHash, unitHashes: hashes, patches: patches, dependencies: try references(for: patches, in: project),
            supportingTypes: project.types.filter { neededTypes.contains($0.id) })
        state.items.append(item); state.revision += 1; result.manualTrash = state
        try validateStoredState(in: result)
        result.audit.append(ToolAudit(name: "manual_trash", summary: "已将\(item.title)及本次受影响的关联快照移入回收站。"))
        return result
    }

    public static func restorePlan(in project: BookProject, itemID: String) throws -> ManualTrashRestorePlan {
        try validateStoredState(in: project)
        guard let state = project.manualTrash, let root = state.items.firstIndex(where: { $0.id == itemID }) else { throw invalid("要恢复的条目不存在。") }
        let touches = try state.items.map { try touchedFields($0.patches) }
        let presentIDs = Dictionary(uniqueKeysWithValues: ManualTrashCollection.allCases.map { ($0, Set(recordIDs($0, in: project))) })
        var removedOwners: [String: Int] = [:]
        for (index, item) in state.items.enumerated() { for patch in item.patches where patch.after == nil { removedOwners[key(patch.collection, patch.id)] = index } }
        var selected: Set<Int> = [root], changed = true
        while changed {
            changed = false
            let covered = Set(selected.flatMap { state.items[$0].patches.map { key($0.collection, $0.id) } })
            for index in selected.sorted() {
                let item = state.items[index]
                // Later removals affecting the same field must be reversed
                // first. Unrelated edits on that record remain independent.
                if index + 1 < state.items.count {
                    for later in (index + 1)..<state.items.count where !selected.contains(later) {
                        if overlaps(touches[index], touches[later]) { selected.insert(later); changed = true }
                    }
                }
                for reference in item.dependencies where presentIDs[reference.collection]?.contains(reference.id) != true {
                    let recordKey = key(reference.collection, reference.id)
                    if covered.contains(recordKey) { continue }
                    if let dependency = removedOwners[recordKey], selected.insert(dependency).inserted { changed = true }
                }
            }
        }
        let items = selected.sorted(by: >).map { state.items[$0] }
        var conflicts: [String] = []
        do { _ = try restore(items, in: project) }
        catch { conflicts.append(error.localizedDescription) }
        return ManualTrashRestorePlan(itemIDs: items.map(\.id), items: items, conflicts: conflicts)
    }

    public static func restoring(itemID: String, expectedItemIDs: [String], in project: BookProject) throws -> BookProject {
        let plan = try restorePlan(in: project, itemID: itemID)
        guard expectedItemIDs == plan.itemIDs else { throw invalid("恢复依赖已经变化，请重新查看要一起恢复的条目。") }
        guard plan.conflicts.isEmpty else { throw invalid(plan.conflicts.joined(separator: "\n")) }
        var result = try restore(plan.items, in: project)
        result.audit.append(ToolAudit(name: "manual_restore", summary: "已恢复：\(plan.titles.joined(separator: "、"))；保留无关的后续编辑。"))
        return result
    }

    public static func validateStoredState(in project: BookProject) throws {
        try validateShape(project.manualTrash)
        try validateReserved(project)
    }
    public static func validateReservedRecords(in project: BookProject) throws {
        try validateShape(project.manualTrash)
        try validateReserved(project)
    }
    public static func protectedUnitIDs(in project: BookProject) throws -> Set<String> {
        try validateShape(project.manualTrash)
        var result = Set<String>()
        for item in project.manualTrash?.items ?? [] {
            result.formUnion(item.unitHashes.keys)
            result.formUnion(try sourceUnits(for: item.patches, in: project))
        }
        return result
    }

    private static func restore(_ items: [ManualTrashItem], in project: BookProject) throws -> BookProject {
        var result = project
        var cache: [ManualTrashCollection: [String: Data]] = [:]
        var positions: [ManualTrashCollection: [String: Int]] = [:]
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            guard item.sourceHash == project.sourceHash else { throw invalid("\(item.title)属于另一原文版本；回收快照已保留。") }
            for (id, hash) in item.unitHashes {
                guard let unit = units[id], try BookImporter.sha256(Data(unit.text.utf8)) == hash else { throw invalid("\(item.title)引用的原文或OCR已经变化；未恢复或覆盖当前内容。") }
            }
            for type in item.supportingTypes {
                if let existing = result.types.first(where: { $0.id == type.id }) {
                    guard existing == type else { throw invalid("类型\(type.name)已经改变；不能覆盖现有定义。") }
                } else { result.types.append(type) }
            }
            for patch in item.patches {
                if cache[patch.collection] == nil {
                    cache[patch.collection] = try records(patch.collection, in: result)
                    positions[patch.collection] = Dictionary(uniqueKeysWithValues: recordIDs(patch.collection, in: result).enumerated().map { ($0.element, $0.offset) })
                }
                let current = cache[patch.collection]?[patch.id]
                let replacement: Data
                if let after = patch.after {
                    guard let current else { throw invalid("恢复\(item.title)需要的\(patch.collection.rawValue)/\(patch.id)已不存在；快照已保留。") }
                    replacement = try merge(before: patch.before, after: after, current: current, label: item.title + " · " + patch.collection.rawValue + "/" + patch.id)
                } else {
                    guard current == nil || current == patch.before else { throw invalid("同标识已有新内容：\(patch.collection.rawValue)/\(patch.id)；没有用旧快照覆盖。") }
                    replacement = patch.before
                }
                let index = positions[patch.collection]?[patch.id]
                try replace(patch.collection, id: patch.id, data: replacement, index: index, in: &result)
                if index == nil { positions[patch.collection]?[patch.id] = cache[patch.collection]?.count ?? 0 }
                cache[patch.collection]?[patch.id] = replacement
            }
        }
        guard var state = result.manualTrash, state.revision < Int.max else { throw invalid("回收站版本无效。") }
        let ids = Set(items.map(\.id)); state.items.removeAll { ids.contains($0.id) }; state.revision += 1; result.manualTrash = state
        try validateStoredState(in: result)
        try validateRestoredReferences(result)
        return result
    }

    private static func merge(before: Data, after: Data, current: Data, label: String) throws -> Data {
        let first = try object(before), last = try object(after); var present = try object(current)
        for key in Set(first.keys).union(last.keys) where try value(first[key]) != value(last[key]) {
            let existing = try value(present[key]), expected = try value(last[key]), desired = try value(first[key])
            guard existing == expected || existing == desired else { throw invalid("\(label)的\(key)在删除后已有新值；恢复停止，当前内容和快照均保留。") }
            present[key] = first[key]
        }
        return try JSONSerialization.data(withJSONObject: present, options: [.sortedKeys])
    }
    private static func touchedFields(_ patches: [ManualTrashPatch]) throws -> [String: Set<String>] {
        try Dictionary(uniqueKeysWithValues: patches.map { patch in
            (key(patch.collection, patch.id), try patch.after.map { try fields(before: patch.before, after: $0) } ?? ["*"])
        })
    }
    private static func overlaps(_ lhs: [String: Set<String>], _ rhs: [String: Set<String>]) -> Bool {
        for (key, first) in lhs { if let second = rhs[key], first.contains("*") || second.contains("*") || !first.isDisjoint(with: second) { return true } }
        return false
    }
    private static func fields(before: Data, after: Data) throws -> Set<String> {
        let a = try object(before), b = try object(after)
        return Set(try Set(a.keys).union(b.keys).filter { try value(a[$0]) != value(b[$0]) })
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid("回收快照不是记录对象。") }; return value
    }
    private static func value(_ value: Any?) throws -> Data? {
        try value.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
    }
    private static func diff(from before: BookProject, to after: BookProject) throws -> [ManualTrashPatch] {
        var result: [ManualTrashPatch] = []
        for collection in ManualTrashCollection.allCases {
            let a = try records(collection, in: before), b = try records(collection, in: after)
            for id in Set(a.keys).union(b.keys).sorted() where a[id] != b[id] {
                guard let first = a[id] else { throw invalid("移除操作不能凭空新增记录。") }
                result.append(ManualTrashPatch(collection: collection, id: id, before: first, after: b[id]))
            }
        }
        return result
    }

    private static func records(_ collection: ManualTrashCollection, in project: BookProject) throws -> [String: Data] {
        func encode<T: Encodable & Identifiable>(_ values: [T]) throws -> [String: Data] where T.ID == String {
            guard Set(values.map(\.id)).count == values.count else { throw invalid("记录身份重复，不能生成可靠回收快照。") }
            return try Dictionary(uniqueKeysWithValues: values.map { ($0.id, try data($0)) })
        }
        switch collection {
        case .entities: return try encode(project.entities)
        case .events: return try encode(project.events)
        case .relations: return try encode(project.relations)
        case .nodes: return try encode(project.nodes)
        case .edges: return try encode(project.edges)
        case .views: return try encode(project.views)
        case .documents: return try encode(project.documents)
        case .graphGroups: return try encode(project.graphGroups ?? [])
        case .temporalAnchors: return try encode(project.temporalKnowledge?.anchors ?? [])
        case .presences: return try encode(project.temporalKnowledge?.presences ?? [])
        case .participations: return try encode(project.temporalKnowledge?.participations ?? [])
        case .eventMetadata: return try encode(project.temporalKnowledge?.eventMetadata ?? [])
        case .relationMetadata: return try encode(project.temporalKnowledge?.relationMetadata ?? [])
        case .experienceAnchors: return try encode(project.readingExperience?.anchors ?? [])
        case .mentions: return try encode(project.readingExperience?.mentions ?? [])
        }
    }
    private static func recordIDs(_ collection: ManualTrashCollection, in project: BookProject) -> [String] {
        switch collection {
        case .entities: return project.entities.map(\.id)
        case .events: return project.events.map(\.id)
        case .relations: return project.relations.map(\.id)
        case .nodes: return project.nodes.map(\.id)
        case .edges: return project.edges.map(\.id)
        case .views: return project.views.map(\.id)
        case .documents: return project.documents.map(\.id)
        case .graphGroups: return (project.graphGroups ?? []).map(\.id)
        case .temporalAnchors: return (project.temporalKnowledge?.anchors ?? []).map(\.id)
        case .presences: return (project.temporalKnowledge?.presences ?? []).map(\.id)
        case .participations: return (project.temporalKnowledge?.participations ?? []).map(\.id)
        case .eventMetadata: return (project.temporalKnowledge?.eventMetadata ?? []).map(\.id)
        case .relationMetadata: return (project.temporalKnowledge?.relationMetadata ?? []).map(\.id)
        case .experienceAnchors: return (project.readingExperience?.anchors ?? []).map(\.id)
        case .mentions: return (project.readingExperience?.mentions ?? []).map(\.id)
        }
    }
    private static func replace(_ collection: ManualTrashCollection, id: String, data: Data, index: Int?, in project: inout BookProject) throws {
        func update<T: Codable & Identifiable>(_ values: inout [T]) throws where T.ID == String {
            let value = try JSONDecoder().decode(T.self, from: data)
            guard value.id == id else { throw invalid("回收记录身份与快照不一致。") }
            if let index {
                guard values.indices.contains(index), values[index].id == id else { throw invalid("恢复记录索引已经改变。") }; values[index] = value
            } else { values.append(value) }
        }
        switch collection {
        case .entities: try update(&project.entities)
        case .events: try update(&project.events)
        case .relations: try update(&project.relations)
        case .nodes: try update(&project.nodes)
        case .edges: try update(&project.edges)
        case .views: try update(&project.views)
        case .documents: try update(&project.documents)
        case .graphGroups: var values = project.graphGroups ?? []; try update(&values); project.graphGroups = values
        case .temporalAnchors, .presences, .participations, .eventMetadata, .relationMetadata:
            var state = project.temporalKnowledge ?? TemporalKnowledgeState()
            switch collection {
            case .temporalAnchors: try update(&state.anchors)
            case .presences: try update(&state.presences)
            case .participations: try update(&state.participations)
            case .eventMetadata: try update(&state.eventMetadata)
            case .relationMetadata: try update(&state.relationMetadata)
            default: break
            }; project.temporalKnowledge = state
        case .experienceAnchors, .mentions:
            var state = project.readingExperience ?? ReadingExperienceState()
            if collection == .experienceAnchors { try update(&state.anchors) } else { try update(&state.mentions) }
            project.readingExperience = state
        }
    }

    private static func references(for patches: [ManualTrashPatch], in project: BookProject) throws -> [ManualTrashReference] {
        var result = Set<ManualTrashReference>()
        func add(_ collection: ManualTrashCollection, _ id: String?) { if let id { result.insert(ManualTrashReference(collection: collection, id: id)) } }
        func target(_ id: String) {
            if project.entities.contains(where: { $0.id == id }) { add(.entities, id) }
            else if project.events.contains(where: { $0.id == id }) { add(.events, id) }
            else if project.documents.contains(where: { $0.id == id }) { add(.documents, id) }
        }
        func anchors(_ ids: [String]) {
            for id in ids {
                if project.temporalKnowledge?.anchors.contains(where: { $0.id == id }) == true { add(.temporalAnchors, id) }
                else { add(.experienceAnchors, id) }
            }
        }
        for patch in patches {
            let decoder = JSONDecoder()
            switch patch.collection {
            case .events:
                let value = try decoder.decode(KnowledgeEvent.self, from: patch.before); for id in value.placeIDs + value.participantIDs { add(.entities, id) }
            case .relations:
                let value = try decoder.decode(KnowledgeRelation.self, from: patch.before); target(value.fromID); target(value.toID)
            case .nodes:
                let value = try decoder.decode(CanvasNode.self, from: patch.before); target(value.targetID); for id in value.documentIDs ?? [] { add(.documents, id) }
            case .edges:
                let value = try decoder.decode(CanvasEdge.self, from: patch.before); add(.nodes, value.fromID); add(.nodes, value.toID)
            case .documents:
                let value = try decoder.decode(DocumentRecord.self, from: patch.before); for id in value.linkedIDs { target(id) }
            case .graphGroups:
                let value = try decoder.decode(CanvasGroup.self, from: patch.before); for id in value.nodeIDs { add(.nodes, id) }
            case .presences:
                let value = try decoder.decode(EntityPresence.self, from: patch.before); add(.entities, value.entityID); add(.entities, value.placeID); add(.events, value.eventID); anchors(value.sourceAnchorIDs)
            case .participations:
                let value = try decoder.decode(Participation.self, from: patch.before); add(.entities, value.entityID); add(.events, value.eventID); anchors(value.sourceAnchorIDs)
            case .eventMetadata:
                let value = try decoder.decode(EventTemporalMetadata.self, from: patch.before); add(.events, value.eventID); add(.events, value.parentEventID); anchors(value.sourceAnchorIDs)
            case .relationMetadata:
                let value = try decoder.decode(RelationTemporalMetadata.self, from: patch.before); add(.relations, value.relationID); anchors(value.sourceAnchorIDs)
            case .mentions:
                let value = try decoder.decode(SourceMention.self, from: patch.before); target(value.targetID); anchors([value.anchorID])
            default: break
            }
        }
        return result.sorted { ($0.collection.rawValue, $0.id) < ($1.collection.rawValue, $1.id) }
    }
    private static func sourceUnits(for patches: [ManualTrashPatch], in project: BookProject) throws -> Set<String> {
        var result = Set<String>()
        let unitIDs = Set(project.units.map(\.id))
        let anchors = Dictionary(((project.temporalKnowledge?.anchors ?? []) + (project.readingExperience?.anchors ?? [])).map { ($0.id, $0.unitID) }, uniquingKeysWith: { first, _ in first })
        func target(_ id: String) { if unitIDs.contains(id) { result.insert(id) }; if let insight = project.insights.first(where: { $0.id == id }) { result.formUnion(insight.unitIDs) } }
        func evidence(_ values: [Evidence]) { result.formUnion(values.map(\.unitID)) }
        for patch in patches {
            for payload in [patch.before, patch.after].compactMap({ $0 }) {
                let decoder = JSONDecoder()
                switch patch.collection {
                case .entities: evidence(try decoder.decode(KnowledgeEntity.self, from: payload).evidence)
                case .events: evidence(try decoder.decode(KnowledgeEvent.self, from: payload).evidence)
                case .relations: evidence(try decoder.decode(KnowledgeRelation.self, from: payload).evidence)
                case .documents:
                    let value = try decoder.decode(DocumentRecord.self, from: payload); evidence(value.evidence); for id in value.linkedIDs { target(id) }
                case .nodes: target(try decoder.decode(CanvasNode.self, from: payload).targetID)
                case .temporalAnchors, .experienceAnchors: result.insert(try decoder.decode(SourceAnchor.self, from: payload).unitID)
                case .presences: result.formUnion(try decoder.decode(EntityPresence.self, from: payload).sourceAnchorIDs.compactMap { anchors[$0] })
                case .participations: result.formUnion(try decoder.decode(Participation.self, from: payload).sourceAnchorIDs.compactMap { anchors[$0] })
                case .eventMetadata: result.formUnion(try decoder.decode(EventTemporalMetadata.self, from: payload).sourceAnchorIDs.compactMap { anchors[$0] })
                case .relationMetadata: result.formUnion(try decoder.decode(RelationTemporalMetadata.self, from: payload).sourceAnchorIDs.compactMap { anchors[$0] })
                case .mentions: if let id = anchors[try decoder.decode(SourceMention.self, from: payload).anchorID] { result.insert(id) }
                default: break
                }
            }
        }
        return result
    }
    private static func typeIDs(for patches: [ManualTrashPatch]) throws -> Set<String> {
        var result = Set<String>()
        for patch in patches {
            switch patch.collection {
            case .entities: result.insert(try JSONDecoder().decode(KnowledgeEntity.self, from: patch.before).typeID)
            case .eventMetadata: if let id = try JSONDecoder().decode(EventTemporalMetadata.self, from: patch.before).typeID { result.insert(id) }
            case .views:
                let view = try JSONDecoder().decode(ViewDefinition.self, from: patch.before)
                result.formUnion(view.typeIDs); result.formUnion(view.composition?.sources.flatMap(\.typeIDs) ?? [])
            default: break
            }
        }
        return result
    }

    private static func validateShape(_ state: ManualTrashState?) throws {
        guard let state else { return }
        guard state.version == 1, state.revision >= 0, state.items.count <= 200, Set(state.items.map(\.id)).count == state.items.count,
              try data(state).count <= 32 * 1_024 * 1_024 else { throw invalid("回收站版本、数量或总快照大小超过安全上限。") }
        for item in state.items {
            try identifier(item.id); try identifier(item.rootID)
            guard item.deletedAt.timeIntervalSince1970.isFinite, !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.title.utf8.count <= 1600, !item.title.contains("\0"), hash(item.sourceHash),
                  !item.patches.isEmpty, item.patches.count <= 4000, item.dependencies.count <= 20_000,
                  Set(item.dependencies).count == item.dependencies.count, item.supportingTypes.count <= 256,
                  item.unitHashes.count <= BookImporter.maximumUnits, try data(item).count <= 8 * 1_024 * 1_024 else { throw invalid("回收快照字段、日期或大小无效；原内容没有移除。") }
            for (id, value) in item.unitHashes { try identifier(id); guard hash(value) else { throw invalid("回收原文校验值无效。") } }
            var seen = Set<String>()
            for patch in item.patches {
                guard seen.insert(key(patch.collection, patch.id)).inserted, patch.before != patch.after,
                      patch.before.count <= 2_097_152, (patch.after?.count ?? 0) <= 2_097_152 else { throw invalid("回收补丁重复、无变化或过大。") }
                for payload in [patch.before, patch.after].compactMap({ $0 }) { try validateRecord(payload, patch: patch) }
            }
            for reference in item.dependencies { try referenceID(reference.collection, reference.id) }
            guard Set(item.supportingTypes.map(\.id)).count == item.supportingTypes.count else { throw invalid("回收依赖类型重复。") }
            for type in item.supportingTypes { try identifier(type.id); guard !type.name.isEmpty, type.fields.count <= 100 else { throw invalid("回收的类型依赖无效。") } }
        }
    }
    private static func validateRecord(_ payload: Data, patch: ManualTrashPatch) throws {
        func check<T: Decodable & Identifiable>(_ type: T.Type) throws where T.ID == String {
            guard try JSONDecoder().decode(type, from: payload).id == patch.id else { throw invalid("回收补丁身份与正文不一致。") }
        }
        try referenceID(patch.collection, patch.id)
        switch patch.collection {
        case .entities: try check(KnowledgeEntity.self)
        case .events: try check(KnowledgeEvent.self)
        case .relations: try check(KnowledgeRelation.self)
        case .nodes: try check(CanvasNode.self)
        case .edges: try check(CanvasEdge.self)
        case .views: try check(ViewDefinition.self)
        case .documents: try check(DocumentRecord.self)
        case .graphGroups: try check(CanvasGroup.self)
        case .temporalAnchors, .experienceAnchors: try check(SourceAnchor.self)
        case .presences: try check(EntityPresence.self)
        case .participations: try check(Participation.self)
        case .eventMetadata: try check(EventTemporalMetadata.self)
        case .relationMetadata: try check(RelationTemporalMetadata.self)
        case .mentions: try check(SourceMention.self)
        }
    }
    private static func validateReserved(_ project: BookProject) throws {
        let knowledge = Set(project.entities.map(\.id) + project.events.map(\.id) + project.documents.map(\.id))
        var caches: [ManualTrashCollection: Set<String>] = [:]
        for item in project.manualTrash?.items ?? [] {
            for patch in item.patches where patch.after == nil {
                let ids: Set<String>
                if patch.collection == .entities || patch.collection == .events { ids = knowledge }
                else if let cached = caches[patch.collection] { ids = cached }
                else { ids = Set(recordIDs(patch.collection, in: project)); caches[patch.collection] = ids }
                guard !ids.contains(patch.id) else { throw invalid("标识仍在回收站中，不能重建或覆盖：\(patch.collection.rawValue)/\(patch.id)。请先恢复原条目。") }
            }
        }
    }
    private static func validateRestoredReferences(_ project: BookProject) throws {
        let entities = Set(project.entities.map(\.id)), events = Set(project.events.map(\.id)), documents = Set(project.documents.map(\.id))
        let knowledge = entities.union(events).union(documents), targets = knowledge.union(project.units.map(\.id)).union(project.insights.map(\.id))
        guard entities.count == project.entities.count, events.count == project.events.count, documents.count == project.documents.count,
              entities.isDisjoint(with: events), entities.isDisjoint(with: documents), events.isDisjoint(with: documents),
              project.types.count <= 1000, project.nodes.count <= 100_000, project.edges.count <= 200_000 else { throw invalid("恢复后的身份或记录数量不合法。") }
        let types = Set(project.types.map(\.id)), nodes = Set(project.nodes.map(\.id))
        for entity in project.entities where !types.contains(entity.typeID) { throw invalid("恢复所需的类型定义缺失。") }
        for event in project.events where !Set(event.placeIDs + event.participantIDs).isSubset(of: entities) { throw invalid("恢复关联需要一起恢复其他人物或地点；快照已保留。") }
        for relation in project.relations where !knowledge.contains(relation.fromID) || !knowledge.contains(relation.toID) { throw invalid("恢复关系需要一起恢复另一端对象；快照已保留。") }
        for node in project.nodes where !targets.contains(node.targetID) && !(node.isStandalone == true && node.id == node.targetID) { throw invalid("恢复节点需要一起恢复它引用的内容。") }
        for edge in project.edges where !nodes.contains(edge.fromID) || !nodes.contains(edge.toID) { throw invalid("恢复连线需要一起恢复端点节点。") }
        for document in project.documents where !Set(document.linkedIDs).isSubset(of: targets) { throw invalid("恢复笔记关联所需的对象尚未恢复。") }
        for view in project.views where !Set(view.typeIDs).isSubset(of: types) { throw invalid("恢复组件所需的类型已缺失。") }
        try ControlledGraphRuntime.validate(in: project)
        try TemporalKnowledgeRuntime.validateStoredState(in: project)
        if let experience = project.readingExperience { try ReadingExperienceRuntime.validateStoredState(experience, in: project) }
    }
    private static func referenceID(_ collection: ManualTrashCollection, _ id: String) throws {
        if collection == .mentions {
            let parts = id.components(separatedBy: "::"); guard parts.count == 2 else { throw invalid("词语提及的复合标识无效。") }; for part in parts { try identifier(part) }
        } else { try identifier(id) }
    }
    private static func identifier(_ value: String) throws { guard value.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil else { throw invalid("回收记录标识无效。") } }
    private static func hash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit } }
    private static func key(_ collection: ManualTrashCollection, _ id: String) -> String { collection.rawValue + "/" + id }
    private static func data<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private static func nodeTitle(_ node: CanvasNode, in project: BookProject) -> String {
        node.title ?? project.documents.first { $0.id == node.targetID }?.title ?? project.entities.first { $0.id == node.targetID }?.name ?? project.events.first { $0.id == node.targetID }?.name ?? "导图节点"
    }
    private static func displayTitle(_ title: String, kind: ManualTrashKind, id: String) -> String {
        var value = String(String.UnicodeScalarView(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.utf8.count > 1600 { value.removeLast() }
        let fallback: String
        switch kind { case .entity: fallback = "要素"; case .event: fallback = "事件"; case .relation: fallback = "关系"
        case .node: fallback = "导图节点"; case .edge: fallback = "导图连线"; case .view: fallback = "组件入口" }
        return value.isEmpty ? fallback + " · " + id : value
    }
    private static func invalid(_ message: String) -> ReadingError { .invalid(message) }
}
