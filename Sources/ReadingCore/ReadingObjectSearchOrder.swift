import Foundation

/// Ranking only: it never creates identities, hides ambiguity or changes the
/// matching set, canonical versions, scope, evidence or paging limits.
enum ReadingObjectSearchOrder {
    struct Candidate {
        var row: [String: Any]
        var ranks: [Int]
    }
    static func ranks(name: String, aliases: [String], descriptions: [String], queries: [String]) -> [Int] {
        queries.map { query in
            if name.localizedCaseInsensitiveCompare(query) == .orderedSame { return 0 }
            if aliases.contains(where: { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }) { return 1 }
            if name.localizedCaseInsensitiveContains(query) { return 2 }
            if aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return 3 }
            return descriptions.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ? 4 : 5
        }
    }
    static func ordered(_ candidates: [Candidate], queries: [String]) -> [[String: Any]] {
        guard !queries.isEmpty else { return candidates.map(\.row) }
        let eligible = candidates.indices.filter { candidates[$0].ranks.contains(where: { $0 < 5 }) }
        let sorted = eligible.sorted {
            (candidates[$0].ranks.min() ?? 5, $0) < (candidates[$1].ranks.min() ?? 5, $1)
        }
        guard queries.count > 1 else { return sorted.map { candidates[$0].row } }
        var front = [Int](), seen = Set<Int>()
        for index in queries.indices {
            // One best candidate per term first, so description matches for
            // one name cannot crowd another name off the first page.
            if let best = eligible.min(by: { (candidates[$0].ranks[index], $0) < (candidates[$1].ranks[index], $1) }),
               candidates[best].ranks[index] < 5, seen.insert(best).inserted { front.append(best) }
        }
        return (front + sorted.filter { !seen.contains($0) }).map { candidates[$0].row }
    }
}
