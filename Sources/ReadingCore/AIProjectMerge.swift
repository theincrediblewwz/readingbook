import Foundation

/// Rebase only the AI operation's delta on the repository's latest state. No
/// document bodies, source text, deletion records or human layout are writable.
enum AIProjectMerge {
    static let writable: Set<String> = ["coverage", "types", "entities", "events", "relations", "views", "methods", "plan", "insights", "syntheses", "nodes", "edges", "chats", "audit", "plugins", "appliedOperationIDs", "lastUnitID", "paragraphReceipts", "readingStepResults", "workflowRuns", "receiptBatch", "smartReading", "readingExperience", "bookSchemes", "mathVerifications", "temporalKnowledge", "graphGroups"]
    static func merge(base: BookProject, result: BookProject, latest: BookProject) throws -> BookProject {
        func sameSource(_ other: BookProject) -> Bool {
            base.units == other.units && zip(base.units, other.units).allSatisfy { $0.text.utf8.elementsEqual($1.text.utf8) }
        }
        guard sameSource(result), sameSource(latest) else { throw ReadingError.invalid("原文识别或分段已改变，本次分析未应用，请从当前原文继续。") }
        // Never encode the entire source three times to merge a small tool
        // response. Protect host fields explicitly and rebase only changed
        // metadata fields; the repository still validates the final project.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        func protect<T: Encodable>(_ key: String, _ path: KeyPath<BookProject, T>) throws {
            guard try encoder.encode(base[keyPath: path]) == encoder.encode(result[keyPath: path]) else {
                throw ReadingError.invalid("分析不能修改原书、用户文档或本地管理状态：" + key)
            }
        }
        try protect("schemaVersion", \.schemaVersion); try protect("id", \.id)
        try protect("title", \.title); try protect("originalName", \.originalName)
        try protect("sourceHash", \.sourceHash); try protect("importedAt", \.importedAt)
        try protect("documents", \.documents); try protect("disabledPluginIDs", \.disabledPluginIDs)
        try protect("bookmarks", \.bookmarks); try protect("ocrPages", \.ocrPages)
        try protect("readerAnnotations", \.readerAnnotations); try protect("manualTrash", \.manualTrash)
        try protect("aiRequestHistory", \.aiRequestHistory); try protect("readingKnowledge", \.readingKnowledge)
        try protect("controlledChanges", \.controlledChanges)
        try protect("generatedOutline", \.generatedOutline)
        try protect("originalBookOutline", \.originalBookOutline)
        var canonical = latest
        func patch<T: Codable>(_ key: String, _ path: WritableKeyPath<BookProject, T>) throws {
            let before = try encoder.encode(base[keyPath: path]), after = try encoder.encode(result[keyPath: path])
            guard before != after else { return }
            guard writable.contains(key) else { throw ReadingError.invalid("分析增量字段无效。") }
            let current = try encoder.encode(latest[keyPath: path])
            if current == before || current == after { canonical[keyPath: path] = result[keyPath: path]; return }
            let old = try JSONSerialization.jsonObject(with: before, options: [.fragmentsAllowed])
            let proposed = try JSONSerialization.jsonObject(with: after, options: [.fragmentsAllowed])
            let stored = try JSONSerialization.jsonObject(with: current, options: [.fragmentsAllowed])
            let value = try rebase(old, proposed, stored, path: key) ?? NSNull()
            canonical[keyPath: path] = try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
        }
        let originalIDs = Set(base.entities.map(\.id))
        struct IdentityKey: Hashable { let typeID: String; let name: String }
        var concurrentNames: [IdentityKey: Set<String>] = [:]
        for entity in latest.entities {
            for name in [entity.name] + entity.aliases {
                let key = IdentityKey(typeID: entity.typeID, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                concurrentNames[key, default: []].insert(entity.id)
            }
        }
        for entity in result.entities where !originalIDs.contains(entity.id) {
            if ([entity.name] + entity.aliases).contains(where: { name in
                let key = IdentityKey(typeID: entity.typeID, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                return concurrentNames[key]?.contains(where: { $0 != entity.id }) == true
            }) {
                throw ReadingError.invalid("并行保存了同名对象，请重新查询本地身份后继续；已有内容保留。")
            }
        }
        try patch("coverage", \.coverage); try patch("types", \.types); try patch("entities", \.entities)
        try patch("events", \.events); try patch("relations", \.relations); try patch("views", \.views)
        try patch("methods", \.methods); try patch("plan", \.plan); try patch("insights", \.insights)
        try patch("syntheses", \.syntheses); try patch("nodes", \.nodes); try patch("edges", \.edges)
        try patch("chats", \.chats); try patch("audit", \.audit); try patch("plugins", \.plugins)
        try patch("appliedOperationIDs", \.appliedOperationIDs); try patch("lastUnitID", \.lastUnitID)
        try patch("paragraphReceipts", \.paragraphReceipts); try patch("readingStepResults", \.readingStepResults)
        try patch("workflowRuns", \.workflowRuns); try patch("receiptBatch", \.receiptBatch)
        try patch("smartReading", \.smartReading); try patch("readingExperience", \.readingExperience)
        try patch("bookSchemes", \.bookSchemes); try patch("mathVerifications", \.mathVerifications)
        try patch("temporalKnowledge", \.temporalKnowledge); try patch("graphGroups", \.graphGroups)
        return canonical
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
            // Common additive aliases/IDs need membership, not repeated scans
            // of the whole history. Preserve order and concurrent removals.
            if let prior = base as? [String], let proposed = result as? [String], let current = latest as? [String] {
                let old = Set(prior), next = Set(proposed)
                if old.isSubset(of: next) {
                    var output = current, seen = Set(current)
                    for item in proposed where !old.contains(item) && seen.insert(item).inserted { output.append(item) }
                    return output
                }
            }
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
    public func commitAIResult(base: BookProject, result: BookProject, operationID: String, expectedReadingSessionID: String? = nil) throws -> BookProject {
        guard !operationID.isEmpty, operationID.count <= 120,
              operationID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw ReadingError.invalid("分析操作标识无效。") }
        let directory = try bookDirectory(base.id, mustExist: true)
        let latest = try readProject(in: directory)
        if let expectedReadingSessionID, latest.smartReading?.id != expectedReadingSessionID { throw CancellationError() }
        guard base.id == result.id, latest.id == base.id, base.sourceHash == result.sourceHash, latest.sourceHash == base.sourceHash else { throw ReadingError.invalid("原书已改变，分析结果未应用。") }
        if latest.appliedOperationIDs.contains(operationID) { return latest }
        var merged = try AIProjectMerge.merge(base: base, result: result, latest: latest)
        merged.appliedOperationIDs.append(operationID)
        return try saveCanonicalProject(merged)
    }
}
