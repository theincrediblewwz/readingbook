import Foundation

/// Ownership metadata only. Values remain in the shared entities/events/relations;
/// components never receive a second editable copy of the knowledge database.
public enum KnowledgeEditBasis: String, Codable, CaseIterable, Sendable {
    case checkedSource, inference, interpretation
    public var title: String {
        switch self { case .checkedSource: return "我已核对原文"; case .inference: return "我的推断"; case .interpretation: return "我的理解" }
    }
}
public enum KnowledgeRecordKind: String, Codable, Sendable { case entity, event, relation }
public struct KnowledgeUserEdit: Codable, Equatable, Sendable {
    public var kind: KnowledgeRecordKind
    public var objectID: String
    public var fields: [String]
    public var basis: KnowledgeEditBasis
    public var updatedAt: Date
    public init(kind: KnowledgeRecordKind, objectID: String, fields: [String], basis: KnowledgeEditBasis, updatedAt: Date = Date()) {
        self.kind = kind; self.objectID = objectID; self.fields = fields; self.basis = basis; self.updatedAt = updatedAt
    }
}
public struct KnowledgeUserEditState: Codable, Equatable, Sendable {
    public var version = 1
    public var records: [KnowledgeUserEdit] = []
    public init() {}
}
public enum KnowledgeRecordValue: Equatable, Sendable {
    case entity(KnowledgeEntity), event(KnowledgeEvent), relation(KnowledgeRelation)
    public var kind: KnowledgeRecordKind { switch self { case .entity: return .entity; case .event: return .event; case .relation: return .relation } }
    public var id: String { switch self { case .entity(let v): return v.id; case .event(let v): return v.id; case .relation(let v): return v.id } }
    public var evidence: [Evidence] { switch self { case .entity(let v): return v.evidence; case .event(let v): return v.evidence; case .relation(let v): return v.evidence } }
    func encoded() throws -> Data {
        switch self { case .entity(let v): return try JSONEncoder().encode(v); case .event(let v): return try JSONEncoder().encode(v); case .relation(let v): return try JSONEncoder().encode(v) }
    }
}

public enum KnowledgeUserEditsRuntime {
    public static func record(_ id: String, kind: KnowledgeRecordKind, in project: BookProject) -> KnowledgeUserEdit? {
        project.knowledgeUserEdits?.records.first { $0.kind == kind && $0.objectID == id }
    }
    static func locked(_ field: String, id: String, kind: KnowledgeRecordKind, in project: BookProject) -> Bool {
        record(id, kind: kind, in: project)?.fields.contains(field) == true
    }
    static func value(_ id: String, kind: KnowledgeRecordKind, in project: BookProject) -> KnowledgeRecordValue? {
        switch kind {
        case .entity: return project.entities.first { $0.id == id }.map(KnowledgeRecordValue.entity)
        case .event: return project.events.first { $0.id == id }.map(KnowledgeRecordValue.event)
        case .relation: return project.relations.first { $0.id == id }.map(KnowledgeRecordValue.relation)
        }
    }
    static func put(_ value: KnowledgeRecordValue, in project: inout BookProject) {
        switch value {
        case .entity(let v): if let i = project.entities.firstIndex(where: { $0.id == v.id }) { project.entities[i] = v }
        case .event(let v): if let i = project.events.firstIndex(where: { $0.id == v.id }) { project.events[i] = v }
        case .relation(let v): if let i = project.relations.firstIndex(where: { $0.id == v.id }) { project.relations[i] = v }
        }
    }
    /// Reapply only explicitly edited fields. Fresh evidence and unedited fields
    /// are still merged; removals stay removed rather than being resurrected.
    public static func preserving(_ candidate: BookProject, from canonical: BookProject) throws -> BookProject {
        guard candidate.id == canonical.id, candidate.sourceHash == canonical.sourceHash else { throw ReadingError.invalid("修正资料不属于当前原书。") }
        var result = candidate
        result.knowledgeUserEdits = canonical.knowledgeUserEdits
        guard let edits = canonical.knowledgeUserEdits?.records, !edits.isEmpty else { return result }
        let requested = Set(edits.map { $0.kind.rawValue + "/" + $0.objectID })
        var originalRecords: [String: KnowledgeRecordValue] = [:], candidateRecords: [String: KnowledgeRecordValue] = [:]
        func collect(_ project: BookProject, into values: inout [String: KnowledgeRecordValue]) {
            for value in project.entities where requested.contains("entity/" + value.id) { values["entity/" + value.id] = .entity(value) }
            for value in project.events where requested.contains("event/" + value.id) { values["event/" + value.id] = .event(value) }
            for value in project.relations where requested.contains("relation/" + value.id) { values["relation/" + value.id] = .relation(value) }
        }
        collect(canonical, into: &originalRecords); collect(candidate, into: &candidateRecords)
        var restoredRecords: [String: KnowledgeRecordValue] = [:]
        for edit in edits where !edit.fields.isEmpty {
            let key = edit.kind.rawValue + "/" + edit.objectID
            guard let old = originalRecords[key], let proposed = candidateRecords[key], old != proposed else { continue }
            var fields = try dictionary(proposed)
            let saved = try dictionary(old)
            for field in edit.fields {
                if field.hasPrefix("properties.") {
                    let key = String(field.dropFirst("properties.".count))
                    var properties = fields["properties"] as? [String: Any] ?? [:]
                    properties[key] = (saved["properties"] as? [String: Any])?[key]
                    fields["properties"] = properties
                } else { fields[field] = saved[field] }
            }
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            let restored: KnowledgeRecordValue
            switch edit.kind {
            case .entity: restored = .entity(try JSONDecoder().decode(KnowledgeEntity.self, from: data))
            case .event: restored = .event(try JSONDecoder().decode(KnowledgeEvent.self, from: data))
            case .relation: restored = .relation(try JSONDecoder().decode(KnowledgeRelation.self, from: data))
            }
            restoredRecords[key] = restored
        }
        for i in result.entities.indices { if case .entity(let value) = restoredRecords["entity/" + result.entities[i].id] { result.entities[i] = value } }
        for i in result.events.indices { if case .event(let value) = restoredRecords["event/" + result.events[i].id] { result.events[i] = value } }
        for i in result.relations.indices { if case .relation(let value) = restoredRecords["relation/" + result.relations[i].id] { result.relations[i] = value } }
        return result
    }
    static func applying(expected: KnowledgeRecordValue, replacement: KnowledgeRecordValue, basis: KnowledgeEditBasis, to project: BookProject) throws -> BookProject {
        guard expected.id == replacement.id, expected.kind == replacement.kind,
              value(expected.id, kind: expected.kind, in: project) == expected else { throw ReadingError.invalid("这份资料已经更新或回收；输入保留，请重新核对后保存。") }
        guard expected.evidence == replacement.evidence else { throw ReadingError.invalid("编辑介绍不能改写原文出处。") }
        let name: String, summary: String
        switch replacement { case .entity(let v): name = v.name; summary = v.summary; case .event(let v): name = v.name; summary = v.summary; case .relation(let v): name = v.label; summary = "" }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1600, summary.utf8.count <= 131_072 else { throw ReadingError.invalid("名称不能为空，名称或概述不能过长。") }
        if basis == .checkedSource { guard !expected.evidence.isEmpty else { throw ReadingError.invalid("没有原文出处，请选择“我的推断”或“我的理解”。") } }
        let before = try dictionary(expected), after = try dictionary(replacement)
        var fields: [String] = []
        for key in Set(before.keys).union(after.keys).subtracting(["id", "evidence"]) {
            if key == "properties" {
                let a = before[key] as? [String: String] ?? [:], b = after[key] as? [String: String] ?? [:]
                fields += Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.map { "properties." + $0 }
            } else if !same(before[key], after[key]) { fields.append(key) }
        }
        var result = project, state = project.knowledgeUserEdits ?? .init()
        let existing = state.records.firstIndex { $0.objectID == expected.id && $0.kind == expected.kind }
        if let i = existing {
            state.records[i].fields = Array(Set(state.records[i].fields + fields)).sorted()
            state.records[i].basis = basis; state.records[i].updatedAt = Date()
        } else { state.records.append(.init(kind: expected.kind, objectID: expected.id, fields: fields.sorted(), basis: basis)) }
        put(replacement, in: &result); result.knowledgeUserEdits = state
        try validate(in: result)
        return result
    }
    public static func validate(in project: BookProject) throws {
        guard let state = project.knowledgeUserEdits else { return }
        guard state.version == 1, state.records.count <= 100_000 else { throw ReadingError.invalid("用户修正记录版本或数量无效。") }
        var seen = Set<String>()
        for entry in state.records {
            let allowed: Set<String>
            switch entry.kind {
            case .entity: allowed = ["name", "typeID", "summary", "aliases", "latitude", "longitude", "locationNote"]
            case .event: allowed = ["name", "summary", "dateText", "startYear", "endYear", "placeIDs", "participantIDs"]
            case .relation: allowed = ["label", "fromID", "toID"]
            }
            guard safeID(entry.objectID), seen.insert(entry.kind.rawValue + "/" + entry.objectID).inserted,
                  entry.fields.count <= 270, Set(entry.fields).count == entry.fields.count,
                  entry.fields.allSatisfy({ allowed.contains($0) || entry.kind == .entity && $0.hasPrefix("properties.") && safeID(String($0.dropFirst(11))) }),
                  entry.updatedAt.timeIntervalSince1970.isFinite else { throw ReadingError.invalid("用户修正的字段或标识无效。") }
        }
    }
    private static func dictionary(_ value: KnowledgeRecordValue) throws -> [String: Any] { try JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any] ?? [:] }
    private static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".." && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }; guard let a, let b else { return false }
        return NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
    }
}

extension LibraryRepository {
    /// One actor transaction, based on the current disk object rather than an
    /// editor's full-project snapshot. Concurrent notes/analyses are preserved.
    public func saveKnowledgeEdit(bookID: String, sourceHash: String, expected: KnowledgeRecordValue,
                                  replacement: KnowledgeRecordValue, basis: KnowledgeEditBasis) throws -> BookProject {
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        let current = try readProject(in: directory)
        guard current.sourceHash == sourceHash else { throw ReadingError.invalid("原书已改变，修正输入保留。") }
        var edited = try KnowledgeUserEditsRuntime.applying(expected: expected, replacement: replacement, basis: basis, to: current)
        edited.audit.append(.init(name: "user_knowledge_edit", summary: "已修正共享资料；后续 AI 整理保留修改字段：" + expected.id))
        return try saveCanonicalProject(edited, knowledgeUserEdits: edited.knowledgeUserEdits)
    }
}
