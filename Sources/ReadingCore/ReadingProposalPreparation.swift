import Foundation
import CoreFoundation

/// An uncommitted draft, retained with a real transaction receipt. It is never
/// projected as knowledge, a time extent, a location, or new source authority.
public struct DeferredKnowledgeProposal: Codable, Sendable {
    public var originalArguments: Data
    public var heldCounts: [String: Int]
    public var explanation: String
}

public struct ReadingPreparedProposal: Sendable {
    public var arguments: Data
    public var deferred: DeferredKnowledgeProposal?
}

public enum ReadingProposalPreparation {
    /// Splitting is an explicit request, not automatic error recovery. Only a
    /// knowledge-only envelope can separate facts from optional presentation
    /// metadata; cross-group transactions must retain all their dependencies.
    public static func prepare(name: String, arguments: Data) throws -> ReadingPreparedProposal {
        guard arguments.count <= 262_144,
              var root = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw ReadingError.invalid("变更提案须为小于256 KiB的JSON对象。")
        }
        guard let requested = root.removeValue(forKey: "saveCoreOnly") else {
            return ReadingPreparedProposal(arguments: arguments, deferred: nil)
        }
        guard let boolean = requested as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
            throw ReadingError.invalid("saveCoreOnly须为布尔值；不是批准或权限。")
        }
        let flag = boolean.boolValue
        let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        if !flag { return ReadingPreparedProposal(arguments: original, deferred: nil) }
        guard name == "knowledge_changes_propose", Set(root.keys) == ["batch"],
              var batch = root["batch"] as? [String: Any], Set(batch.keys) == ["knowledge"],
              var knowledge = batch["knowledge"] as? [String: Any] else {
            throw ReadingError.invalid("先保存基础资料只适用于单独的知识提案；笔记、画布和方案的跨组依赖不能拆开。")
        }
        try ReadingProposalShape.validate(batch, wrapped: true)
        var counts = [String: Int]()
        if var entities = knowledge["entities"] as? [[String: Any]] {
            for index in entities.indices {
                if entities[index]["latitude"] != nil || entities[index]["longitude"] != nil {
                    counts["coordinates", default: 0] += 1
                    entities[index].removeValue(forKey: "latitude")
                    entities[index].removeValue(forKey: "longitude")
                }
            }
            knowledge["entities"] = entities
        }
        for key in ["presences", "participations", "eventMetadata", "relationMetadata", "layers", "alignments"] {
            if let rows = knowledge[key] as? [Any], !rows.isEmpty {
                counts[key] = rows.count
                knowledge.removeValue(forKey: key)
            }
        }
        guard !counts.isEmpty else { throw ReadingError.invalid("本批没有可暂缓的附加资料，请按原提案校验，不必拆分。") }
        batch["knowledge"] = knowledge; root["batch"] = batch
        let core = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        _ = try ReadingProposalTools.decode(name: name, arguments: core)
        return ReadingPreparedProposal(arguments: core, deferred: .init(originalArguments: original, heldCounts: counts,
            explanation: "明确选择先保存基础资料；位置、时间和阅读附加内容的完整原稿随回执保留，尚未成为有效资料。补齐后须重新校验，沿用本次回执的真实ID。"))
    }
}

struct ReadingProposalPreflightError: LocalizedError {
    var issues: [[String: Any]]
    var underlying: Error?
    var errorDescription: String? { "提案有多处字段需要核对，请按preflightIssues一起修正；整批未保存。也可明确选择saveCoreOnly先保存基础资料并保留待补原稿。" }
}

extension ReadingQuerySession {
    func preflightSourceReferences(in data: Data) throws -> Data {
        do { return try resolveSourceReferences(in: data) }
        catch let error as ReadingSourceReferenceError {
            let independent = proposalEntityIssues(in: data) + proposalSpatialIssues(in: data) + ((try? temporalFormIssues(in: data)) ?? [])
            guard !independent.isEmpty else { throw error }
            throw ReadingProposalPreflightError(issues: Array((error.issues + independent).prefix(48)), underlying: error)
        }
    }

    /// Collect independent inexpensive checks before calling the write host.
    /// Keep the existing complete validation as the final authority.
    func preflightProposal(name: String, data: Data) throws -> Data {
        var issues = proposalEntityIssues(in: data) + proposalSpatialIssues(in: data)
        var resolved = data
        var firstError: Error?
        do { resolved = try resolveTemporalSourceSpans(in: data) }
        catch { firstError = error; issues += Self.preflightIssues(error) }
        // A failed span must not hide errors in the other time rows.
        if let more = try? temporalFormIssues(in: resolved) { issues += more }
        do { try validateProposal(name: name, data: resolved) }
        catch {
            if firstError == nil { firstError = error }
            issues += Self.preflightIssues(error)
        }
        func issueKey(_ issue: [String: Any]) -> String {
            String(describing: issue["path"] ?? "") + "|" + String(describing: issue["reason"] ?? "")
        }
        var seen = Set<String>()
        issues = issues.filter {
            seen.insert(issueKey($0)).inserted
        }
        if !issues.isEmpty {
            // Keep established error fields when they already describe every
            // issue; aggregate only when an independent check adds information.
            if let firstError, Set(Self.preflightIssues(firstError).map(issueKey)) == Set(issues.map(issueKey)) {
                throw firstError
            }
            throw ReadingProposalPreflightError(issues: Array(issues.prefix(48)), underlying: firstError)
        }
        if let firstError { throw firstError }
        return resolved
    }

    private static func preflightIssues(_ error: Error) -> [[String: Any]] {
        if let value = error as? ReadingProposalTemporalError {
            return value.issues + value.metadataIssues.map { $0.mapValues { $0 as Any } }
        }
        if let value = error as? ReadingProposalEvidenceError { return value.issues.map { $0.mapValues { $0 as Any } } }
        if let value = error as? ReadingProposalMetadataError { return value.issues.map { $0.mapValues { $0 as Any } } }
        if let value = error as? ReadingProposalReferenceError { return value.receiptIssues }
        return []
    }

    private func proposalSpatialIssues(in data: Data) -> [[String: Any]] {
        guard let scoped = scopedKnowledgeProject(),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let batch = raw["batch"] as? [String: Any] ?? raw
        let knowledge = batch["knowledge"] as? [String: Any] ?? batch
        let path = (raw["batch"] == nil ? "$" : "$.batch") + (batch["knowledge"] == nil ? "" : ".knowledge")
        // Only frozen, admitted objects may be named in diagnostic feedback.
        // New objects are supplied by this proposal, not by a wider book read.
        var types = Dictionary(scoped.entities.map { ($0.id, $0.typeID) }, uniquingKeysWith: { first, _ in first })
        let newEntities = Set(knowledge["newEntityIDs"] as? [String] ?? [])
        for entity in knowledge["entities"] as? [[String: Any]] ?? [] {
            if let id = entity["id"] as? String, let type = entity["typeID"] as? String,
               types[id] != nil || newEntities.contains(id) { types[id] = type }
        }
        var endpoints = Dictionary(scoped.relations.filter { types[$0.fromID] != nil && types[$0.toID] != nil }
            .map { ($0.id, [$0.fromID, $0.toID]) }, uniquingKeysWith: { first, _ in first })
        let newRelations = Set(knowledge["newRelationIDs"] as? [String] ?? [])
        for relation in knowledge["relations"] as? [[String: Any]] ?? [] {
            if let id = relation["id"] as? String, endpoints[id] != nil || newRelations.contains(id),
               let from = relation["fromID"] as? String, let to = relation["toID"] as? String,
               types[from] != nil, types[to] != nil { endpoints[id] = [from, to] }
        }
        let locations = Set(scoped.temporalKnowledge?.profile?.locationTypeIDs ?? []).union(["place", "location"])
        var declaredPlaces = TemporalKnowledgeRuntime.locationEntityIDs(in: scoped)
        let eventIDs = Set(scoped.events.map(\.id)).union(knowledge["newEventIDs"] as? [String] ?? [])
        for event in knowledge["events"] as? [[String: Any]] ?? [] {
            if let id = event["id"] as? String, eventIDs.contains(id) {
                declaredPlaces.formUnion((event["placeIDs"] as? [String] ?? []).filter { types[$0] != nil })
            }
        }
        var issues = [[String: Any]]()
        for (index, row) in (knowledge["presences"] as? [[String: Any]] ?? []).enumerated() {
            guard let placeID = row["placeID"] as? String, types[placeID] != nil,
                  !locations.contains(types[placeID] ?? ""), !declaredPlaces.contains(placeID) else { continue }
            issues.append(["path": path + ".presences[\(index)].placeID", "value": placeID,
                "reason": "此对象尚未在本次已存事件placeIDs或地点类型中声明为地点。若原文确有依据，可在对应事件补充placeIDs并保留原ID和已有内容；否则明确暂缓这条新增出现记录，保留其他有效修正。不要把人物当地点，也不必重生成整份资料。"])
        }
        for (index, row) in (knowledge["relationMetadata"] as? [[String: Any]] ?? []).enumerated() {
            guard let spatial = row["spatial"] as? [String: Any] else { continue }
            let prefix = path + ".relationMetadata[\(index)]"
            guard let id = row["relationID"] as? String, let ends = endpoints[id] else {
                issues.append(["path": prefix + ".relationID", "reason": "地图行动须引用本次范围内已有关系，或本批明确新增的关系；未读取范围外的起止地点。"])
                continue
            }
            let via = spatial["viaPlaceIDs"] as? [String] ?? []
            let places = [ends[0]] + via + [ends[1]]
            let invalidPlaces = places.filter { !locations.contains(types[$0] ?? "") && !declaredPlaces.contains($0) }
            if !invalidPlaces.isEmpty {
                issues.append(["path": prefix + ".spatial", "relationID": id, "fromID": ends[0], "toID": ends[1],
                    "invalidPlaceIDs": invalidPlaces, "reason": "路线起止和途经点须为地点实体；人物与部队填写actorIDs，不可充当地点。"])
            }
            var seen = Set<String>()
            for (offset, place) in places.enumerated() where !seen.insert(place).inserted {
                issues.append(["path": prefix + ".spatial" + (offset <= via.count ? ".viaPlaceIDs[\(offset - 1)]" : ""),
                    "relationID": id, "fromID": ends[0], "toID": ends[1], "repeatedPlaceID": place,
                    "reason": "此地点与路线前面的地点重复。起点、途经点、终点须互不重复；同地火攻或伏击保留事件标记即可，可移除此条spatial，勿删除原事件或编造另一地点。"])
            }
        }
        return issues
    }

    private func proposalEntityIssues(in data: Data) -> [[String: Any]] {
        guard let project, let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let batch = raw["batch"] as? [String: Any] ?? raw
        let knowledge = batch["knowledge"] as? [String: Any] ?? batch
        let path = (raw["batch"] == nil ? "$" : "$.batch") + (batch["knowledge"] == nil ? "" : ".knowledge")
        var types = Dictionary(project.types.map { ($0.id, Set($0.fields.map(\.key))) }, uniquingKeysWith: { first, _ in first })
        for row in knowledge["types"] as? [[String: Any]] ?? [] {
            if let id = row["id"] as? String {
                types[id] = Set((row["fields"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String })
            }
        }
        var issues = [[String: Any]]()
        for (index, row) in (knowledge["entities"] as? [[String: Any]] ?? []).enumerated() {
            let prefix = path + ".entities[\(index)]"
            for (field, limit) in [("latitude", 90.0), ("longitude", 180.0)] {
                guard let rawValue = row[field] else { continue }
                guard let number = rawValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, abs(number.doubleValue) <= limit else {
                    issues.append(["path": prefix + "." + field, "value": rawValue,
                        "reason": field == "latitude" ? "纬度须为-90至90的数值。请核对经纬度顺序，不会自动交换；不确定可先不填写。" : "经度须为-180至180的数值。请核对地理依据，不会自动修正；不确定可先不填写。"])
                    continue
                }
            }
            if let typeID = row["typeID"] as? String {
                if let fields = types[typeID], let properties = row["properties"] as? [String: Any] {
                    for key in Set(properties.keys).subtracting(fields).sorted().prefix(8) {
                        issues.append(["path": prefix + ".properties." + key, "reason": "此类型没有这个字段；请使用已定义的fields.key，说明文字可放summary。"])
                    }
                } else if types[typeID] == nil {
                    issues.append(["path": prefix + ".typeID", "value": typeID, "reason": "类型ID不存在；复用本书类型，或在本批types与newTypeIDs中明确新增。"])
                }
            }
        }
        return issues
    }
}
