import Foundation

/// A read-only projection of an archived analysis request, not a configuration
/// version and not a promise that every requirement in that request completed.
public struct ReadingContinuationHistoryEntry: Identifiable, Sendable {
    public var id: String
    public var scopeTitle: String
    public var sourceHash: String
    public var status: SmartReadingStatus
    public var updatedAt: Date
    public var intent: ReadingContinuationIntent?
    public var generationID: String?
    public var isSourceCurrent: Bool
    public var checkpointCount: Int
    public var missingCheckpointCount: Int
    public var legacyInsightCount: Int
}

public struct ReadingContinuationHistoryDetail: Sendable {
    public var entry: ReadingContinuationHistoryEntry
    /// Exact immutable IDs referenced by the archive, resolved without changing
    /// the active generation or writing another persistent prose collection.
    public var checkpoints: [ReadingAnalysisCheckpoint]
    /// Older unit-scoped prose has no generation receipt. It is labelled as
    /// historical content and never used here as proof of task completion.
    public var legacyInsights: [ReadingInsight]
    public var missingCheckpointIDs: [String]
    public var warnings: [String]
}

extension ReadingContinuationRuntime {
    public static func history(in project: BookProject) throws -> [ReadingContinuationHistoryEntry] {
        let archives = historyArchives(in: project)
        let checkpoints = Dictionary((project.smartReading?.analysisCheckpoints ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let hashes = try historyUnitHashes(in: project, archives: archives)
        return archives.map { archive in
            historyEntry(archive, project: project, checkpointIDs: historyValidCheckpointIDs(archive, checkpoints: checkpoints), unitHashes: hashes)
        }.sorted { first, second in
            first.updatedAt == second.updatedAt ? first.id < second.id : first.updatedAt > second.updatedAt
        }
    }

    public static func historyDetails(sessionID: String, in project: BookProject) throws -> ReadingContinuationHistoryDetail {
        guard let archive = historyArchives(in: project).first(where: { $0.id == sessionID }) else {
            throw ReadingError.invalid("这条分析历史已不可用，请重新打开历史列表。")
        }
        let byID = Dictionary((project.smartReading?.analysisCheckpoints ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let ids = historyUniqueIDs(archive.analysisCheckpointIDs)
        let validIDs = historyValidCheckpointIDs(archive, checkpoints: byID)
        let checkpoints = ids.filter { validIDs.contains($0) }.compactMap { byID[$0] }
        let missing = ids.filter { !validIDs.contains($0) }
        let hashes = try historyUnitHashes(in: project, archives: [archive])
        let entry = historyEntry(archive, project: project, checkpointIDs: validIDs, unitHashes: hashes)
        var warnings: [String] = []
        if !entry.isSourceCurrent { warnings.append("原文版本或片段内容已变化。这里仅查看历史分析，不将旧来源映射到当前同名片段。") }
        if !missing.isEmpty { warnings.append("\(missing.count) 条历史检查点引用缺失或来源不符；未用当前结果补造旧版本。") }
        let legacy = historyLegacyInsights(archive, project: project)
        if !legacy.isEmpty { warnings.append("以下旧分析没有独立版本凭据，仅按保存时间及所含来源归入历史内容；不能证明这些文字就是本次任务的完整输出。") }
        return ReadingContinuationHistoryDetail(entry: entry, checkpoints: checkpoints, legacyInsights: legacy,
            missingCheckpointIDs: missing, warnings: warnings)
    }

    private static func historyArchives(in project: BookProject) -> [ReadingContinuationArchivedSession] {
        var seen = Set<String>()
        // A damaged duplicate ID must not make Dictionary(uniqueKeysWithValues:)
        // trap, and this view never repairs or removes the stored record.
        return (project.smartReading?.continuation?.history ?? []).reversed().filter { seen.insert($0.id).inserted }
    }
    private static func historyUniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
    private static func historyUnitHashes(in project: BookProject, archives: [ReadingContinuationArchivedSession]) throws -> [String: String] {
        let wanted = Set(archives.filter { $0.sourceHash == project.sourceHash }.flatMap(\.unitIDs))
        var hashes: [String: String] = [:]
        var duplicatedIDs = Set<String>()
        for unit in project.units where wanted.contains(unit.id) {
            try Task.checkCancellation()
            if hashes[unit.id] != nil { duplicatedIDs.insert(unit.id) }
            hashes[unit.id] = try BookImporter.sha256(Data(unit.text.utf8))
        }
        for id in duplicatedIDs { hashes.removeValue(forKey: id) }
        return hashes
    }
    private static func historyValidCheckpointIDs(_ archive: ReadingContinuationArchivedSession,
        checkpoints: [String: ReadingAnalysisCheckpoint]) -> Set<String> {
        let scope = Set(archive.unitIDs)
        return Set(archive.analysisCheckpointIDs.filter { id in
            guard let checkpoint = checkpoints[id], !checkpoint.unitIDs.isEmpty,
                  Set(checkpoint.unitIDs).isSubset(of: scope),
                  checkpoint.unitIDs.allSatisfy({ checkpoint.unitHashes[$0] != nil && checkpoint.unitHashes[$0] == archive.unitHashes[$0] }),
                  historyRanges(checkpoint.sourceRanges, fitWithin: archive.sourceRanges, scope: scope) else { return false }
            if let job = checkpoint.scopeJob {
                guard !job.scopeUnitIDs.isEmpty, Set(job.scopeUnitIDs).isSubset(of: scope),
                      historyRanges(job.sourceRanges, fitWithin: archive.sourceRanges, scope: scope) else { return false }
            }
            return true
        })
    }
    private static func historyRanges(_ ranges: [ReadingSourceRange]?, fitWithin archived: [ReadingSourceRange]?, scope: Set<String>) -> Bool {
        guard let archived else {
            return (ranges ?? []).allSatisfy { scope.contains($0.unitID) && $0.startUTF16 >= 0 && $0.endUTF16 > $0.startUTF16 }
        }
        guard let ranges, !ranges.isEmpty else { return false }
        return ranges.allSatisfy { range in
            guard scope.contains(range.unitID), range.startUTF16 >= 0, range.endUTF16 > range.startUTF16 else { return false }
            var cursor = range.startUTF16
            for saved in archived.filter({ $0.unitID == range.unitID }).sorted(by: { $0.startUTF16 < $1.startUTF16 }) {
                if saved.startUTF16 > cursor { break }
                if saved.endUTF16 > cursor { cursor = saved.endUTF16 }
                if cursor >= range.endUTF16 { return true }
            }
            return false
        }
    }
    private static func historyEntry(_ archive: ReadingContinuationArchivedSession, project: BookProject,
        checkpointIDs: Set<String>, unitHashes: [String: String]) -> ReadingContinuationHistoryEntry {
        let units = Set(archive.unitIDs)
        let sourceCurrent = archive.sourceHash == project.sourceHash && !units.isEmpty &&
            units.count == archive.unitIDs.count && Set(archive.unitHashes.keys) == units &&
            units.allSatisfy { archive.unitHashes[$0] == unitHashes[$0] && unitHashes[$0] != nil }
        let ids = Set(archive.analysisCheckpointIDs)
        return ReadingContinuationHistoryEntry(id: archive.id, scopeTitle: archive.scopeTitle, sourceHash: archive.sourceHash,
            status: archive.status, updatedAt: archive.updatedAt, intent: archive.intent ?? archive.generationIntent,
            generationID: archive.generationID, isSourceCurrent: sourceCurrent,
            checkpointCount: ids.intersection(checkpointIDs).count,
            missingCheckpointCount: ids.subtracting(checkpointIDs).count,
            legacyInsightCount: historyLegacyInsights(archive, project: project).count)
    }
    private static func historyLegacyInsights(_ archive: ReadingContinuationArchivedSession, project: BookProject) -> [ReadingInsight] {
        guard archive.selection.execution == nil else { return [] }
        let units = Set(archive.unitIDs)
        return project.insights.filter { insight in
            !insight.unitIDs.isEmpty && Set(insight.unitIDs).isSubset(of: units) &&
                insight.createdAt <= archive.updatedAt && !insight.id.hasPrefix("analysis-chunk-") &&
                !insight.id.hasPrefix("deferred-") && !insight.id.hasPrefix("blank-")
        }.sorted { first, second in
            first.createdAt == second.createdAt ? first.id < second.id : first.createdAt < second.createdAt
        }
    }
}
