import Foundation

enum ControlledChangeBuilder {
    static func prepare(_ batch: ControlledChangeBatch, grant: ControlledWriteGrant, project: BookProject, documents: [String: Data], proposalID: String, operationID: String, baseRevision: String) throws -> PreparedControlledChange {
        guard try ControlledChangeCoding.data(batch).count <= 1_048_576 else { throw ControlledChangeError.invalid("变更提案不能超过1 MiB。") }
        var groups: [ControlledChangeGroup] = []
        if batch.knowledge != nil { groups.append(.knowledge) }; if batch.graph != nil { groups.append(.graph) }
        if batch.documents != nil { groups.append(.documents) }; if batch.bookScheme != nil { groups.append(.bookScheme) }
        guard !groups.isEmpty, Set(groups).isSubset(of: grant.permissions) else { throw ControlledChangeError.denied("本次任务没有授权这些变更组。") }
        var candidate = project, identity = ControlledIdentityMap(operationID: operationID, project: project)
        var bodies: [String: Data] = [:], beforeBodies: [String: Data] = [:], previews: [ControlledDocumentPreview] = []
        let creates = batch.documents?.create ?? [], edits = batch.documents?.edits ?? []
        let graph = batch.graph ?? ControlledGraphChanges()
        guard creates.count <= 16, edits.count <= 16, Set(edits.map(\.documentID)).count == edits.count else { throw ControlledChangeError.invalid("文档批次过大或重复编辑同一文档。") }
        for value in creates { try identity.register(value.clientID, kind: "document") }
        for value in graph.createNodes ?? [] { try identity.register(value.clientID, kind: "node") }
        for value in graph.connections ?? [] { try identity.register(value.clientID, kind: "edge") }
        for value in graph.createGroups ?? [] { try identity.register(value.clientID, kind: "group") }
        for value in creates {
            try ControlledChangeCoding.text(value.title, maximum: 1600); try ControlledChangeCoding.text(value.markdown, maximum: 262_144, empty: true)
            let record = DocumentRecord(id: identity.resolve(value.clientID), title: value.title, origin: "ai-organized", linkedIDs: value.linkedIDs ?? [], evidence: value.evidence ?? [])
            try validateEvidence(record.evidence, allowed: grant.allowedUnitIDs, in: project)
            candidate.documents.append(record); let body = Data(value.markdown.utf8); bodies[record.id] = body
            previews.append(ControlledDocumentPreview(documentID: record.id, title: record.title, before: nil, after: value.markdown, expectedHash: nil, afterHash: try BookImporter.sha256(body)))
        }
        for edit in edits {
            guard grant.editableDocumentIDs.contains(edit.documentID), let index = candidate.documents.firstIndex(where: { $0.id == edit.documentID }),
                  candidate.documents[index].trashedAt == nil, let before = documents[edit.documentID], let original = String(data: before, encoding: .utf8),
                  try BookImporter.sha256(before) == edit.expectedHash.lowercased() else { throw ControlledChangeError.conflict("已有文档未获准修改、已回收或正文 hash 已变化，原稿保留。") }
            try ControlledChangeCoding.text(edit.markdown, maximum: 262_144, empty: true)
            let after = edit.mode == .append ? original + edit.markdown : edit.markdown
            guard after.utf8.count <= 16 * 1_024 * 1_024 else { throw ControlledChangeError.invalid("修改后的 Markdown 超过16 MiB。") }
            let body = Data(after.utf8)
            beforeBodies[edit.documentID] = before; bodies[edit.documentID] = body
            candidate.documents[index].updatedAt = Date()
            previews.append(ControlledDocumentPreview(documentID: edit.documentID, title: candidate.documents[index].title, before: original, after: after, expectedHash: edit.expectedHash.lowercased(), afterHash: try BookImporter.sha256(body)))
        }
        if let knowledge = batch.knowledge {
            try ControlledKnowledgeRuntime.apply(knowledge, to: &candidate, allowedUnitIDs: grant.allowedUnitIDs, requiresReceipts: grant.requiresReceipts, identity: &identity)
        }
        let newDocuments = Set(creates.map { identity.resolve($0.clientID) })
        for index in candidate.documents.indices where newDocuments.contains(candidate.documents[index].id) {
            candidate.documents[index].linkedIDs = candidate.documents[index].linkedIDs.map(identity.resolve)
        }
        if batch.graph != nil { try apply(graph, to: &candidate, identity: &identity) }
        if let scheme = batch.bookScheme { try stage(scheme, in: &candidate) }
        let patches = try diff(from: project, to: candidate)
        guard !patches.isEmpty || !bodies.isEmpty else { throw ControlledChangeError.invalid("此批次没有实际变更。") }
        let approval = !edits.isEmpty || batch.bookScheme != nil || patches.contains { $0.before != nil }
        let summary = try ControlledChangeSummary.describe(patches, from: project, to: candidate)
        let proposal = ControlledChangeProposal(id: proposalID, operationID: operationID, bookID: project.id, digest: try ControlledChangeCoding.hash(batch), baseRevision: baseRevision,
            groups: groups, requiresConfirmation: approval, idMap: identity.values, summary: summary, documents: previews)
        return PreparedControlledChange(proposal: proposal, project: candidate, bodies: bodies, beforeBodies: beforeBodies, patches: patches)
    }

    private static func apply(_ changes: ControlledGraphChanges, to project: inout BookProject, identity: inout ControlledIdentityMap) throws {
        let counts = [(changes.createNodes ?? []).count, (changes.attachments ?? []).count, (changes.connections ?? []).count, (changes.moves ?? []).count,
                      (changes.renames ?? []).count, (changes.removeNodeIDs ?? []).count, (changes.removeEdgeIDs ?? []).count, (changes.createGroups ?? []).count, (changes.moveGroups ?? []).count]
        guard counts.allSatisfy({ $0 <= 128 }), counts.reduce(0, +) <= 256 else { throw ControlledChangeError.invalid("图变更批次最多256项。") }
        let docs = Set(project.activeDocuments.map(\.id))
        let targets = docs.union(project.entities.map(\.id)).union(project.events.map(\.id)).union(project.units.map(\.id)).union(project.insights.map(\.id))
        for value in changes.createNodes ?? [] {
            try ControlledChangeCoding.text(value.title, maximum: 1600); try position(value.x, value.y)
            let id = identity.resolve(value.clientID), documents = (value.documentIDs ?? []).map(identity.resolve)
            guard !project.nodes.contains(where: { $0.id == id }), Set(documents).isSubset(of: docs), documents.count <= 64 else { throw ControlledChangeError.invalid("新节点 ID、挂载文档或数量无效。") }
            let requested = value.targetID.map(identity.resolve) ?? documents.first
            if let requested { guard targets.contains(requested) else { throw ControlledChangeError.invalid("新节点引用了不存在或已回收的对象。") } }
            var node = CanvasNode(id: id, targetID: requested ?? id, x: value.x, y: value.y)
            node.title = value.title; node.isStandalone = requested == nil
            node.documentIDs = Array(Set(documents + (requested.map { docs.contains($0) ? [$0] : [] } ?? []))).sorted()
            project.nodes.append(node)
        }
        for attachment in changes.attachments ?? [] {
            let id = identity.resolve(attachment.nodeID), documents = attachment.documentIDs.map(identity.resolve)
            let permittedDocuments = attachment.mode == .attach ? docs : Set(project.documents.map(\.id))
            guard let index = project.nodes.firstIndex(where: { $0.id == id }), documents.count <= 64, Set(documents).isSubset(of: permittedDocuments) else { throw ControlledChangeError.invalid("挂载操作引用了不存在的节点或活动文档。") }
            var node = project.nodes[index]
            var current = node.documentIDs ?? (project.documents.contains(where: { $0.id == node.targetID }) ? [node.targetID] : [])
            if attachment.mode == .attach { current = Array(Set(current + documents)).sorted() }
            else { current.removeAll { documents.contains($0) } }
            guard current.count <= 64 else { throw ControlledChangeError.invalid("一个节点最多挂载64篇文档。") }
            if node.isStandalone == true, let first = current.first { node.targetID = first; node.isStandalone = false }
            else if project.documents.contains(where: { $0.id == node.targetID }), !current.contains(node.targetID) {
                if node.title == nil { node.title = project.documents.first(where: { $0.id == node.targetID })?.title ?? "笔记节点" }
                node.targetID = current.first ?? node.id; node.isStandalone = current.isEmpty
            }
            node.documentIDs = current; project.nodes[index] = node
        }
        for rename in changes.renames ?? [] {
            try ControlledChangeCoding.text(rename.title, maximum: 1600)
            guard let index = project.nodes.firstIndex(where: { $0.id == identity.resolve(rename.nodeID) }) else { throw ControlledChangeError.invalid("要改名的节点不存在。") }
            project.nodes[index].title = rename.title
        }
        for move in changes.moves ?? [] {
            try position(move.x, move.y)
            guard let index = project.nodes.firstIndex(where: { $0.id == identity.resolve(move.nodeID) }) else { throw ControlledChangeError.invalid("要移动的节点不存在。") }
            project.nodes[index].x = move.x; project.nodes[index].y = move.y
        }
        for value in changes.createGroups ?? [] {
            try ControlledChangeCoding.text(value.title, maximum: 1600)
            var groups = project.graphGroups ?? []
            groups.append(CanvasGroup(id: identity.resolve(value.clientID), title: value.title, nodeIDs: value.nodeIDs.map(identity.resolve), childGroupIDs: value.childGroupIDs.map(identity.resolve)))
            project.graphGroups = groups
        }
        try ControlledGraphRuntime.validate(in: project)
        for move in changes.moveGroups ?? [] {
            try position(move.deltaX, move.deltaY)
            let nodes = try ControlledGraphRuntime.recursiveNodeIDs(groupID: identity.resolve(move.groupID), in: project)
            for index in project.nodes.indices where nodes.contains(project.nodes[index].id) {
                let x = project.nodes[index].x + move.deltaX, y = project.nodes[index].y + move.deltaY
                try position(x, y); project.nodes[index].x = x; project.nodes[index].y = y
            }
        }
        for value in changes.connections ?? [] {
            let from = identity.resolve(value.fromNodeID), to = identity.resolve(value.toNodeID)
            let before = Set(project.edges.map(\.id))
            var connected = try GraphConnections.connecting(from: from, to: to, label: value.label, in: project)
            if let index = connected.edges.firstIndex(where: { !before.contains($0.id) }) { connected.edges[index].id = identity.resolve(value.clientID) }
            else if let existing = connected.edges.first(where: { $0.fromID == from && $0.toID == to && $0.label.trimmingCharacters(in: .whitespacesAndNewlines) == value.label.trimmingCharacters(in: .whitespacesAndNewlines) }) { identity.values[value.clientID] = existing.id }
            project = connected
        }
        let removeNodes = Set((changes.removeNodeIDs ?? []).map(identity.resolve)), removeEdges = Set((changes.removeEdgeIDs ?? []).map(identity.resolve))
        guard removeNodes.isSubset(of: Set(project.nodes.map(\.id))), removeEdges.isSubset(of: Set(project.edges.map(\.id))) else { throw ControlledChangeError.conflict("要移除的布局节点或边已不存在。") }
        project.nodes.removeAll { removeNodes.contains($0.id) }
        project.edges.removeAll { removeEdges.contains($0.id) || removeNodes.contains($0.fromID) || removeNodes.contains($0.toID) }
        if project.graphGroups != nil { for index in project.graphGroups!.indices { project.graphGroups![index].nodeIDs.removeAll { removeNodes.contains($0) } } }
        try ControlledGraphRuntime.validate(in: project)
    }

    private static func stage(_ changes: ControlledBookSchemeChanges, in project: inout BookProject) throws {
        var proposed = project
        for type in changes.types ?? [] { try ControlledKnowledgeRuntime.appendImmutable(type, to: &proposed.types) }
        for method in changes.methods ?? [] { try ControlledKnowledgeRuntime.appendImmutable(method, to: &proposed.methods) }
        for view in changes.views ?? [] {
            if let index = proposed.views.firstIndex(where: { $0.id == view.id }) {
                guard proposed.views[index].kind == view.kind, proposed.views[index].rendererID == view.rendererID else { throw ControlledChangeError.conflict("已有视图不能改换渲染器。") }
                proposed.views[index] = view
            } else { proposed.views.append(view) }
        }
        if let plan = changes.plan { proposed.plan = plan }
        if let profile = changes.profile { var state = proposed.temporalKnowledge ?? TemporalKnowledgeState(); state.profile = profile; proposed.temporalKnowledge = state }
        project = try BookSchemeRuntime.stageAIProposal(from: project, proposed: proposed)
        project.bookSchemes?.pending?.title = "AI 整理提出的书本方案"
        project.bookSchemes?.pending?.origin = "ai-organized"
        project.bookSchemes?.pending?.notes = ["依据本次获准材料提出；不增加逐段或全文阅读覆盖。", "这里只暂存方案，采纳后才启用所选组件与方法；原书、已有回执和笔记不变。"]
    }

    private static func validateEvidence(_ evidence: [Evidence], allowed: Set<String>, in project: BookProject) throws {
        guard evidence.count <= 64 else { throw ControlledChangeError.invalid("文档依据过多。") }
        for value in evidence {
            guard allowed.contains(value.unitID), let unit = project.units.first(where: { $0.id == value.unitID }), !value.quote.isEmpty,
                  unit.text.range(of: value.quote, options: .literal) != nil else { throw ControlledChangeError.denied("文档依据超出本次获准原文。") }
        }
    }
    private static func position(_ x: Double, _ y: Double) throws { guard x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { throw ControlledChangeError.invalid("画布坐标超出安全范围。") } }

    static func diff(from old: BookProject, to new: BookProject) throws -> [ControlledRecordPatch] {
        var patches: [ControlledRecordPatch] = []
        func records<T: Codable & Identifiable>(_ before: [T], _ after: [T], _ collection: ControlledChangeCollection) throws where T.ID == String {
            let left = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), right = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Set(left.keys).union(right.keys).sorted() {
                let first = try left[id].map(ControlledChangeCoding.data), last = try right[id].map(ControlledChangeCoding.data)
                if first != last { patches.append(ControlledRecordPatch(collection: collection, id: id, before: first, after: last)) }
            }
        }
        try records(old.types, new.types, .types); try records(old.entities, new.entities, .entities); try records(old.events, new.events, .events)
        try records(old.relations, new.relations, .relations); try records(old.nodes, new.nodes, .nodes); try records(old.edges, new.edges, .edges)
        try records(old.graphGroups ?? [], new.graphGroups ?? [], .graphGroups); try records(old.documents, new.documents, .documents)
        try records(old.temporalKnowledge?.anchors ?? [], new.temporalKnowledge?.anchors ?? [], .temporalAnchors)
        try records(old.temporalKnowledge?.presences ?? [], new.temporalKnowledge?.presences ?? [], .presences)
        try records(old.temporalKnowledge?.participations ?? [], new.temporalKnowledge?.participations ?? [], .participations)
        try records(old.temporalKnowledge?.eventMetadata ?? [], new.temporalKnowledge?.eventMetadata ?? [], .eventMetadata)
        try records(old.temporalKnowledge?.relationMetadata ?? [], new.temporalKnowledge?.relationMetadata ?? [], .relationMetadata)
        try records(old.readingExperience?.anchors ?? [], new.readingExperience?.anchors ?? [], .experienceAnchors)
        try records(old.readingExperience?.layers ?? [], new.readingExperience?.layers ?? [], .layers)
        try records(old.readingExperience?.alignments ?? [], new.readingExperience?.alignments ?? [], .alignments)
        let before = try old.bookSchemes.map(ControlledChangeCoding.data), after = try new.bookSchemes.map(ControlledChangeCoding.data)
        if before != after { patches.append(ControlledRecordPatch(collection: .bookSchemes, id: "book-schemes", before: before, after: after)) }
        return patches
    }
}

public enum ControlledGraphRuntime {
    public static func validate(in project: BookProject) throws {
        let documents = Set(project.documents.map(\.id)), nodes = Set(project.nodes.map(\.id)), groups = project.graphGroups ?? []
        for node in project.nodes {
            if let title = node.title { try ControlledChangeCoding.text(title, maximum: 1600) }
            if node.isStandalone == true { guard node.targetID == node.id, node.title != nil, (node.documentIDs ?? []).isEmpty else { throw ControlledChangeError.invalid("独立节点不能伪装成知识对象或保留隐藏挂载。") } }
            if let ids = node.documentIDs { guard ids.count <= 64, Set(ids).count == ids.count, Set(ids).isSubset(of: documents) else { throw ControlledChangeError.invalid("节点挂载了不存在或重复的文档。") } }
        }
        guard groups.count <= 10_000, Set(groups.map(\.id)).count == groups.count else { throw ControlledChangeError.invalid("图分组重复或过多。") }
        let groupIDs = Set(groups.map(\.id))
        for group in groups {
            try ControlledChangeCoding.requireID(group.id); try ControlledChangeCoding.text(group.title, maximum: 1600)
            guard group.nodeIDs.count <= 10_000, Set(group.nodeIDs).count == group.nodeIDs.count, Set(group.nodeIDs).isSubset(of: nodes),
                  group.childGroupIDs.count <= 10_000, Set(group.childGroupIDs).count == group.childGroupIDs.count, Set(group.childGroupIDs).isSubset(of: groupIDs) else { throw ControlledChangeError.invalid("图分组含悬空或重复成员。") }
        }
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var finished = Set<String>()
        for group in groups where !finished.contains(group.id) {
            var active = Set<String>(), stack: [(String, Bool)] = [(group.id, false)]
            while let (id, exiting) = stack.popLast() {
                if exiting { active.remove(id); finished.insert(id); continue }
                if finished.contains(id) { continue }
                guard active.insert(id).inserted else { throw ControlledChangeError.invalid("图分组不能成环。") }
                stack.append((id, true)); for child in byID[id]?.childGroupIDs ?? [] { stack.append((child, false)) }
            }
        }
    }
    public static func recursiveNodeIDs(groupID: String, in project: BookProject) throws -> Set<String> {
        let groups = Dictionary((project.graphGroups ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard groups[groupID] != nil else { throw ControlledChangeError.invalid("要移动的图分组不存在。") }
        var result = Set<String>(), visited = Set<String>(), pending = [groupID]
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let group = groups[id] else { continue }
            result.formUnion(group.nodeIDs); pending.append(contentsOf: group.childGroupIDs)
        }
        return result
    }
}
