import Foundation
import CoreFoundation

/// Only the renderer can supply real visibility; project membership is not visibility.
public struct ReadingVisibleObjectsSnapshot: Codable, Hashable, Sendable {
    public var rendererID: String
    public var objectIDs: [String]
    public var partial: Bool
    public var description: String
    public var nodeIDs: [String]
    public init(rendererID: String, objectIDs: [String], partial: Bool = false, description: String = "", nodeIDs: [String] = []) {
        self.rendererID = rendererID; self.objectIDs = objectIDs; self.partial = partial; self.description = description
        self.nodeIDs = nodeIDs
    }
}
public struct ReadingWorkspaceSnapshot: Codable, Hashable, Sendable {
    public var bookID: String
    public var sourceHash: String
    public var rendererID: String?
    public var selectedObjectIDs: [String]
    public var context: ReadingContext?
    public var visibleObjects: ReadingVisibleObjectsSnapshot?
    public var selectedNodeIDs: [String]
    public var timeAxis: String?
    public var timeFrom: Double?
    public var timeTo: Double?
    public var currentTime: Double?
    public init(bookID: String, sourceHash: String, rendererID: String? = nil, selectedObjectIDs: [String] = [], context: ReadingContext? = nil, visibleObjects: ReadingVisibleObjectsSnapshot? = nil, selectedNodeIDs: [String] = [], timeAxis: String? = nil, timeFrom: Double? = nil, timeTo: Double? = nil, currentTime: Double? = nil) {
        self.bookID = bookID; self.sourceHash = sourceHash; self.rendererID = rendererID; self.selectedObjectIDs = selectedObjectIDs
        self.context = context; self.visibleObjects = visibleObjects
        self.selectedNodeIDs = selectedNodeIDs
        self.timeAxis = timeAxis; self.timeFrom = timeFrom; self.timeTo = timeTo; self.currentTime = currentTime
    }
}
public struct ReadingHostToolAccess: Sendable {
    public var viewActions: Set<String>
    public var performViewAction: @Sendable (String, Data) async throws -> Data
    public var readWorkspace: (@Sendable () async throws -> ReadingWorkspaceSnapshot?)?
    public init(viewActions: Set<String>, performViewAction: @escaping @Sendable (String, Data) async throws -> Data,
                readWorkspace: (@Sendable () async throws -> ReadingWorkspaceSnapshot?)? = nil) {
        self.viewActions = viewActions; self.performViewAction = performViewAction
        self.readWorkspace = readWorkspace
    }
}
/// The host prepares previews and may commit explicitly authorized new content.
/// Approval/commit credentials are never model tools or arguments.
public struct ReadingProposalToolAccess: Sendable {
    public var proposalTools: Set<String>
    public var prepare: @Sendable (String, Data) async throws -> Data
    public var currentProject: (@Sendable () async throws -> BookProject?)?
    public init(proposalTools: Set<String>, prepare: @escaping @Sendable (String, Data) async throws -> Data,
                currentProject: (@Sendable () async throws -> BookProject?)? = nil) {
        self.proposalTools = proposalTools; self.prepare = prepare
        self.currentProject = currentProject
    }
}

enum ReadingQueryToolCatalog {
    static let readNames: Set<String> = ["capabilities_list", "book_schema_get", "source_outline", "source_search", "source_read", "reading_coverage_get",
        "objects_search", "object_get", "relations_list", "events_query", "entity_history_get", "documents_list", "documents_search", "document_read",
        "conversation_search", "conversation_read", "workspace_context_get", "visible_objects_list"]
    static let viewNames: Set<String> = ["view_select", "view_focus", "view_set_time_window", "map_fit_objects", "graph_focus", "panel_present"]
    static let proposalNames: Set<String> = ["knowledge_changes_propose", "graph_changes_propose", "document_changes_propose", "book_scheme_propose"]
    static func function(_ name: String, _ description: String, _ fields: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "additionalProperties": false, "properties": fields, "required": required]]]
    }
    static let string: [String: Any] = ["type": "string", "maxLength": 400]
    static let ids: [String: Any] = ["type": "array", "items": string, "maxItems": 128]
    static let integer: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 1_000_000_000]
    static let paging: [String: Any] = ["offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 20]]
    static func schemas(snapshot: ReadingQuerySnapshot, host: ReadingHostToolAccess?, proposals: ReadingProposalToolAccess?) -> [[String: Any]] {
        let base = ReadingQuerySession.tools.filter { tool in
            let name = (tool["function"] as? [String: Any])?["name"] as? String ?? ""
            if name.hasPrefix("source_") { return !snapshot.sources.isEmpty }
            if ["documents_list", "documents_search", "document_read"].contains(name) { return !snapshot.documents.isEmpty }
            return true
        }
        var query = paging; query["query"] = string; query["typeIDs"] = ids
        var object = ["id": string]; object["expectedHash"] = string
        var relation = paging; relation["objectID"] = string
        var event = paging; event["entityID"] = string; event["placeID"] = string
        let time: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
            "calendar": string, "year": ["type": "integer", "minimum": -1_000_000_000_000, "maximum": 1_000_000_000_000],
            "month": ["type": "integer", "minimum": 1, "maximum": 12], "day": ["type": "integer", "minimum": 1, "maximum": 31], "narrativeOrder": integer]]
        relation["at"] = time; event["at"] = time
        var entity = paging; entity["entityID"] = string; entity["at"] = time
        var result = base + [
            function("capabilities_list", "列本次实际加载的能力和权限；可用schemaFor查询跨组原子变更的结构，不开启新权限。", ["schemaFor": ["type": "string", "enum": ["knowledge", "graph", "documents", "bookScheme"]]]),
            function("book_schema_get", "按section分页读本书类型/方法/视图/画布节点目录；operations仅列本次已应用回执的完整idMap。不传section只返目录计数，配置与布局不是原书事实。", paging.merging(["section": ["type": "string", "enum": ["types", "methods", "workflowActions", "views", "profile", "graph", "operations"]]]) { _, next in next }),
            function("workspace_context_get", "读取宿主真实界面快照。没有接入时明确unsupported；不根据项目数据猜屏幕。"),
            function("visible_objects_list", "仅返回渲染器给出的真实可见对象ID；范围外对象隐藏，可见不等于正文已读。", paging)
        ]
        if !snapshot.sources.isEmpty {
            result += [function("reading_coverage_get", "本次范围的实际处理状态/缺口；查询不增加覆盖，不证明理解无遗漏。", paging),
                function("objects_search", "按名称/别名/概述和类型检索范围内对象；索引不是独立证据。", query),
                function("object_get", "读取一个范围内统一对象，返回版本、字段、来源；不自动读取挂载Markdown。", object, required: ["id"]),
                function("relations_list", "查询对象的有证据关系和可见有效期，不泄露范围外对象；时间未知不当作当前成立。", relation, required: ["objectID"]),
                function("events_query", "按人物/地点/时间查询范围内事件；保留个人参与时间的不确定性，参与事件不推出位置。", event),
                function("entity_history_get", "查询一个实体的有证据出现/参与/关系；footprints是明确出现点，不推造连续路线。", entity, required: ["entityID"])]
        }
        if let host {
            let fields: [String: Any] = ["rendererID": string, "objectID": string, "anchorID": string, "documentID": string, "nodeID": string,
                "objectIDs": ids, "nodeIDs": ids, "panelID": string, "state": ["type": "string", "enum": ["open", "collapse", "close"]], "at": time,
                "from": ["type": "number"], "to": ["type": "number"]]
            for name in host.viewActions.intersection(viewNames).sorted() {
                result.append(function(name, "执行宿主授予的本次视图操作；不修改原文、笔记、知识或保存的节点坐标；相机/界面偏好可记忆且可重置。结果以宿主真实回执为准。", fields))
            }
        }
        // Typed proposal schemas are added separately when the host grants a group.
        if let proposals { result += ReadingProposalSchemas.schemas(names: proposals.proposalTools.intersection(proposalNames)) }
        return result
    }
}

extension ReadingQuerySession {
    /// Identity can be reused when this scope has a genuine appearance. Aggregate
    /// descriptions and attributes backed by other scopes are withheld.
    func isIdentityStub(_ id: String) -> Bool {
        guard let project else { return false }
        let evidence = project.entities.first(where: { $0.id == id })?.evidence
            ?? project.events.first(where: { $0.id == id })?.evidence ?? []
        return evidence.contains(where: snapshot.admits) && !evidence.allSatisfy(snapshot.admits)
    }
    func identityStubIDs() -> Set<String> {
        guard let project else { return [] }
        var result = Set<String>()
        for entity in project.entities where entity.evidence.contains(where: snapshot.admits) && !entity.evidence.allSatisfy(snapshot.admits) { result.insert(entity.id) }
        for event in project.events where event.evidence.contains(where: snapshot.admits) && !event.evidence.allSatisfy(snapshot.admits) { result.insert(event.id) }
        return result
    }
    func scopedKnowledgeProject() -> BookProject? {
        guard var project else { return nil }
        func permitted(_ evidence: [Evidence]) -> Bool {
            !evidence.isEmpty && evidence.allSatisfy(snapshot.admits)
        }
        project.entities = project.entities.compactMap { original in
            let local = original.evidence.filter(snapshot.admits)
            guard !local.isEmpty else { return nil }
            var value = original
            if local.count != original.evidence.count {
                value.summary = ""; value.properties = [:]
                value.latitude = nil; value.longitude = nil; value.locationNote = nil
                value.aliases = value.aliases.filter { alias in local.contains { $0.quote.contains(alias) } }
                if !local.contains(where: { $0.quote.contains(value.name) }) { value.name = value.aliases.first ?? "本段关联实体" }
            }
            value.evidence = local
            return value
        }
        project.events = project.events.compactMap { original in
            let local = original.evidence.filter(snapshot.admits)
            guard !local.isEmpty else { return nil }
            var value = original
            if local.count != original.evidence.count {
                value.summary = ""; value.dateText = "时间待考"; value.startYear = nil; value.endYear = nil
                value.placeIDs = []; value.participantIDs = []
                if !local.contains(where: { $0.quote.contains(value.name) }) { value.name = "本段关联事件" }
            }
            value.evidence = local
            return value
        }
        let visible = ReadingSpoilerProjection.Context(project: project, allowedUnitIDs: allowsFullIdentity ? nil : Set(snapshot.unitIDs))
        project.entities = project.entities.compactMap { visible.entity($0) }
        project.events = project.events.compactMap { visible.event($0) }
        project.relations = project.relations.filter { permitted($0.evidence) }
        project.documents = snapshot.documents
        let anchors = ((project.readingExperience?.anchors ?? []) + (project.temporalKnowledge?.anchors ?? [])).filter {
            permitted([Evidence(unitID: $0.unitID, quote: $0.quote)])
        }
        let anchorIDs = Set(anchors.map(\.id))
        if project.readingExperience != nil { project.readingExperience?.anchors = anchors }
        if var temporal = project.temporalKnowledge {
            temporal.anchors = anchors
            func permits(_ ids: [String]) -> Bool { !ids.isEmpty && Set(ids).isSubset(of: anchorIDs) }
            temporal.presences = temporal.presences.filter { permits($0.sourceAnchorIDs) }
            temporal.participations = temporal.participations.filter { permits($0.sourceAnchorIDs) }
            temporal.eventMetadata = temporal.eventMetadata.filter { permits($0.sourceAnchorIDs) }
            temporal.relationMetadata = temporal.relationMetadata.filter { permits($0.sourceAnchorIDs) }
            project.temporalKnowledge = temporal
        }
        return project
    }
    mutating func recordReturnedEvidence(_ result: String) throws {
        guard let data = result.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return }
        let sources = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.unitID, $0.text) })
        func scan(_ value: Any, depth: Int) {
            guard depth < 32 else { return }
            if let object = value as? [String: Any] {
                if let id = object["unitID"] as? String, let quote = object["quote"] as? String, !quote.isEmpty,
                   let source = sources[id], let range = source.range(of: quote, options: .literal), source[range].utf8.elementsEqual(quote.utf8) {
                    sourceExcerpts.append((id, quote))
                }
                for child in object.values { scan(child, depth: depth + 1) }
            } else if let list = value as? [Any] { for child in list { scan(child, depth: depth + 1) } }
        }
        scan(root, depth: 0)
    }
    mutating func executeExtended(name: String, arguments: [String: Any], maximumBytes: Int) async throws -> String {
        if ["workspace_context_get", "visible_objects_list"].contains(name), let refresh = hostTools?.readWorkspace {
            workspace = try await refresh(); try Task.checkCancellation()
        }
        if ReadingQueryToolCatalog.viewNames.contains(name), let hostTools, hostTools.viewActions.contains(name) {
            guard maximumBytes >= 1024 else { return try json(["ok": false, "budgetLimited": true, "message": "没有足够空间返回界面操作回执，未执行。"] ) }
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            try validateViewArguments(arguments)
            let returned = try await hostTools.performViewAction(name, data)
            try Task.checkCancellation()
            let result = try hostResult(returned); hostReceipts.append(result); return result
        }
        if ReadingQueryToolCatalog.proposalNames.contains(name), let proposalAccess, proposalAccess.proposalTools.contains(name) {
            guard maximumBytes >= 4000 else { return try json(["ok": false, "budgetLimited": true, "message": "没有足够空间返回保存/提案回执，未调用宿主。"] ) }
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            try validateProposal(name: name, data: data)
            let returned = try await proposalAccess.prepare(name, data)
            let result = try hostResult(returned); hostReceipts.append(result)
            if let refresh = proposalAccess.currentProject {
                guard let fresh = try await refresh(), fresh.id == snapshot.bookID, fresh.sourceHash == snapshot.sourceHash,
                      let prior = project, fresh.units.count == prior.units.count,
                      zip(fresh.units, prior.units).allSatisfy({ pair in pair.0 == pair.1 && pair.0.text.utf8.elementsEqual(pair.1.text.utf8) }) else { throw invalid("宿主操作后原书或OCR版本改变；原提案/回执保留，停止混用不同版本。") }
                project = fresh
                refreshTaskCreatedNodes(in: fresh)
            }
            try Task.checkCancellation()
            return result
        }
        guard let project else { return try json(["ok": false, "status": "unsupported", "message": "宿主尚未连接该读取能力。"] ) }
        let scoped = scopedKnowledgeProject() ?? project
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs))
        // Construct this index once, rather than rebuilding it per result row.
        // Previous sources stay derived context, never current citation grants.
        let reuse = ["objects_search", "object_get"].contains(name) ? SavedKnowledgeReuse(project: project, currentUnitIDs: Set(snapshot.unitIDs),
            currentSlices: Dictionary(snapshot.sources.map { ($0.unitID, $0.text) }, uniquingKeysWith: { first, _ in first })) : nil
        switch name {
        case "capabilities_list":
            if let group = arguments["schemaFor"] as? String {
                guard proposalAccess != nil else { throw invalid("本次未授予提案能力。") }
                let schema: [String: Any]
                switch group { case "knowledge": schema = ReadingProposalSchemas.knowledge; case "graph": schema = ReadingProposalSchemas.graph
                case "documents": schema = ReadingProposalSchemas.documents; case "bookScheme": schema = ReadingProposalSchemas.bookScheme; default: throw invalid("未知提案组。") }
                return try json(["ok": true, "group": group, "schema": schema, "note": "只是结构说明，不是授权或提交。"])
            }
            let schemas = ReadingQueryToolCatalog.schemas(snapshot: snapshot, host: hostTools, proposals: proposalAccess)
            return try json(["ok": true, "tools": schemas.compactMap { ($0["function"] as? [String: Any])?["name"] }, "scope": snapshot.scope.rawValue,
                "writes": proposalAccess == nil ? "disabled" : "host_controlled_proposals", "workspace": workspace != nil, "visibleObjects": workspace?.visibleObjects != nil])
        case "book_schema_get":
            return try schemaSection(arguments, scoped: scoped, maximumBytes: maximumBytes)
        case "reading_coverage_get":
            return try page(snapshot.unitIDs.map { id in ["id": id, "status": project.coverage[id]?.status.rawValue ?? "pending", "warning": project.units.first { $0.id == id }?.warning as Any? ?? NSNull()] as [String: Any] }, arguments, maximumBytes)
        case "objects_search":
            let query = arguments["query"] as? String ?? "", types = Set(arguments["typeIDs"] as? [String] ?? [])
            guard query.count <= 400 else { throw invalid("检索词过长。") }
            let identityStubs = identityStubIDs()
            let objects = try TemporalKnowledgeRuntime.objects(in: scoped, boundary: boundary).filter {
                let named = ([$0.name, $0.summary] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(query) }
                let localMention = identityStubs.contains($0.id) && $0.evidence.contains { $0.quote.localizedCaseInsensitiveContains(query) }
                let earlier = (reuse?.record(id: $0.id)?["summary"] as? String)?.localizedCaseInsensitiveContains(query) == true
                return (types.isEmpty || types.contains($0.typeID)) && (query.isEmpty || named || localMention || earlier)
            }
            var rows = objects.map { object -> [String: Any] in
                var row: [String: Any] = ["id": object.id, "typeID": object.typeID, "kind": object.kind.rawValue, "name": object.name, "summary": String(object.summary.prefix(400)), "version": object.version, "identityOnly": identityStubs.contains(object.id),
                    "sourceUnitIDs": Array(Set(object.evidence.map(\.unitID))).sorted()]
                if let saved = reuse?.record(id: object.id) { row["previouslySaved"] = saved }
                return row
            }
            let returned = Set(objects.map(\.id))
            for candidate in PluginEngine.analysisIdentityCandidates(project, allowedUnitIDs: Set(snapshot.unitIDs), occurrenceTexts: snapshot.sources.map(\.text)) where !returned.contains(candidate.id) {
                guard types.isEmpty || types.contains(candidate.typeID), let saved = reuse?.record(id: candidate.id),
                      query.isEmpty || ([candidate.name] + candidate.aliases + [saved["summary"] as? String ?? ""]).contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { continue }
                rows.append(["id": candidate.id, "typeID": candidate.typeID, "kind": candidate.kind, "name": candidate.name, "summary": "", "identityOnly": true,
                    "sourceUnitIDs": [], "previouslySaved": saved, "notice": "当前原文出现同名/称谓，先核对是否为同一对象；旧简介不能当作本页已核实的新事实。"])
            }
            let pageResult = try page(rows, arguments, maximumBytes)
            if !query.isEmpty, rows.count < 3,
               var output = try JSONSerialization.jsonObject(with: Data(pageResult.utf8)) as? [String: Any] {
                let returnedIDs = Set(rows.compactMap { $0["id"] as? String })
                var suggestions = try KnowledgeIdentitySuggestions.find(query, in: scoped, allowedUnitIDs: Set(snapshot.unitIDs), typeIDs: types, limit: 6)
                    .filter { !returnedIDs.contains($0.id) }.map { try encoded($0) }
                while !suggestions.isEmpty {
                    output["identitySuggestions"] = suggestions
                    output["identitySuggestionNotice"] = "仅为本次可见范围内的相近名称候选；先核对身份，不自动合并，也不授予新事实或原文引用权限。"
                    let result = try json(output)
                    if result.utf8.count <= maximumBytes { return result }
                    suggestions.removeLast()
                }
            }
            return pageResult
        case "object_get":
            let id = try identifier(arguments)
            guard let object = try TemporalKnowledgeRuntime.object(id: id, in: scoped, boundary: boundary) else {
                guard let candidate = PluginEngine.analysisIdentityCandidates(project, allowedUnitIDs: Set(snapshot.unitIDs), occurrenceTexts: snapshot.sources.map(\.text)).first(where: { $0.id == id }), let saved = reuse?.record(id: id) else { throw invalid("对象不在本次原文范围内。") }
                guard arguments["expectedHash"] == nil else { throw invalid("当前只是待核对身份候选，没有可用于变更的对象版本。") }
                return try json(["ok": true, "object": ["id": candidate.id, "name": candidate.name, "typeID": candidate.typeID], "identityOnly": true, "previouslySaved": saved,
                    "documentBodiesProvided": false, "note": "当前同名身份尚待核对；旧简介是派生资料，不扩大本次原文与引用范围。"])
            }
            try checkHash(arguments, actual: object.version)
            var row: [String: Any] = ["ok": true, "object": try encoded(object), "documentBodiesProvided": false,
                "identityOnly": isIdentityStub(object.id), "note": "稳定id可复用关联；跨范围聚合属性隐藏，安全旧简介单列为派生资料。只有本范围实际返回原文可作本次引用。"]
            if let saved = reuse?.record(id: object.id) { row["previouslySaved"] = saved }
            return try json(row)
        case "relations_list":
            guard let id = arguments["objectID"] as? String else { throw invalid("缺少objectID。") }
            let rows = try TemporalKnowledgeRuntime.relations(objectID: id, in: scoped, at: timePoint(arguments), boundary: boundary)
            return try page(rows.map { try encoded($0) as? [String: Any] ?? [:] }, arguments, maximumBytes)
        case "events_query":
            let rows = try TemporalKnowledgeRuntime.events(in: scoped, entityID: arguments["entityID"] as? String, placeID: arguments["placeID"] as? String, at: timePoint(arguments), boundary: boundary)
            return try page(rows.map { try encoded($0) as? [String: Any] ?? [:] }, arguments, maximumBytes)
        case "entity_history_get":
            guard let id = arguments["entityID"] as? String else { throw invalid("缺少entityID。") }
            let result = try TemporalKnowledgeRuntime.entitySnapshot(entityID: id, in: scoped, at: timePoint(arguments), boundary: boundary)
            var rows: [[String: Any]] = []
            func append<T: Encodable>(_ kind: String, _ values: [T]) throws { rows += try values.map { ["kind": kind, "value": try encoded($0)] } }
            try append("presence", result.presences); try append("uncertainPresence", result.uncertainPresences)
            try append("participation", result.participations); try append("uncertainParticipation", result.uncertainParticipations)
            try append("event", result.events); try append("relation", result.relations)
            return try page(rows, arguments, maximumBytes)
        case "workspace_context_get":
            guard let workspace else { return try json(["ok": false, "status": "unsupported", "message": "宿主尚未提供实际界面快照。"] ) }
            try validateWorkspace(workspace)
            let admitted = Set(try TemporalKnowledgeRuntime.objects(in: scoped, boundary: boundary).map(\.id)).union(snapshot.documentIDs)
            return try json(["ok": true, "rendererID": workspace.rendererID as Any? ?? NSNull(), "selectedObjectIDs": workspace.selectedObjectIDs.filter(admitted.contains),
                "selectedNodeIDs": workspace.selectedNodeIDs.filter { admitsNode($0, admitted: admitted, project: project) },
                "context": ["page": workspace.context?.page as Any? ?? NSNull(), "timeFrom": workspace.context?.timeFrom as Any? ?? NSNull(), "timeTo": workspace.context?.timeTo as Any? ?? NSNull()],
                "timeAxis": workspace.timeAxis as Any? ?? NSNull(), "timeFrom": workspace.timeFrom as Any? ?? NSNull(), "timeTo": workspace.timeTo as Any? ?? NSNull(), "currentTime": workspace.currentTime as Any? ?? NSNull(),
                "note": "宿主界面状态仅用于定位，不是原书事实；范围外对象已隐藏。"])
        case "visible_objects_list":
            guard let workspace, let visible = workspace.visibleObjects else { return try json(["ok": false, "status": "unsupported", "message": "当前渲染器未接入真实可见对象快照；没有从项目数据猜测。"] ) }
            try validateWorkspace(workspace)
            let admitted = Set(try TemporalKnowledgeRuntime.objects(in: scoped, boundary: boundary).map(\.id)).union(snapshot.documentIDs)
            var rows = visible.objectIDs.filter(admitted.contains).map { ["objectID": $0, "rendererID": visible.rendererID, "partial": visible.partial] as [String: Any] }
            rows += visible.nodeIDs.filter { admitsNode($0, admitted: admitted, project: project) }.map { ["nodeID": $0, "rendererID": visible.rendererID, "partial": visible.partial] as [String: Any] }
            return try page(rows, arguments, maximumBytes)
        default: throw invalid("本次问答未注册该工具。")
        }
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    func admitsNode(_ id: String, admitted: Set<String>, project: BookProject) -> Bool {
        guard let node = project.nodes.first(where: { $0.id == id }) else { return false }
        return admitted.contains(node.targetID) || !(Set(node.documentIDs ?? []).intersection(admitted)).isEmpty
            || snapshot.authorizedNodeIDs.contains(id) || taskCreatedNodeIDs.contains(id)
    }
    private mutating func refreshTaskCreatedNodes(in project: BookProject) {
        let operations = Set(hostReceipts.compactMap { value -> String? in
            guard let raw = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any], raw["applied"] as? Bool == true else { return nil }
            return raw["operationID"] as? String
        })
        // The callback's claim alone is insufficient. A real transaction receipt
        // must show that this task created the physical node in this exact book.
        let physical = Set(project.nodes.filter { $0.isStandalone == true && $0.targetID == $0.id && ($0.documentIDs ?? []).isEmpty }.map(\.id))
        taskCreatedNodeIDs = Set((project.controlledChanges?.receipts ?? []).filter {
            $0.originBookID == snapshot.bookID && operations.contains($0.operationID) && $0.undoneAt == nil
        }.flatMap(\.patches).filter { $0.collection == .nodes && $0.before == nil && $0.after != nil }.map(\.id)).intersection(physical)
    }
    private func schemaSection(_ arguments: [String: Any], scoped: BookProject, maximumBytes: Int) throws -> String {
        guard let project else { throw invalid("没有当前项目。") }
        let methods = PluginEngine.activeMethods(in: project), actions = PluginEngine.activeWorkflowActions
        guard let section = arguments["section"] as? String else {
            return try json(["ok": true, "sections": ["types": project.types.count, "methods": methods.count, "workflowActions": actions.count,
                "views": project.views.count, "profile": project.temporalKnowledge?.profile == nil ? 0 : 1, "graph": project.nodes.count, "operations": hostReceipts.count],
                "note": "按section分页读取；声明与读者偏好不是原文事实，graph只返回本次范围关联的物理节点，不提供文档正文。"])
        }
        var rows: [[String: Any]]
        func values<T: Encodable>(_ items: [T]) throws -> [[String: Any]] { try items.map { try encoded($0) as? [String: Any] ?? [:] } }
        switch section {
        case "types": rows = try values(project.types)
        case "methods": rows = try values(methods)
        case "workflowActions": rows = try values(actions)
        case "views": rows = try values(project.views)
        case "profile":
            if let profile = project.temporalKnowledge?.profile { rows = [try encoded(profile) as? [String: Any] ?? [:]] } else { rows = [] }
        case "graph":
            let admitted = Set(try TemporalKnowledgeRuntime.objects(in: scoped, boundary: KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs))).map(\.id)).union(snapshot.documentIDs)
            let nodes = project.nodes.filter { admitsNode($0.id, admitted: admitted, project: project) }, nodeIDs = Set(nodes.map(\.id))
            rows = try nodes.map { node in
                var value = try encoded(node) as? [String: Any] ?? [:]
                let targetShared = admitted.contains(node.targetID) || node.isStandalone == true && node.targetID == node.id || node.targetID.isEmpty
                let documents = node.documentIDs ?? []
                let sharedDocuments = documents.filter { snapshot.documentIDs.contains($0) }
                if !targetShared { value.removeValue(forKey: "targetID") }
                if sharedDocuments.count != documents.count { value["documentIDs"] = sharedDocuments }
                return ["kind": "node", "value": value, "contentRestricted": !targetShared || sharedDocuments.count != documents.count,
                    "note": "布局授权不共享范围外目标或文档正文。"] as [String: Any]
            }
            rows += try project.edges.filter { nodeIDs.contains($0.fromID) && nodeIDs.contains($0.toID) }.map { ["kind": "edge", "value": try encoded($0)] }
            // Group titles can reveal unrelated contents; only fully admitted groups are returned.
            rows += try (project.graphGroups ?? []).filter { !$0.nodeIDs.isEmpty && Set($0.nodeIDs).isSubset(of: nodeIDs) && $0.childGroupIDs.isEmpty }.map { ["kind": "group", "value": try encoded($0)] }
        case "operations":
            let operationIDs = Set(hostReceipts.compactMap { value -> String? in
                guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["applied"] as? Bool == true else { return nil }
                return object["operationID"] as? String
            })
            rows = (project.controlledChanges?.receipts ?? []).filter { operationIDs.contains($0.operationID) }.flatMap { receipt in
                receipt.idMap.keys.sorted().map { ["operationID": receipt.operationID, "clientID": $0, "id": receipt.idMap[$0] ?? "", "undone": receipt.undoneAt != nil] as [String: Any] }
            }
        default: throw invalid("未知目录section。")
        }
        return try page(rows, arguments, maximumBytes)
    }
    private func validateViewArguments(_ arguments: [String: Any]) throws {
        guard let project, let scoped = scopedKnowledgeProject() else { throw invalid("没有当前范围项目，不能定位对象。") }
        let admitted = Set(try TemporalKnowledgeRuntime.objects(in: scoped, boundary: KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs))).map(\.id)).union(snapshot.documentIDs)
        let objects = (arguments["objectIDs"] as? [String] ?? []) + [arguments["objectID"] as? String, arguments["documentID"] as? String].compactMap { $0 }
        let nodes = (arguments["nodeIDs"] as? [String] ?? []) + [arguments["nodeID"] as? String].compactMap { $0 }
        guard objects.allSatisfy(admitted.contains), nodes.allSatisfy({ admitsNode($0, admitted: admitted, project: project) }) else { throw invalid("视图目标不在本次获准范围内；请切换范围后再定位。") }
        if let anchorID = arguments["anchorID"] as? String {
            let anchors = (scoped.readingExperience?.anchors ?? []) + (scoped.temporalKnowledge?.anchors ?? [])
            guard anchors.contains(where: { $0.id == anchorID }) else { throw invalid("原文锚点不在本次获准范围内。") }
        }
    }
    private func hostResult(_ data: Data) throws -> String {
        guard data.count <= 16_000, (try? JSONSerialization.jsonObject(with: data)) is [String: Any], let text = String(data: data, encoding: .utf8) else { throw invalid("宿主工具必须返回有界JSON对象回执。") }; return text
    }
    private func validateWorkspace(_ value: ReadingWorkspaceSnapshot) throws {
        guard value.bookID == snapshot.bookID, value.sourceHash == snapshot.sourceHash, value.selectedObjectIDs.count <= 1024,
              value.selectedNodeIDs.count <= 1024, (value.visibleObjects?.objectIDs.count ?? 0) <= 10_000,
              (value.visibleObjects?.nodeIDs.count ?? 0) <= 10_000,
              [value.timeFrom, value.timeTo, value.currentTime].compactMap({ $0 }).allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000_000 }) else { throw invalid("界面快照属于其他书或超过界限。") }
    }
    private func timePoint(_ arguments: [String: Any]) throws -> TemporalQueryPoint? {
        guard let raw = arguments["at"] else { return nil }
        guard let at = raw as? [String: Any] else { throw invalid("at须为时间对象。") }
        if let narrative = at["narrativeOrder"] {
            guard at.count == 1 else { throw invalid("叙事次序不能混入历法日期。") }
            return .narrative(try number(["value": narrative], "value", fallback: 0, maximum: 1_000_000_000))
        }
        guard Set(at.keys).isSubset(of: ["calendar", "year", "month", "day"]), let calendar = at["calendar"] as? String, !calendar.isEmpty, calendar.count <= 80, let year = at["year"] as? NSNumber,
              CFGetTypeID(year) != CFBooleanGetTypeID(),
              year.doubleValue.isFinite, year.doubleValue.rounded() == year.doubleValue, abs(year.doubleValue) <= 1_000_000_000_000 else { throw invalid("数字时间必须给出明确历法和年份。") }
        let month = try at["month"].map { try number(["value": $0], "value", fallback: 0, maximum: 12) }
        let day = try at["day"].map { try number(["value": $0], "value", fallback: 0, maximum: 31) }
        let date = TemporalDate(year: year.intValue, month: month, day: day)
        try TemporalKnowledgeRuntime.validateExtent(TemporalExtent(sourceText: "查询时间", calendar: calendar, start: date,
            precision: day != nil ? .day : (month != nil ? .month : .year), uncertainty: .exact))
        return .date(date, calendar: calendar)
    }
}
