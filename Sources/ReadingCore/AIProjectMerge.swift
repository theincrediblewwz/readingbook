import Foundation

/// Rebase only the AI operation's delta on the repository's latest state. No
/// document bodies, source text, deletion records or human layout are writable.
enum AIProjectMerge {
    static let writable: Set<String> = ["coverage", "types", "entities", "events", "relations", "views", "methods", "plan", "insights", "syntheses", "nodes", "edges", "chats", "audit", "plugins", "appliedOperationIDs", "lastUnitID", "paragraphReceipts", "readingStepResults", "workflowRuns", "receiptBatch", "smartReading", "readingExperience", "bookSchemes", "mathVerifications", "temporalKnowledge", "graphGroups"]
    static func merge(base: BookProject, result: BookProject, latest: BookProject) throws -> BookProject {
        let encoder = JSONEncoder()
        func object(_ project: BookProject) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: encoder.encode(project)) as? [String: Any] else { throw ReadingError.invalid("无法校验分析增量。") }; return value
        }
        let before = try object(base), after = try object(result)
        var canonical = try object(latest)
        guard same(before["units"], canonical["units"]) else { throw ReadingError.invalid("原文识别或分段已改变，本次分析未应用，请从当前原文继续。") }
        let originalIDs = Set(base.entities.map(\.id))
        let concurrent = latest.entities.filter { !originalIDs.contains($0.id) }
        for entity in result.entities where !originalIDs.contains(entity.id) {
            if concurrent.contains(where: { $0.id != entity.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == entity.name.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                throw ReadingError.invalid("并行保存了同名对象，请重新查询本地身份后继续；已有内容保留。")
            }
        }
        for key in Set(before.keys).union(after.keys) where !same(before[key], after[key]) {
            guard writable.contains(key) else { throw ReadingError.invalid("分析不能修改原书、用户文档或本地管理状态。") }
            canonical[key] = try rebase(before[key], after[key], canonical[key], path: key)
        }
        return try JSONDecoder().decode(BookProject.self, from: JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]))
    }
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        return NSDictionary(dictionary: ["value": a]).isEqual(to: ["value": b])
    }
    private static func rebase(_ base: Any?, _ result: Any?, _ latest: Any?, path: String) throws -> Any? {
        if same(base, result) { return latest }
        if same(base, latest) || same(result, latest) { return result }
        if let result = result as? [String: Any], let latest = latest as? [String: Any] {
            let base = base as? [String: Any] ?? [:]
            var output = latest
            for key in Set(base.keys).union(result.keys) where !same(base[key], result[key]) {
                output[key] = try rebase(base[key], result[key], latest[key], path: path + "." + key)
            }
            return output
        }
        if let result = result as? [Any], let latest = latest as? [Any] {
            let base = base as? [Any] ?? []
            func keyed(_ rows: [Any]) -> [String: Any]? {
                var output: [String: Any] = [:]
                for row in rows {
                    guard let object = row as? [String: Any], let id = object["id"] as? String, output[id] == nil else { return nil }
                    output[id] = row
                }
                return output
            }
            if let prior = keyed(base), let proposed = keyed(result), let current = keyed(latest) {
                var merged = current
                for id in Set(prior.keys).union(proposed.keys) where !same(prior[id], proposed[id]) {
                    // Never resurrect an object removed after this job started.
                    if prior[id] != nil && current[id] == nil { throw ReadingError.invalid("此对象已被移除，本次分析保留待重试。") }
                    merged[id] = try rebase(prior[id], proposed[id], current[id], path: path + "." + id)
                }
                let order = latest.compactMap { ($0 as? [String: Any])?["id"] as? String } + result.compactMap { ($0 as? [String: Any])?["id"] as? String }.filter { current[$0] == nil }
                return order.compactMap { merged[$0] }
            }
            // Additive evidence/aliases/operation IDs may be safely unioned;
            // changing/removing an existing element still needs fresh analysis.
            if base.allSatisfy({ row in result.contains(where: { same($0, row) }) }) {
                var merged = latest
                for row in result where !base.contains(where: { same($0, row) }) && !merged.contains(where: { same($0, row) }) { merged.append(row) }
                return merged
            }
        }
        throw ReadingError.invalid("另一条任务已更新同一内容，本次结果未覆盖它；已保存结果保留，可继续重试。")
    }
}

extension LibraryRepository {
    /// The actor serializes read/rebase/validate/write as one transaction. The
    /// persisted operation ID makes retries idempotent across app restarts.
    public func commitAIResult(base: BookProject, result: BookProject, operationID: String) throws -> BookProject {
        guard !operationID.isEmpty, operationID.count <= 120,
              operationID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw ReadingError.invalid("分析操作标识无效。") }
        let directory = try bookDirectory(base.id, mustExist: true)
        let latest = try readProject(in: directory)
        guard base.id == result.id, latest.id == base.id, base.sourceHash == result.sourceHash, latest.sourceHash == base.sourceHash else { throw ReadingError.invalid("原书已改变，分析结果未应用。") }
        if latest.appliedOperationIDs.contains(operationID) { return latest }
        var merged = try AIProjectMerge.merge(base: base, result: result, latest: latest)
        merged.appliedOperationIDs.append(operationID)
        try save(merged)
        return merged
    }
}
