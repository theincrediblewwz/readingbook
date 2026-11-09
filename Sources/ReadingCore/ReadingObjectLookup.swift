import Foundation
import CoreFoundation

extension ReadingQuerySession {
    /// Batch discovery uses the same scoped adapter and canonical versions as
    /// a full read. Omitted excerpts do not become new citation grants.
    func objectLookup(_ arguments: [String: Any], scoped: BookProject, project: BookProject,
                      reuse: SavedKnowledgeReuse?, maximumBytes: Int) throws -> String {
        let batch = arguments["ids"] != nil
        let includeEvidence: Bool
        if let raw = arguments["includeEvidence"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw invalid("includeEvidence须为true或false。")
            }
            includeEvidence = number.boolValue
        } else { includeEvidence = !batch }
        let ids: [String]
        if batch {
            guard arguments["id"] == nil, arguments["expectedHash"] == nil,
                  let values = arguments["ids"] as? [String], (1...20).contains(values.count),
                  values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 400 }) else {
                throw invalid("ids须为1–20个非空ID，与id二选一；expectedHash仅用于单个id。")
            }
            var seen = Set<String>(); ids = values.filter { seen.insert($0).inserted }
        } else {
            guard arguments["offset"] == nil, arguments["limit"] == nil else { throw invalid("offset与limit只用于ids批量读取。") }
            ids = [try identifier(arguments)]
        }
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs))
        let objects: [TypedObject]
        if batch { objects = try TemporalKnowledgeRuntime.objects(in: scoped, boundary: boundary) }
        else { objects = try ids.compactMap { try TemporalKnowledgeRuntime.object(id: $0, in: scoped, boundary: boundary) } }
        let indexed = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = ids.contains { indexed[$0] == nil }
            ? PluginEngine.analysisIdentityCandidates(project, allowedUnitIDs: Set(snapshot.unitIDs), occurrenceTexts: snapshot.sources.map(\.text)) : []
        let stubs = identityStubIDs()
        func read(_ id: String) throws -> [String: Any] {
            guard let object = indexed[id] else {
                guard let candidate = candidates.first(where: { $0.id == id }),
                      let saved = reuse?.record(id: id, includeSourceExcerpts: includeEvidence) else {
                    if batch { return ["id": id, "status": "unavailable", "message": "本次可用范围没有可读对象。"] }
                    throw invalid("对象不在本次原文范围内。")
                }
                guard arguments["expectedHash"] == nil else { throw invalid("当前只是待核对身份候选，没有可用于变更的对象版本。") }
                return ["ok": true, "object": ["id": candidate.id, "name": candidate.name, "typeID": candidate.typeID], "identityOnly": true,
                    "previouslySaved": saved, "documentBodiesProvided": false,
                    "note": "当前同名身份尚待核对；旧简介是派生资料，不扩大本次原文与引用范围。"]
            }
            try checkHash(arguments, actual: object.version)
            var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(object)) as? [String: Any] ?? [:]
            if !includeEvidence {
                payload.removeValue(forKey: "evidence")
                payload["evidenceOmitted"] = true; payload["evidenceCount"] = object.evidence.count
                payload["sourceUnitIDs"] = Array(Set(object.evidence.map(\.unitID))).sorted()
                let summary = String(object.summary.prefix(400)); payload["summary"] = summary
                if summary != object.summary { payload["summaryTruncated"] = true }
            }
            var row: [String: Any] = ["ok": true, "object": payload, "documentBodiesProvided": false,
                "identityOnly": stubs.contains(object.id),
                "note": "稳定id可复用关联；跨范围聚合属性隐藏，安全旧简介单列为派生资料。只有本范围实际返回原文可作本次引用。"]
            if let saved = reuse?.record(id: object.id, includeSourceExcerpts: includeEvidence) { row["previouslySaved"] = saved }
            let kind: KnowledgeRecordKind = object.kind == .event ? .event : .entity
            if !stubs.contains(object.id), let edit = KnowledgeUserEditsRuntime.record(object.id, kind: kind, in: scoped), !edit.fields.isEmpty {
                row["readerCorrection"] = ["basis": edit.basis.title, "protectedFields": edit.fields,
                    "notice": "仅这些字段是用户修正，其余不代表已核对；原文出处单列，不把个人理解当作原文明载。"]
            }
            return row
        }
        if batch {
            let rows = try ids.map { id -> [String: Any] in
                var row = try read(id)
                row.removeValue(forKey: "note"); row.removeValue(forKey: "ok"); row.removeValue(forKey: "documentBodiesProvided")
                return row
            }
            return try page(rows, arguments, maximumBytes)
        }
        let row = try read(ids[0])
        if includeEvidence, let object = indexed[ids[0]] {
            return try objectResultWithTeacherBackground(row, objectID: object.id, visibleName: object.name, project: project, maximumBytes: maximumBytes)
        }
        return try json(row)
    }
}
