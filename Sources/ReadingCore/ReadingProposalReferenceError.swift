import Foundation

/// Identity hints are read-only, scoped declarations, never substituted IDs or
/// new evidence. A model must explicitly resubmit the corrected proposal.
struct ReadingProposalReferenceError: LocalizedError {
    struct Candidate: Codable, Sendable {
        let id: String
        let name: String
        let kind: String
    }
    struct Issue: Codable, Sendable {
        let path: String
        let id: String
        let reason: String
        let candidates: [Candidate]
        let candidatesPartial: Bool
    }
    let issues: [Issue]
    var errorDescription: String? {
        "提案引用的对象ID未通过核验；请按referenceIssues核对。新增对象须在同批newEntityIDs/newEventIDs/clientID声明；抄写错误请核对候选后显式重交。候选不授予原文引用。整批未保存。"
    }
    var receiptIssues: [[String: Any]] {
        guard let data = try? JSONEncoder().encode(issues),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows
    }

    /// One ASCII insertion, deletion or substitution. Long opaque IDs are
    /// susceptible to copying errors; short semantic names are not guessed.
    static func differsByOneByte(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard (8...128).contains(a.count), (8...128).contains(b.count), abs(a.count - b.count) <= 1,
              a.allSatisfy({ $0 < 128 }), b.allSatisfy({ $0 < 128 }), a != b else { return false }
        var i = 0, j = 0, differences = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            differences += 1
            if differences > 1 { return false }
            if a.count <= b.count { j += 1 }
            if a.count >= b.count { i += 1 }
        }
        return differences + (a.count - i) + (b.count - j) == 1
    }

    static func check(_ references: [(path: String, id: String)], allowed: Set<String>, known: Set<String>, identities: [Candidate]) throws {
        let invalid = references.filter { !allowed.contains($0.id) }
        guard !invalid.isEmpty else { return }
        // Never expose the name, kind or a near-match of an out-of-scope ID.
        // Suggestions contain only identities already admitted by this task.
        let candidates = identities.filter { allowed.contains($0.id) }.sorted { $0.id < $1.id }
        var matches: [String: [Candidate]] = [:]
        var issues: [Issue] = []
        for reference in invalid.prefix(8) {
            let outside = known.contains(reference.id)
            if !outside && matches[reference.id] == nil {
                matches[reference.id] = Array(candidates.lazy.filter { differsByOneByte(reference.id, $0.id) }.prefix(4))
            }
            let rows = matches[reference.id] ?? []
            issues.append(Issue(path: String(reference.path.prefix(240)), id: String(reference.id.prefix(128)),
                reason: outside ? "此ID不在本次冻结范围内；不能用相近对象替换或扩大范围。"
                    : "此ID不存在，也未在本批newEntityIDs/newEventIDs/clientID中声明；若是抄写错误，核对候选身份后显式重交，不要另建同名对象。",
                candidates: outside ? [] : Array(rows.prefix(3)), candidatesPartial: rows.count > 3))
        }
        throw Self(issues: issues)
    }
}
