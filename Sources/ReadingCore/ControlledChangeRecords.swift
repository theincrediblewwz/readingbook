import Foundation

enum ControlledChangeRecords {
    /// Chat/audit additions and reader navigation do not invalidate a reviewed
    /// content proposal. Every other canonical field remains under the grant CAS.
    static func revision(_ project: BookProject) throws -> String {
        var value = project
        value.chats = []; value.audit = []; value.lastUnitID = nil
        value.bookmarks = []; value.readerAnnotations = nil
        // Transport counters and host-only explanation caches do not change
        // what the reader reviewed or grant new write authority. Actual source,
        // object, document and layout changes remain part of this revision.
        value.aiRequestHistory = nil; value.readingKnowledge = nil; value.generatedOutline = nil; value.originalBookOutline = nil
        return try ControlledChangeCoding.hash(value)
    }

    static func applying(_ patches: [ControlledRecordPatch], to project: BookProject, undo: Bool) throws -> BookProject {
        var result = project
        // Work on a value copy. A conflict in any collection leaves the caller intact.
        for patch in patches {
            let expected = undo ? patch.after : patch.before, replacement = undo ? patch.before : patch.after
            func update<T: Codable & Identifiable>(_ values: inout [T]) throws where T.ID == String {
                let index = values.firstIndex { $0.id == patch.id }
                let current = try index.map { try ControlledChangeCoding.data(values[$0]) }
                guard current == expected else { throw ControlledChangeError.conflict("记录在提案之后已改变，未覆盖：\(patch.collection.rawValue)/\(patch.id)") }
                if let replacement {
                    let value = try JSONDecoder().decode(T.self, from: replacement)
                    guard value.id == patch.id else { throw ControlledChangeError.invalid("变更记录 ID 与正文不一致。") }
                    if let index { values[index] = value } else { values.append(value) }
                } else if let index { values.remove(at: index) }
            }
            switch patch.collection {
            case .types: try update(&result.types)
            case .entities: try update(&result.entities)
            case .events: try update(&result.events)
            case .relations: try update(&result.relations)
            case .nodes: try update(&result.nodes)
            case .edges: try update(&result.edges)
            case .graphGroups:
                var values = result.graphGroups ?? []; try update(&values); result.graphGroups = values
            case .documents:
                if undo, patch.before == nil {
                    // Undoing a new note never deletes its file or reference. Keep
                    // its exact contents in the ordinary recoverable trash.
                    guard let index = result.documents.firstIndex(where: { $0.id == patch.id }),
                          try ControlledChangeCoding.data(result.documents[index]) == expected else { throw ControlledChangeError.conflict("新笔记已经被编辑或回收，未自动撤销。") }
                    result.documents[index].trashedAt = Date()
                } else { try update(&result.documents) }
            case .temporalAnchors, .presences, .participations, .eventMetadata, .relationMetadata:
                var temporal = result.temporalKnowledge ?? TemporalKnowledgeState()
                switch patch.collection {
                case .temporalAnchors: try update(&temporal.anchors)
                case .presences: try update(&temporal.presences)
                case .participations: try update(&temporal.participations)
                case .eventMetadata: try update(&temporal.eventMetadata)
                case .relationMetadata: try update(&temporal.relationMetadata)
                default: break
                }
                result.temporalKnowledge = temporal
            case .experienceAnchors, .layers, .alignments:
                var experience = result.readingExperience ?? ReadingExperienceState()
                switch patch.collection {
                case .experienceAnchors: try update(&experience.anchors)
                case .layers: try update(&experience.layers)
                case .alignments: try update(&experience.alignments)
                default: break
                }
                result.readingExperience = experience
            case .bookSchemes:
                guard patch.id == "book-schemes", try result.bookSchemes.map(ControlledChangeCoding.data) == expected else { throw ControlledChangeError.conflict("书本方案已变化，请保留当前配置并重新审阅。") }
                result.bookSchemes = try replacement.map { try JSONDecoder().decode(BookSchemeState.self, from: $0) }
            }
        }
        if undo {
            let retained = Set(result.entities.map(\.id)).union(result.events.map(\.id)).union(result.documents.map(\.id)).union(result.units.map(\.id)).union(result.insights.map(\.id))
            let addedDocuments = Set(patches.filter { $0.collection == .documents && $0.before == nil }.map(\.id))
            for index in result.documents.indices where addedDocuments.contains(result.documents[index].id) {
                result.documents[index].linkedIDs.removeAll { !retained.contains($0) }
            }
        }
        return result
    }

    static func validate(in project: BookProject) throws {
        guard let state = project.controlledChanges else { return }
        guard state.version == 1, state.receipts.count <= 1_000,
              Set(state.receipts.map(\.id)).count == state.receipts.count else { throw ControlledChangeError.invalid("整理回执版本、数量或 ID 无效。") }
        for receipt in state.receipts {
            try ControlledChangeCoding.requireID(receipt.operationID); try ControlledChangeCoding.requireID(receipt.grantID)
            guard UUID(uuidString: receipt.originBookID) != nil, hash(receipt.digest), receipt.createdAt.timeIntervalSince1970.isFinite,
                  receipt.undoneAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  !receipt.groups.isEmpty, Set(receipt.groups).count == receipt.groups.count,
                  receipt.idMap.count <= 512, receipt.patches.count <= 512, receipt.documents.count <= 32,
                  Set(receipt.documents.map(\.documentID)).count == receipt.documents.count else { throw ControlledChangeError.invalid("整理回执字段超出安全范围。") }
            for (client, actual) in receipt.idMap { try ControlledChangeCoding.requireID(client); try ControlledChangeCoding.requireID(actual) }
            var seen = Set<String>()
            for patch in receipt.patches {
                try ControlledChangeCoding.requireID(patch.id)
                guard seen.insert(patch.collection.rawValue + "/" + patch.id).inserted, patch.before != patch.after,
                      patch.before.map({ $0.count <= 2_097_152 }) ?? true, patch.after.map({ $0.count <= 2_097_152 }) ?? true else { throw ControlledChangeError.invalid("整理回执中的补丁重复、无变化或过大。") }
                // Decode both historical sides, independent of active plugins and
                // current record existence. History may refer to later-undone data.
                for data in [patch.before, patch.after].compactMap({ $0 }) { try validateRecord(data, patch: patch) }
            }
            for document in receipt.documents {
                try ControlledChangeCoding.requireID(document.documentID)
                guard hash(document.afterHash), (document.beforeHash == nil) == (document.backupDocumentID == nil) else { throw ControlledChangeError.invalid("整理文档回执散列或备份不完整。") }
                if let before = document.beforeHash { guard hash(before) else { throw ControlledChangeError.invalid("整理文档原版本散列无效。") } }
                if let backup = document.backupDocumentID { try ControlledChangeCoding.requireID(backup) }
            }
        }
    }

    private static func validateRecord(_ data: Data, patch: ControlledRecordPatch) throws {
        func check<T: Decodable & Identifiable>(_ type: T.Type) throws where T.ID == String {
            guard try JSONDecoder().decode(type, from: data).id == patch.id else { throw ControlledChangeError.invalid("历史补丁 ID 无效。") }
        }
        switch patch.collection {
        case .types: try check(EntityType.self)
        case .entities: try check(KnowledgeEntity.self)
        case .events: try check(KnowledgeEvent.self)
        case .relations: try check(KnowledgeRelation.self)
        case .nodes: try check(CanvasNode.self)
        case .edges: try check(CanvasEdge.self)
        case .graphGroups: try check(CanvasGroup.self)
        case .documents: try check(DocumentRecord.self)
        case .temporalAnchors, .experienceAnchors: try check(SourceAnchor.self)
        case .presences: try check(EntityPresence.self)
        case .participations: try check(Participation.self)
        case .eventMetadata: try check(EventTemporalMetadata.self)
        case .relationMetadata: try check(RelationTemporalMetadata.self)
        case .layers: try check(ReadingLayer.self)
        case .alignments: try check(ReferenceAlignment.self)
        case .bookSchemes:
            guard patch.id == "book-schemes" else { throw ControlledChangeError.invalid("方案补丁 ID 无效。") }
            _ = try JSONDecoder().decode(BookSchemeState.self, from: data)
        }
    }
    static func hash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit } }
}

enum ControlledChangeSummary {
    static func describe(_ patches: [ControlledRecordPatch], from before: BookProject, to after: BookProject) throws -> [String] {
        func nodeName(_ node: CanvasNode, in project: BookProject) -> String {
            node.title ?? project.documents.first(where: { $0.id == node.targetID })?.title ?? project.entities.first(where: { $0.id == node.targetID })?.name ?? project.events.first(where: { $0.id == node.targetID })?.name ?? node.targetID
        }
        func body(_ data: Data?) -> String {
            guard let data, let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: pretty, encoding: .utf8) else { return "（无）" }
            return text // Explicit bounded JSON, not a model-written description.
        }
        return patches.map { patch in
            let action = patch.before == nil ? "新增" : patch.after == nil ? "移除布局" : "更新"
            switch patch.collection {
            case .nodes:
                let left = before.nodes.first { $0.id == patch.id }, right = after.nodes.first { $0.id == patch.id }
                func detail(_ node: CanvasNode?, in project: BookProject) -> String {
                    guard let node else { return "（无）" }
                    return "\(nodeName(node, in: project)) [\(node.id)]，位置(\(node.x), \(node.y))，目标\(node.targetID)，挂载\((node.documentIDs ?? []).joined(separator: ", "))"
                }
                return "\(action)节点：\(detail(left, in: before)) → \(detail(right, in: after))"
            case .edges:
                func detail(_ edge: CanvasEdge?, in project: BookProject) -> String {
                    guard let edge else { return "（无）" }
                    let from = project.nodes.first { $0.id == edge.fromID }.map { nodeName($0, in: project) } ?? edge.fromID
                    let to = project.nodes.first { $0.id == edge.toID }.map { nodeName($0, in: project) } ?? edge.toID
                    return "\(from) [\(edge.fromID)] —\(edge.label)→ \(to) [\(edge.toID)]"
                }
                return "\(action)连线 [\(patch.id)]：\(detail(before.edges.first { $0.id == patch.id }, in: before)) → \(detail(after.edges.first { $0.id == patch.id }, in: after))"
            case .bookSchemes:
                guard let pending = after.bookSchemes?.pending else { return "更新书本方案状态：\(body(patch.before)) → \(body(patch.after))" }
                return "暂存书本方案，尚未采纳或执行。类型/读书法/组件/计划/书籍分类的完整声明：\(body(try? ControlledChangeCoding.data(pending.before))) → \(body(try? ControlledChangeCoding.data(pending.proposed)))"
            default:
                return "\(action) \(patch.collection.rawValue) [\(patch.id)]：\(body(patch.before)) → \(body(patch.after))"
            }
        }
    }
}
