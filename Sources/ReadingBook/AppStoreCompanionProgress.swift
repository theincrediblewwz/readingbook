import Foundation
import ReadingCore

/// Host-only progress in the existing audit stream. A unit checkpoint is
/// appended to the same project transaction as its successful reading_enrich.
/// Receipt batches alone never count as a generated companion unit.
struct CompanionScopeProgress {
    let scopeFingerprint: String
    let runID: String
    var completedUnitIDs: Set<String> = []

    private struct Entry: Codable {
        var scopeFingerprint: String
        var runID: String
        var unitID: String?
    }
    static func unfinished(for snapshot: ReadingQuerySnapshot, in project: BookProject) -> CompanionScopeProgress? {
        let allowed = Set(snapshot.unitIDs)
        var orderedRuns: [String] = [], runs: [String: CompanionScopeProgress] = [:], finished = Set<String>()
        for audit in project.audit where ["companion_scope_started", "companion_scope_checkpoint", "companion_scope_finished"].contains(audit.name) {
            guard audit.summary.utf8.count <= 4096, let data = audit.summary.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.scopeFingerprint == snapshot.scopeFingerprint,
                  UUID(uuidString: entry.runID) != nil else { continue }
            switch audit.name {
            case "companion_scope_started":
                guard runs[entry.runID] == nil else { continue }
                runs[entry.runID] = CompanionScopeProgress(scopeFingerprint: entry.scopeFingerprint, runID: entry.runID)
                orderedRuns.append(entry.runID)
            case "companion_scope_checkpoint":
                if let id = entry.unitID, allowed.contains(id), !finished.contains(entry.runID), runs[entry.runID] != nil {
                    runs[entry.runID]?.completedUnitIDs.insert(id)
                }
            case "companion_scope_finished":
                if runs[entry.runID] != nil { finished.insert(entry.runID) }
            default: break
            }
        }
        return orderedRuns.reversed().first(where: { !finished.contains($0) }).flatMap { runs[$0] }
    }
    func audit(_ name: String, unitID: String? = nil) throws -> ToolAudit {
        let value = Entry(scopeFingerprint: scopeFingerprint, runID: runID, unitID: unitID)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let summary = String(data: data, encoding: .utf8) else { throw ReadingError.invalid("无法保存伴读进度。") }
        return ToolAudit(name: name, summary: summary)
    }
}
