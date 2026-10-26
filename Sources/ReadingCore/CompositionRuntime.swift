import Foundation

/// A finite, read-only query language over canonical book records. A declaration
/// cannot change the caller's source boundary or run scripts, requests or writers.
public enum CompositionRuntime {
    /// A validated, immutable input for one publication. Callers cannot pair an
    /// already validated declaration with a different book or source boundary.
    public struct PreparedCompositionInput: Sendable {
        fileprivate let definition: CompositionDefinition
        fileprivate let bases: [CompositionScope: ScopeBase]
        fileprivate let mapSourceIDs: Set<String>
    }

    public static func prepare(_ definition: CompositionDefinition, in project: BookProject, context: ReadingContext? = nil,
                               currentScope: CompositionCurrentScope = .automatic,
                               boundary: KnowledgeReadBoundary = .all) throws -> PreparedCompositionInput {
        try Task.checkCancellation()
        try validate(definition, in: project)
        var bases: [CompositionScope: ScopeBase] = [:]
        for source in definition.sources where bases[source.scope] == nil {
            try Task.checkCancellation()
            bases[source.scope] = try scoped(source.scope, project: project, context: context, currentScope: currentScope, boundary: boundary)
        }
        return PreparedCompositionInput(definition: definition, bases: bases,
            mapSourceIDs: Set(definition.parts.filter { $0.primitive == .map }.map(\.sourceID)))
    }

    public static func validate(_ definition: CompositionDefinition, in project: BookProject) throws {
        guard definition.version == 1 else { throw invalid("尚不支持这个组合组件版本。") }
        guard (1...12).contains(definition.sources.count), (1...24).contains(definition.parts.count), (1...48).contains(definition.layout.count),
              try JSONEncoder().encode(definition).count <= 65_536 else { throw invalid("组合组件超过数据源、元件、布局或64KB上限。") }
        try unique(definition.sources.map(\.id)); try unique(definition.parts.map(\.id)); try unique(definition.layout.map(\.id))
        let sources = Dictionary(uniqueKeysWithValues: definition.sources.map { ($0.id, $0) })
        let parts = Dictionary(uniqueKeysWithValues: definition.parts.map { ($0.id, $0) })
        let layouts = Dictionary(uniqueKeysWithValues: definition.layout.map { ($0.id, $0) })
        let types = Set(project.types.map(\.id)).union(["event", "document"])
        let declaredFields = Set(project.types.flatMap { $0.fields.map(\.key) })
        for source in definition.sources {
            try identifier(source.selectionGroup); try identifier(source.timeGroup)
            guard (1...200).contains(source.limit), source.typeIDs.count <= 32, Set(source.typeIDs).count == source.typeIDs.count,
                  Set(source.typeIDs).isSubset(of: types), source.filters.count <= 8 else { throw invalid("组合数据源的类型、筛选或数量无效。") }
            for filter in source.filters {
                let builtin = ["name", "summary", "typeID", "kind", "origin", "label"]
                let custom = filter.field.hasPrefix("properties.") && declaredFields.contains(String(filter.field.dropFirst(11)))
                guard builtin.contains(filter.field) || custom else { throw invalid("组合筛选只能引用已有的声明字段。") }
                guard filter.field != "label" || source.collection == .relations else { throw invalid("label筛选只适用于关系数据源。") }
                guard (filter.value?.utf8.count ?? 0) <= 1000, (filter.values?.count ?? 0) <= 16,
                      filter.values?.allSatisfy({ $0.utf8.count <= 1000 }) ?? true else { throw invalid("组合筛选文本超过上限。") }
                switch filter.operation {
                case .exists: guard filter.value == nil, filter.values == nil else { throw invalid("exists筛选不接收额外值。") }
                case .oneOf: guard filter.value == nil, let values = filter.values, !values.isEmpty else { throw invalid("oneOf筛选需要有限的值列表。") }
                case .equals, .contains: guard let value = filter.value, !value.isEmpty, filter.values == nil else { throw invalid("组合文本筛选需要一个值。") }
                }
            }
        }
        guard Set(definition.sources.map(\.selectionGroup)).count <= 8, Set(definition.sources.map(\.timeGroup)).count <= 8 else { throw invalid("组合联动组过多。") }
        var usedSources = Set<String>()
        for part in definition.parts {
            try identifier(part.selectionGroup); try identifier(part.timeGroup)
            guard part.title.utf8.count <= 400, let source = sources[part.sourceID],
                  part.selectionGroup == source.selectionGroup, part.timeGroup == source.timeGroup else { throw invalid("组合元件必须引用同一联动组中的真实数据源。") }
            usedSources.insert(part.sourceID)
            let compatible: Bool
            switch part.primitive {
            case .objectList, .objectDetail: compatible = [.objects, .events, .documents].contains(source.collection)
            case .sourceExcerpt: compatible = true
            case .markdown, .documentGraph: compatible = source.collection == .documents
            case .map: compatible = [.objects, .events, .relations].contains(source.collection)
            case .timeline: compatible = [.objects, .events].contains(source.collection)
            case .relations: compatible = source.collection == .relations
            }
            guard compatible else { throw invalid("组合元件和数据源类型不匹配。") }
        }
        guard usedSources.count == sources.count, layouts[definition.rootID] != nil else { throw invalid("组合布局含有未使用的数据源或缺少根。") }
        var parents: [String: String] = [:], usedParts = Set<String>()
        for node in definition.layout {
            if let fraction = node.fraction { guard fraction.isFinite, (0.1...0.9).contains(fraction) else { throw invalid("组合布局比例应在0.1至0.9之间。") } }
            if node.kind == .part {
                guard node.children.isEmpty, let id = node.partID, parts[id] != nil, usedParts.insert(id).inserted else { throw invalid("每个组合元件必须且只能出现在一个布局位置。") }
            } else {
                guard node.partID == nil, (2...8).contains(node.children.count), Set(node.children).count == node.children.count else { throw invalid("组合容器需要2至8个不同子布局。") }
            }
            for child in node.children {
                guard layouts[child] != nil, child != definition.rootID, parents[child] == nil else { throw invalid("组合布局存在重复父节点或非法子布局。") }
                parents[child] = node.id
            }
        }
        var visited = Set<String>()
        func walk(_ id: String, depth: Int) throws {
            guard depth <= 6, visited.insert(id).inserted, let node = layouts[id] else { throw invalid("组合布局存在环或层数超过6层。") }
            for child in node.children { try walk(child, depth: depth + 1) }
        }
        try walk(definition.rootID, depth: 1)
        guard visited.count == layouts.count, usedParts.count == parts.count else { throw invalid("组合布局包含不可达或未使用的元件。") }
    }

    public static func project(_ definition: CompositionDefinition, in project: BookProject, context: ReadingContext? = nil,
                               selections: [String: Set<String>] = [:], times: [String: TemporalQueryPoint] = [:],
                               boundary: KnowledgeReadBoundary = .all,
                               currentScope: CompositionCurrentScope = .automatic,
                               windows: [String: TemporalQueryWindow] = [:],
                               mapModes: [String: CompositionMapTimeMode] = [:]) throws -> [String: CompositionProjection] {
        try self.project(prepare(definition, in: project, context: context, currentScope: currentScope, boundary: boundary),
                         selections: selections, times: times, windows: windows, mapModes: mapModes)
    }

    public static func project(_ prepared: PreparedCompositionInput, selections: [String: Set<String>] = [:],
                               times: [String: TemporalQueryPoint] = [:], windows: [String: TemporalQueryWindow] = [:],
                               mapModes: [String: CompositionMapTimeMode] = [:]) throws -> [String: CompositionProjection] {
        var result: [String: CompositionProjection] = [:]
        for source in prepared.definition.sources {
            try Task.checkCancellation()
            guard let base = prepared.bases[source.scope] else { throw invalid("组合输入缺少已校验的数据范围。") }
            let point = times[source.timeGroup]
            let window = windows[source.timeGroup]
            let events: [TemporalEventSnapshot], relations: [TemporalRelationSnapshot]
            if let window {
                events = try TemporalKnowledgeRuntime.events(in: base.project, within: window, boundary: .all)
                relations = try TemporalKnowledgeRuntime.relations(in: base.project, within: window, boundary: .all)
            } else {
                events = try TemporalKnowledgeRuntime.events(in: base.project, at: point, boundary: .all)
                relations = try TemporalKnowledgeRuntime.relations(in: base.project, at: point, boundary: .all)
            }
            let visibleIDs = Set(base.objects.map(\.id))
            // Host selection is a hint, never authority to cross a source boundary.
            let selected = (selections[source.selectionGroup] ?? []).intersection(visibleIDs)
            let related = try relatedIDs(source.relation, selected: selected, base: base, events: events, relations: relations, point: point, window: window)
            let eventIndex = Dictionary(events.map { ($0.object.id, $0) }, uniquingKeysWith: { first, _ in first })
            var items: [CompositionItem]
            var edges: [CompositionEdge] = []
            switch source.collection {
            case .evidence:
                if source.relation == .none {
                    items = base.snapshot.sources.filter { !$0.text.isEmpty }.map { slice in
                        CompositionItem(id: "source." + slice.unitID, objectID: nil, documentID: nil, unitID: slice.unitID, anchorID: nil,
                            title: slice.locator, summary: "", kind: "evidence", typeID: nil, fields: [:],
                            evidence: [Evidence(unitID: slice.unitID, quote: slice.text)], references: [:], latitude: nil, longitude: nil, extent: nil,
                            sourceOrder: base.order[slice.unitID])
                    }
                } else { items = base.objects.filter { related.contains($0.id) }.map { item($0, order: base.order) } }
            case .objects:
                items = base.objects.filter { $0.kind != .document && ($0.kind != .event || eventIndex[$0.id] != nil) }.map { item($0, order: base.order) }
            case .events: items = events.map { value in var row = item(value.object, order: base.order); row.fields["temporalMatch"] = value.match.rawValue; row.extent = value.extent; return row }
            case .documents: items = base.objects.filter { $0.kind == .document }.map { item($0, order: base.order) }
            case .relations:
                let endpointIDs = Set(relations.flatMap { [$0.relation.fromID, $0.relation.toID] })
                items = base.objects.filter { endpointIDs.contains($0.id) }.map { item($0, order: base.order) }
                var seen = Set<String>()
                edges = try relations.compactMap { value in
                    try Task.checkCancellation()
                    let relation = value.relation
                    guard seen.insert(relation.id).inserted else { return nil }
                    if source.relation != .none, !selected.isEmpty, !selected.contains(relation.fromID), !selected.contains(relation.toID) { return nil }
                    if source.filters.contains(where: { $0.field == "label" && !matches(relation.label, filter: $0) }) { return nil }
                    return CompositionEdge(id: relation.id, fromID: relation.fromID, toID: relation.toID, label: relation.label, kind: "knowledge", temporalMatch: value.match)
                }
                let linked = Set(edges.flatMap { [$0.fromID, $0.toID] }), edgeIDs = Set(edges.map(\.id))
                items = try items.filter { linked.contains($0.id) }.map { original in
                    try Task.checkCancellation()
                    var row = original, seen = Set(original.evidence)
                    let proofs = try relations.filter {
                        try Task.checkCancellation()
                        return edgeIDs.contains($0.relation.id) && ($0.relation.fromID == row.id || $0.relation.toID == row.id)
                    }.flatMap { $0.relation.evidence }
                    row.evidence += proofs.filter { seen.insert($0).inserted }
                    return row
                }
            }
            if source.relation != .none { items = items.filter { related.contains($0.objectID ?? $0.documentID ?? $0.id) } }
            if !source.typeIDs.isEmpty { items = items.filter { $0.typeID.map(source.typeIDs.contains) ?? false } }
            items = try items.filter { row in
                try Task.checkCancellation()
                return source.filters.filter { $0.field != "label" }.allSatisfy { matches(field($0.field, in: row), filter: $0) }
            }
            try items.sort { lhs, rhs in
                try Task.checkCancellation()
                switch source.sort {
                case .name: return lhs.title == rhs.title ? lhs.id < rhs.id : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                case .sourceOrder: return (lhs.sourceOrder ?? Int.max, lhs.id) < (rhs.sourceOrder ?? Int.max, rhs.id)
                case .time:
                    let a = lhs.extent?.narrativeStart ?? lhs.extent?.start?.year ?? Int.max, b = rhs.extent?.narrativeStart ?? rhs.extent?.start?.year ?? Int.max
                    return a == b ? lhs.id < rhs.id : a < b
                }
            }
            let total = items.count
            items = Array(items.prefix(source.limit))
            if let point { items = try items.map { try timedItem($0, base: base, at: point) } }
            let itemIDs = Set(items.map(\.id))
            var diagnostics = base.diagnostics
            if source.collection == .documents {
                let layout = try documentEdges(in: base.project, documentIDs: itemIDs)
                edges = layout.edges
                if layout.usesMounts { diagnostics.append("这里的连线沿用原画布节点关联；同节点挂载的文档共享该布局关系，不代表额外的书中事实。") }
            }
            edges = edges.filter { itemIDs.contains($0.fromID) && itemIDs.contains($0.toID) }
            let edgeTruncated = edges.count > 800
            edges = Array(edges.prefix(800))
            let allPoints: [CompositionMapPoint]
            if prepared.mapSourceIDs.contains(source.id) {
                let footprintWindow = mapModes[source.timeGroup] == .windowFootprints ? window : nil
                let mapEvents: [TemporalEventSnapshot]
                if window != nil, footprintWindow == nil {
                    mapEvents = try TemporalKnowledgeRuntime.events(in: base.project, at: point, boundary: .all)
                } else { mapEvents = events }
                allPoints = try points(for: items, base: base, events: mapEvents, at: point, within: footprintWindow)
            }
            else { allPoints = [] }
            let pointTruncated = allPoints.count > 400
            let mapPoints = Array(allPoints.prefix(400))
            if pointTruncated { diagnostics.append("地图先显示400个有依据的地点；请缩小类型、时间或当前阅读范围。") }
            if edgeTruncated { diagnostics.append("关系先显示800条连线；请缩小类型或当前选择。") }
            if window != nil && (items.contains(where: { $0.fields["temporalMatch"] == "unknown" || $0.fields["temporalMatch"] == "possible" }) ||
                edges.contains(where: { $0.temporalMatch == .unknown || $0.temporalMatch == .possible })) {
                diagnostics.append("标为时间待考的记录仍保留供核对；时间未明、推测或历法不同不代表已确认落在这个区间。")
            }
            result[source.id] = CompositionProjection(items: items, edges: edges, mapPoints: mapPoints, total: total,
                partial: total > source.limit || edgeTruncated || pointTruncated, diagnostics: diagnostics)
        }
        return result
    }

    fileprivate struct ScopeBase: Sendable {
        var project: BookProject
        var snapshot: ReadingQuerySnapshot
        var objects: [TypedObject]
        var order: [String: Int]
        var diagnostics: [String]
    }
    private static func scoped(_ scope: CompositionScope, project original: BookProject, context: ReadingContext?,
                               currentScope: CompositionCurrentScope, boundary: KnowledgeReadBoundary) throws -> ScopeBase {
        var project = original
        if let allowed = boundary.allowedUnitIDs { project.units = project.units.filter { allowed.contains($0.id) } }
        var diagnostics: [String] = []
        let snapshot: ReadingQuerySnapshot
        if scope == .current, context?.unitID == nil && context?.selectedText == nil {
            project.units = []; diagnostics.append("打开原文页后，这里会显示与当前阅读位置有关的内容。")
            snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: project)
        } else if scope == .current, let id = context?.unitID, !project.units.contains(where: { $0.id == id }) {
            project.units = []; diagnostics.append("当前原文不在读者允许的阅读范围中。")
            snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: project)
        } else {
            let queryScope: ReadingQueryScope
            if scope == .book { queryScope = .book }
            else {
                switch currentScope {
                case .automatic: queryScope = context?.selectedText?.isEmpty == false ? .selection : .page
                case .page: queryScope = .page
                case .selection: queryScope = .selection
                }
            }
            snapshot = try ReadingQuerySnapshot.freeze(scope: queryScope, in: project, context: scope == .current ? context : nil)
        }
        // Only admit complete local provenance. Merely linking a note to an
        // object does not authorize reading a note containing later material.
        let documents = original.activeDocuments.filter { document in
            if !document.evidence.isEmpty { return document.evidence.allSatisfy(snapshot.admits) }
            return scope == .book && boundary.allowedUnitIDs == nil
        }
        let finalSnapshot = try ReadingQuerySnapshot.freeze(scope: snapshot.scope, in: project,
            context: snapshot.scope == .book ? nil : context, appendedDocumentIDs: documents.map(\.id))
        let session = ReadingQuerySession(snapshot: finalSnapshot, history: [], loader: nil, providedDocuments: [:], project: project)
        var safe = session.scopedKnowledgeProject() ?? project
        safe.units = project.units.filter { finalSnapshot.unitIDs.contains($0.id) }
        var objects = try TemporalKnowledgeRuntime.objects(in: safe, boundary: .all)
        let visible = Set(objects.map(\.id))
        objects = objects.map { original in
            var object = original
            object.references = object.references.mapValues { $0.filter { visible.contains($0) || finalSnapshot.unitIDs.contains($0) } }
            return object
        }
        // Legacy relations have no independent endpoint adapter; both endpoints
        // must survive exact evidence slicing before they become graph lines.
        safe.relations = safe.relations.filter { visible.contains($0.fromID) && visible.contains($0.toID) }
        return ScopeBase(project: safe, snapshot: finalSnapshot, objects: objects,
            order: Dictionary(original.units.map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first }), diagnostics: diagnostics)
    }

    private static func item(_ object: TypedObject, order: [String: Int]) -> CompositionItem {
        CompositionItem(id: object.id, objectID: object.id, documentID: object.kind == .document ? object.id : nil,
            unitID: object.evidence.first?.unitID, anchorID: object.sourceAnchorIDs.first, title: object.name, summary: object.summary,
            kind: object.kind.rawValue, typeID: object.typeID, fields: object.fields, evidence: object.evidence, references: object.references,
            latitude: object.latitude, longitude: object.longitude, extent: object.temporalExtent,
            sourceOrder: object.evidence.compactMap { order[$0.unitID] }.min())
    }
    private static func timedItem(_ original: CompositionItem, base: ScopeBase, at point: TemporalQueryPoint) throws -> CompositionItem {
        try Task.checkCancellation()
        guard original.kind == TypedObjectKind.entity.rawValue, let id = original.objectID else { return original }
        let snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: id, in: base.project, at: point, boundary: .all)
        var row = original
        let names = Dictionary(base.objects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func description(_ values: [EntityPresence]) -> String {
            values.prefix(8).map { value in
                let place = value.placeID.flatMap { names[$0] }.map { " · " + $0 } ?? ""
                return value.action + place + (value.extent.sourceText.isEmpty ? "" : " · " + value.extent.sourceText)
            }.joined(separator: "\n")
        }
        // Time-specific actions come from independent anchored records. A card
        // cannot carry its last known action forward into an unrecorded period.
        row.fields["此时行动"] = snapshot.presences.isEmpty ? "没有已核实的行动记录" : description(snapshot.presences)
        if !snapshot.uncertainPresences.isEmpty { row.fields["时间待考的记录"] = description(snapshot.uncertainPresences) }
        row.references["currentEvents"] = snapshot.events.filter { $0.match != .outside }.map { $0.object.id }
        let ids = Set((snapshot.presences + snapshot.uncertainPresences).flatMap(\.sourceAnchorIDs))
        let anchors = (base.project.temporalKnowledge?.anchors ?? []) + (base.project.readingExperience?.anchors ?? [])
        var seen = Set(row.evidence)
        row.evidence += anchors.filter { ids.contains($0.id) }.map { Evidence(unitID: $0.unitID, quote: $0.quote) }.filter { seen.insert($0).inserted }
        return row
    }
    private static func relatedIDs(_ relation: CompositionSelectionRelation, selected: Set<String>, base: ScopeBase,
                                   events: [TemporalEventSnapshot], relations: [TemporalRelationSnapshot], point: TemporalQueryPoint?,
                                   window: TemporalQueryWindow?) throws -> Set<String> {
        if relation == .none { return Set(base.objects.map(\.id)) }
        guard !selected.isEmpty else { return [] }
        var result = Set<String>()
        switch relation {
        case .none: break
        case .selected: result = selected
        case .neighbors:
            result = selected
            for value in relations where selected.contains(value.relation.fromID) || selected.contains(value.relation.toID) {
                try Task.checkCancellation(); result.formUnion([value.relation.fromID, value.relation.toID])
            }
        case .participants:
            for event in events where selected.contains(event.object.id) { result.formUnion(event.object.references["participants"] ?? []) }
        case .places:
            for event in events where selected.contains(event.object.id) { result.formUnion(event.object.references["places"] ?? []) }
            for id in selected where base.project.entities.contains(where: { $0.id == id }) {
                try Task.checkCancellation()
                let snapshot: EntityTimeSnapshot
                if let window { snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: id, in: base.project, within: window, boundary: .all) }
                else { snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: id, in: base.project, at: point, boundary: .all) }
                result.formUnion(snapshot.footprints.compactMap(\.placeID))
            }
        case .events:
            for id in selected {
                try Task.checkCancellation()
                if let window {
                    result.formUnion(try TemporalKnowledgeRuntime.events(in: base.project, entityID: id, within: window, boundary: .all).map { $0.object.id })
                    result.formUnion(try TemporalKnowledgeRuntime.events(in: base.project, placeID: id, within: window, boundary: .all).map { $0.object.id })
                } else {
                    result.formUnion(try TemporalKnowledgeRuntime.events(in: base.project, entityID: id, at: point, boundary: .all).map { $0.object.id })
                    result.formUnion(try TemporalKnowledgeRuntime.events(in: base.project, placeID: id, at: point, boundary: .all).map { $0.object.id })
                }
            }
        case .documents:
            for document in base.project.activeDocuments where !Set(document.linkedIDs).isDisjoint(with: selected) { result.insert(document.id) }
        }
        return result.intersection(Set(base.objects.map(\.id)))
    }
    private static func points(for items: [CompositionItem], base: ScopeBase, events: [TemporalEventSnapshot], at point: TemporalQueryPoint?,
                               within window: TemporalQueryWindow?) throws -> [CompositionMapPoint] {
        let objects = Dictionary(base.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [CompositionMapPoint] = []
        var seen = Set<String>()
        func append(id: String, target: String, place: TypedObject, title: String, subtitle: String, evidence: [Evidence], kind: String) {
            guard let latitude = place.latitude, let longitude = place.longitude, latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude), result.count <= 400, seen.insert(id).inserted else { return }
            result.append(CompositionMapPoint(id: id, targetID: target, title: title, subtitle: subtitle,
                latitude: latitude, longitude: longitude, evidence: evidence, kind: kind))
        }
        for row in items {
            try Task.checkCancellation()
            guard let id = row.objectID, let object = objects[id] else { continue }
            if object.kind == .entity {
                let locations = Set(base.project.temporalKnowledge?.profile?.locationTypeIDs ?? []).union(["place", "location"])
                // A person's unqualified stored coordinate is not a dated
                // presence. Fixed geographic objects may remain on the map.
                if locations.contains(object.typeID) {
                    append(id: "entity." + id, target: id, place: object, title: object.name, subtitle: object.locationNote ?? "", evidence: object.evidence, kind: "entityLocation")
                }
                let snapshot: EntityTimeSnapshot
                if let window { snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: id, in: base.project, within: window, boundary: .all) }
                else { snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: id, in: base.project, at: point, boundary: .all) }
                for presence in snapshot.footprints {
                    try Task.checkCancellation()
                    guard let placeID = presence.placeID, let place = objects[placeID] else { continue }
                    let anchors = (base.project.temporalKnowledge?.anchors ?? []) + (base.project.readingExperience?.anchors ?? [])
                    let evidence = anchors.filter { presence.sourceAnchorIDs.contains($0.id) }.map { Evidence(unitID: $0.unitID, quote: $0.quote) }
                    append(id: "presence." + presence.id, target: id, place: place, title: object.name, subtitle: presence.action + " · " + presence.extent.sourceText, evidence: evidence, kind: "presence")
                    if result.count > 400 { return result }
                }
            } else if let event = events.first(where: { $0.object.id == id }) {
                for placeID in event.object.references["places"] ?? [] {
                    guard let place = objects[placeID] else { continue }
                    append(id: "event." + id + "." + placeID, target: id, place: place, title: object.name,
                        subtitle: place.name + " · " + event.extent.sourceText + (event.match == .unknown ? " · 时间未明" : event.match == .possible ? " · 时间待考" : ""), evidence: event.object.evidence, kind: "eventLocation")
                    if result.count > 400 { return result }
                }
            }
        }
        return result
    }
    private static func documentEdges(in project: BookProject, documentIDs: Set<String>) throws -> (edges: [CompositionEdge], usesMounts: Bool) {
        var mounted = Set<String>()
        let nodeTargets = Dictionary(project.nodes.compactMap { node -> (String, [String])? in
            let ids = Set([node.targetID] + (node.documentIDs ?? [])).intersection(documentIDs).sorted()
            guard !ids.isEmpty else { return nil }
            if ids.count != 1 || ids.first != node.targetID { mounted.insert(node.id) }
            return (node.id, ids)
        }, uniquingKeysWith: { first, _ in first })
        var result: [CompositionEdge] = [], seen = Set<String>(), usesMounts = false
        for edge in project.edges {
            try Task.checkCancellation()
            guard let fromIDs = nodeTargets[edge.fromID], let toIDs = nodeTargets[edge.toID] else { continue }
            let expanded = mounted.contains(edge.fromID) || mounted.contains(edge.toID)
            for from in fromIDs {
                for to in toIDs where from != to {
                    try Task.checkCancellation()
                    let id = expanded ? edge.id + "." + from + "." + to : edge.id
                    guard seen.insert(id).inserted else { continue }
                    if expanded { usesMounts = true }
                    result.append(CompositionEdge(id: id, fromID: from, toID: to, label: expanded ? "节点关联 · " + edge.label : edge.label, kind: "layout"))
                    // One extra edge communicates truncation without expanding
                    // an unbounded Cartesian product of mounted documents.
                    if result.count > 800 { return (result, usesMounts) }
                }
            }
        }
        return (result, usesMounts)
    }
    private static func field(_ field: String, in item: CompositionItem) -> String {
        switch field { case "name": return item.title; case "summary": return item.summary; case "kind": return item.kind
        case "typeID": return item.typeID ?? ""; case "origin": return item.fields["origin"] ?? ""
        default: return field.hasPrefix("properties.") ? item.fields[String(field.dropFirst(11))] ?? "" : "" }
    }
    private static func matches(_ value: String, filter: CompositionFilter) -> Bool {
        switch filter.operation { case .exists: return !value.isEmpty; case .equals: return value == filter.value
        case .contains: return filter.value.map { value.localizedCaseInsensitiveContains($0) } ?? false
        case .oneOf: return filter.values?.contains(value) ?? false }
    }
    private static func unique(_ ids: [String]) throws {
        guard Set(ids).count == ids.count else { throw invalid("组合声明含重复ID。") }; for id in ids { try identifier(id) }
    }
    private static func identifier(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.-".unicodeScalars.contains(scalar))
        }) else { throw invalid("组合ID必须是1至128位ASCII字母、数字、点、下划线或短横线。") }
    }
    private static func invalid(_ message: String) -> ReadingError { .invalid(message) }
}
