import Foundation

/// A conservative read view over already saved knowledge. An aggregate can be
/// reused only when every cited fragment is still exact and precedes this
/// reading cursor. Mixed future/past aggregates are never split heuristically.
struct SavedKnowledgeReuse {
    let sourceHash: String
    let cursorOrder: Int
    private let units: [String: SourceUnit]
    private let saved: [String: (summary: String, evidence: [Evidence])]
    private let currentSlices: [String: String]?

    init?(project: BookProject, currentUnitIDs: Set<String>, currentSlices: [String: String]? = nil) {
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !currentUnitIDs.isEmpty, currentUnitIDs.allSatisfy({ units[$0] != nil }),
              currentSlices.map({ Set($0.keys) == currentUnitIDs }) ?? true,
              let cursor = currentUnitIDs.compactMap({ units[$0]?.order }).max() else { return nil }
        self.sourceHash = project.sourceHash; self.cursorOrder = cursor; self.units = units
        self.currentSlices = currentSlices
        self.saved = Dictionary((project.entities.map { ($0.id, ($0.summary, $0.evidence)) } + project.events.map { ($0.id, ($0.summary, $0.evidence)) }), uniquingKeysWith: { first, _ in first })
    }

    func record(id: String) -> [String: Any]? {
        guard let value = saved[id] else { return nil }
        return record(summary: value.summary, evidence: value.evidence)
    }

    func admits(_ evidence: [Evidence]) -> Bool {
        !evidence.isEmpty && evidence.allSatisfy { item in
            guard let unit = units[item.unitID], unit.order <= cursorOrder, !item.quote.isEmpty,
                  let range = unit.text.range(of: item.quote, options: .literal) else { return false }
            guard unit.text[range].utf8.elementsEqual(item.quote.utf8) else { return false }
            if let slice = currentSlices?[item.unitID] {
                guard let selected = slice.range(of: item.quote, options: .literal) else { return false }
                return slice[selected].utf8.elementsEqual(item.quote.utf8)
            }
            return true
        }
    }

    func record(summary: String, evidence: [Evidence]) -> [String: Any]? {
        guard admits(evidence) else { return nil }
        let sourceIDs = Array(Set(evidence.map(\.unitID))).sorted()
        return ["kind": "previously_saved", "sourceHash": sourceHash, "cursorOrder": cursorOrder,
            "summary": String(summary.prefix(1200)),
            "sourceUnitIDs": Array(sourceIDs.prefix(64)), "sourceCount": sourceIDs.count, "sourcesTruncated": sourceIDs.count > 64 || evidence.count > 4,
            "sources": evidence.prefix(4).map { ["sourceUnitID": $0.unitID, "excerpt": String($0.quote.prefix(240))] },
            "notice": "此前阅读保存的资料，不是本次新读原文，也不增加处理覆盖。原文有新发展才补充；没有变化就复用稳定ID与已有简介。"]
    }
}
