import Foundation

public enum ReadingProposalTools {
    public static func group(for tool: String) -> ControlledChangeGroup? {
        switch tool { case "knowledge_changes_propose": return .knowledge; case "graph_changes_propose": return .graph
        case "document_changes_propose": return .documents; case "book_scheme_propose": return .bookScheme; default: return nil }
    }
    /// Decode only a business payload. Model JSON never supplies host grant,
    /// operation identity, approval, revision or commit instructions.
    public static func decode(name: String, arguments: Data) throws -> ControlledChangeBatch {
        guard arguments.count <= 262_144, (try? JSONSerialization.jsonObject(with: arguments)) is [String: Any] else { throw ReadingError.invalid("变更提案须为小于256 KiB的JSON对象。") }
        let decoder = JSONDecoder()
        if let wrapper = try JSONSerialization.jsonObject(with: arguments) as? [String: Any], let raw = wrapper["batch"] {
            guard wrapper.count == 1, let value = raw as? [String: Any],
                  Set(value.keys).isSubset(of: ["knowledge", "graph", "documents", "bookScheme"]) else { throw ReadingError.invalid("变更批次包含未声明的宿主字段。") }
            let batch = try decoder.decode(ControlledChangeBatch.self, from: JSONSerialization.data(withJSONObject: value))
            let present: Bool
            switch group(for: name) { case .knowledge: present = batch.knowledge != nil; case .graph: present = batch.graph != nil
            case .documents: present = batch.documents != nil; case .bookScheme: present = batch.bookScheme != nil; case nil: present = false }
            guard present else { throw ReadingError.invalid("提案必须包含该工具对应的业务组。") }
            return batch
        }
        guard let definition = group(for: name) else { throw ReadingError.invalid("未注册的提案组。") }
        let schema: [String: Any]
        switch definition { case .knowledge: schema = ReadingProposalSchemas.knowledge; case .graph: schema = ReadingProposalSchemas.graph
        case .documents: schema = ReadingProposalSchemas.documents; case .bookScheme: schema = ReadingProposalSchemas.bookScheme }
        let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
        let fields = schema["properties"] as? [String: Any] ?? [:]
        guard Set(object.keys).isSubset(of: Set(fields.keys)) else { throw ReadingError.invalid("业务提案不能包含宿主权限、批准或其他未知字段。") }
        switch name {
        case "knowledge_changes_propose": return ControlledChangeBatch(knowledge: try decoder.decode(ControlledKnowledgeChanges.self, from: arguments))
        case "graph_changes_propose": return ControlledChangeBatch(graph: try decoder.decode(ControlledGraphChanges.self, from: arguments))
        case "document_changes_propose": return ControlledChangeBatch(documents: try decoder.decode(ControlledDocumentChanges.self, from: arguments))
        case "book_scheme_propose": return ControlledChangeBatch(bookScheme: try decoder.decode(ControlledBookSchemeChanges.self, from: arguments))
        default: throw ReadingError.invalid("未注册的提案组。")
        }
    }
}

enum ReadingProposalSchemas {
    static func object(_ fields: [String: Any], required: [String]? = nil) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "properties": fields, "required": required ?? fields.keys.sorted()]
    }
    static func array(_ item: [String: Any], maximum: Int = 64) -> [String: Any] { ["type": "array", "items": item, "maxItems": maximum] }
    static func text(_ maximum: Int = 4000) -> [String: Any] { ["type": "string", "maxLength": maximum] }
    static let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9][A-Za-z0-9_.-]*$"]
    static let number: [String: Any] = ["type": "number"]
    static let integer: [String: Any] = ["type": "integer"]
    static let strings: [String: Any] = ["type": "object", "additionalProperties": ["type": "string"], "maxProperties": 64]
    static var evidence: [String: Any] { object(["unitID": id, "quote": text(32_768)]) }
    static var type: [String: Any] { object(["id": id, "name": text(400), "icon": text(128), "fields": array(object(["key": id, "label": text(400), "required": ["type": "boolean"]]))]) }
    static var entity: [String: Any] {
        object(["id": id, "typeID": id, "name": text(400), "summary": text(32_768), "properties": strings, "aliases": array(text(400)), "latitude": number, "longitude": number, "locationNote": text(), "evidence": array(evidence)],
            required: ["id", "typeID", "name", "summary", "properties", "aliases", "evidence"])
    }
    static var event: [String: Any] {
        object(["id": id, "name": text(400), "summary": text(32_768), "dateText": text(), "startYear": integer, "endYear": integer,
            "placeIDs": array(id), "participantIDs": array(id), "evidence": array(evidence)], required: ["id", "name", "summary", "dateText", "placeIDs", "participantIDs", "evidence"])
    }
    static var relation: [String: Any] { object(["id": id, "fromID": id, "toID": id, "label": text(400), "evidence": array(evidence)]) }
    static var date: [String: Any] { object(["year": integer, "month": integer, "day": integer], required: ["year"]) }
    static var extent: [String: Any] {
        object(["sourceText": text(), "calendar": text(80), "start": date, "end": date, "precision": ["type": "string", "enum": ["unknown", "year", "month", "day", "narrative"]],
            "uncertainty": ["type": "string", "enum": ["exact", "approximate", "disputed", "unknown"]], "kind": ["type": "string", "enum": ["point", "interval", "uncertainRange"]],
            "narrativeStart": integer, "narrativeEnd": integer], required: ["sourceText", "precision", "uncertainty", "kind"])
    }
    static var attribution: [String: Any] { ["sourceAnchorIDs": array(id), "assertion": ["type": "string", "enum": ["explicit", "inferred", "unknown"]], "explanation": text()] }
    static var presence: [String: Any] {
        var fields = attribution; fields.merge(["id": id, "entityID": id, "placeID": id, "eventID": id, "extent": extent, "action": text()]) { _, next in next }
        return object(fields, required: ["id", "entityID", "extent", "action", "sourceAnchorIDs", "assertion", "explanation"])
    }
    static var participation: [String: Any] {
        var fields = attribution; fields.merge(["id": id, "entityID": id, "eventID": id, "role": text(400), "extent": extent]) { _, next in next }
        return object(fields, required: ["id", "entityID", "eventID", "role", "sourceAnchorIDs", "assertion", "explanation"])
    }
    static var eventMetadata: [String: Any] {
        var fields = attribution; fields.merge(["eventID": id, "typeID": id, "kind": text(80), "parentEventID": id, "phaseOrder": integer, "extent": extent]) { _, next in next }
        return object(fields, required: ["eventID", "kind", "sourceAnchorIDs", "assertion", "explanation"])
    }
    static var relationMetadata: [String: Any] {
        var fields = attribution; fields.merge(["id": id, "relationID": id, "validity": extent]) { _, next in next }; return object(fields)
    }
    static var provenance: [String: Any] { object(["label": text(), "url": text(), "workTitle": text(), "locator": text()], required: ["label"]) }
    static var knowledge: [String: Any] {
        object(["newTypeIDs": array(id), "newEntityIDs": array(id), "newEventIDs": array(id), "newRelationIDs": array(id), "types": array(type), "entities": array(entity), "events": array(event), "relations": array(relation),
            "anchors": array(object(["clientID": id, "unitID": id, "quote": text(32_768), "prefix": text(1000), "suffix": text(1000)], required: ["clientID", "unitID", "quote"])),
            "presences": array(presence), "participations": array(participation), "eventMetadata": array(eventMetadata), "relationMetadata": array(relationMetadata),
            "layers": array(object(["id": id, "kind": text(80), "title": text(400), "markdown": text(128_000), "sourceAnchorIDs": array(id), "sourceLabel": text(), "parallelGroupID": id, "provenance": provenance], required: ["id", "kind", "title", "markdown", "sourceAnchorIDs", "sourceLabel"])),
            "alignments": array(object(["id": id, "sourceAnchorIDs": array(id), "title": text(400), "markdown": text(128_000), "provenance": provenance, "status": text(80)], required: ["id", "sourceAnchorIDs", "title", "markdown", "status"]))], required: [])
    }
    static var graph: [String: Any] {
        object(["createNodes": array(object(["clientID": id, "title": text(400), "targetID": id, "documentIDs": array(id), "x": number, "y": number], required: ["clientID", "title", "x", "y"])),
            "attachments": array(object(["nodeID": id, "documentIDs": array(id), "mode": ["type": "string", "enum": ["attach", "detach"]]])),
            "connections": array(object(["clientID": id, "fromNodeID": id, "toNodeID": id, "label": text(400)])),
            "moves": array(object(["nodeID": id, "x": number, "y": number])), "renames": array(object(["nodeID": id, "title": text(400)])), "removeNodeIDs": array(id), "removeEdgeIDs": array(id),
            "createGroups": array(object(["clientID": id, "title": text(400), "nodeIDs": array(id), "childGroupIDs": array(id)])),
            "moveGroups": array(object(["groupID": id, "deltaX": number, "deltaY": number]))], required: [])
    }
    static var documents: [String: Any] {
        object(["create": array(object(["clientID": id, "title": text(400), "markdown": text(128_000), "linkedIDs": array(id), "evidence": array(evidence)], required: ["clientID", "title", "markdown"])),
            "edits": array(object(["documentID": id, "expectedHash": text(64), "mode": ["type": "string", "enum": ["replace", "append"]], "markdown": text(128_000)]))], required: [])
    }
    static var bookScheme: [String: Any] {
        let execution = object(["stepIndex": integer, "actionID": text(128), "configuration": strings, "maxAttempts": integer], required: ["stepIndex", "actionID"])
        let method = object(["id": id, "name": text(400), "goal": text(), "steps": array(text(), maximum: 24), "executions": array(execution, maximum: 24)], required: ["id", "name", "goal", "steps"])
        let view = object(["id": id, "title": text(400), "kind": ["type": "string", "enum": ComponentKind.allCases.map(\.rawValue)], "typeIDs": array(id), "rendererID": text(128), "scope": text(80), "configuration": strings, "composition": CompositionSchema.definition], required: ["id", "title", "kind"])
        let profile = object(["genres": array(["type": "string", "enum": BookGenre.allCases.map(\.rawValue)]), "customGenres": array(text(80)), "entityTypeIDs": array(id), "locationTypeIDs": array(id), "methodIDs": array(id), "rendererIDs": array(id), "timeSystem": text(80), "avoidsSpoilers": ["type": "boolean"]], required: ["genres", "customGenres", "entityTypeIDs", "locationTypeIDs", "methodIDs", "rendererIDs", "avoidsSpoilers"])
        return object(["types": array(type), "methods": array(method), "views": array(view), "plan": object(["methodIDs": array(id), "rationale": text(8000), "focus": array(text(400))]), "profile": profile], required: [])
    }
    static func schemas(names: Set<String>) -> [[String: Any]] {
        names.sorted().compactMap { name in
            let schema: [String: Any]
            switch name { case "knowledge_changes_propose": schema = knowledge; case "graph_changes_propose": schema = graph
            case "document_changes_propose": schema = documents; case "book_scheme_propose": schema = bookScheme; default: return nil }
            guard let group = ReadingProposalTools.group(for: name) else { return nil }
            var fields: [String: Any] = [group.rawValue: schema]
            // Cross-group atomic companions are typed by the host decoder. Their
            // detailed schemas can be requested instead of repeated four times.
            for other in [ControlledChangeGroup.knowledge, .graph, .documents, .bookScheme] where other != group {
                fields[other.rawValue] = ["type": "object", "description": "可选同笔原子搭配，结构可用capabilities_list(schemaFor:\"\(other.rawValue)\")查询；仍须宿主授予该组权限。", "additionalProperties": true]
            }
            let parameters = object(["batch": object(fields, required: [group.rawValue])])
            return ["type": "function", "function": ["name": name, "description": "提出本次具体变更批次；新建文档和挂载节点必须放同一batch，未提交提案的clientID不可跨批引用。新对象用clientID/new*IDs局部别名，已有对象用真实ID；不传grant/operationID/approval。已有笔记先读取真实expectedHash并由用户审阅diff。知识只引用本次实际读取原文。准备成功仅是预览；只有宿主回执明确applied=true才可说已保存。", "parameters": parameters]]
        }
    }
}

extension ReadingQuerySession {
    func validateProposal(name: String, data: Data) throws {
        let batch = try ReadingProposalTools.decode(name: name, arguments: data)
        guard let project, let scoped = scopedKnowledgeProject() else { throw invalid("宿主未提供冻结范围的项目，不能准备变更。") }
        let admitted = Set(try TemporalKnowledgeRuntime.objects(in: scoped, boundary: KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs))).map(\.id)).union(snapshot.documentIDs)
        let newObjects = Set((batch.knowledge?.newEntityIDs ?? []) + (batch.knowledge?.newEventIDs ?? []) + (batch.documents?.create ?? []).map(\.clientID))
        let targets = admitted.union(newObjects)
        func requireTargets(_ ids: [String]) throws {
            guard ids.allSatisfy(targets.contains) else { throw invalid("变更引用了冻结范围之外的已有对象；请先切换范围。") }
        }
        if let knowledge = batch.knowledge {
            try requireTargets((knowledge.entities ?? []).map(\.id) + (knowledge.events ?? []).map(\.id))
            try requireTargets((knowledge.events ?? []).flatMap { $0.placeIDs + $0.participantIDs })
            try requireTargets((knowledge.relations ?? []).flatMap { [$0.fromID, $0.toID] })
            try requireTargets((knowledge.presences ?? []).flatMap { [$0.entityID] + [$0.placeID, $0.eventID].compactMap { $0 } })
            try requireTargets((knowledge.participations ?? []).flatMap { [$0.entityID, $0.eventID] })
            try requireTargets((knowledge.eventMetadata ?? []).flatMap { [$0.eventID] + [$0.parentEventID].compactMap { $0 } })
            let relations = Set(scoped.relations.filter { admitted.contains($0.fromID) && admitted.contains($0.toID) }.map(\.id)).union(knowledge.newRelationIDs ?? [])
            guard (knowledge.relations ?? []).allSatisfy({ relations.contains($0.id) }),
                  (knowledge.relationMetadata ?? []).allSatisfy({ relations.contains($0.relationID) }) else { throw invalid("变更引用了范围外的关系。") }
        }
        for document in batch.documents?.create ?? [] { try requireTargets(document.linkedIDs ?? []) }
        if let graph = batch.graph {
            let nodes = Set(project.nodes.filter { admitsNode($0.id, admitted: admitted, project: project) }.map(\.id))
                .union((graph.createNodes ?? []).map(\.clientID))
            func requireNodes(_ ids: [String]) throws {
                guard ids.allSatisfy(nodes.contains) else { throw invalid("画布变更引用了本次范围外节点；未执行。") }
            }
            for node in graph.createNodes ?? [] { try requireTargets([node.targetID].compactMap { $0 } + (node.documentIDs ?? [])) }
            for attachment in graph.attachments ?? [] { try requireNodes([attachment.nodeID]); try requireTargets(attachment.documentIDs) }
            try requireNodes((graph.connections ?? []).flatMap { [$0.fromNodeID, $0.toNodeID] } + (graph.moves ?? []).map(\.nodeID) + (graph.renames ?? []).map(\.nodeID) + (graph.removeNodeIDs ?? []))
            for edgeID in graph.removeEdgeIDs ?? [] {
                guard let edge = project.edges.first(where: { $0.id == edgeID }) else { throw invalid("要删除的连线不存在。") }
                try requireNodes([edge.fromID, edge.toID])
            }
            let groups = Dictionary((project.graphGroups ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newGroups = Set((graph.createGroups ?? []).map(\.clientID))
            func requireGroups(_ ids: [String]) throws {
                var pending = ids, seen = Set<String>()
                while let id = pending.popLast() {
                    if newGroups.contains(id) || !seen.insert(id).inserted { continue }
                    guard let group = groups[id] else { throw invalid("布局组不存在。") }
                    try requireNodes(group.nodeIDs); pending += group.childGroupIDs
                }
            }
            for group in graph.createGroups ?? [] { try requireNodes(group.nodeIDs); try requireGroups(group.childGroupIDs) }
            try requireGroups((graph.moveGroups ?? []).map(\.groupID))
        }
        func read(_ id: String, _ quote: String) -> Bool {
            sourceExcerpts.contains { supplied in
                guard supplied.0 == id, !quote.isEmpty, let range = supplied.1.range(of: quote, options: .literal) else { return false }
                return supplied.1[range].utf8.elementsEqual(quote.utf8)
            }
        }
        func scan(_ value: Any) throws {
            if let object = value as? [String: Any] {
                if let id = object["unitID"] as? String, let quote = object["quote"] as? String, !read(id, quote) { throw invalid("提案引用了本次未实际提供的原文；请先在授权范围内读取对应片段。") }
                for child in object.values { try scan(child) }
            } else if let rows = value as? [Any] { for child in rows { try scan(child) } }
        }
        try scan(JSONSerialization.jsonObject(with: data))
        if let knowledge = batch.knowledge {
            let proposed = Set((knowledge.anchors ?? []).map(\.clientID))
            let anchors = (project.readingExperience?.anchors ?? []) + (project.temporalKnowledge?.anchors ?? [])
            var refs: [String] = []
            for value in knowledge.presences ?? [] { refs.append(contentsOf: value.sourceAnchorIDs) }
            for value in knowledge.participations ?? [] { refs.append(contentsOf: value.sourceAnchorIDs) }
            for value in knowledge.eventMetadata ?? [] { refs.append(contentsOf: value.sourceAnchorIDs) }
            for value in knowledge.relationMetadata ?? [] { refs.append(contentsOf: value.sourceAnchorIDs) }
            for value in knowledge.layers ?? [] { refs.append(contentsOf: value.sourceAnchorIDs) }
            for value in knowledge.alignments ?? [] { refs.append(contentsOf: value.sourceAnchorIDs) }
            for id in refs where !proposed.contains(id) {
                guard let anchor = anchors.first(where: { $0.id == id }), read(anchor.unitID, anchor.quote) else { throw invalid("提案锚点超出本次实际读取范围。") }
            }
        }
        for edit in batch.documents?.edits ?? [] {
            guard snapshot.documentIDs.contains(edit.documentID), documentHashes[edit.documentID] == edit.expectedHash else { throw invalid("修改已有笔记前须在本次授权范围内读取正文并使用其真实hash。") }
        }
    }
}
