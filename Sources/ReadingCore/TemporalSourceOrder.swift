import Foundation

/// Read-only coordinates of a record's admitted source, independent of its
/// calendar date. These are not historical dates or a new persisted timeline.
enum TemporalSourceOrder {
    static func orders(in project: BookProject, boundary: KnowledgeReadBoundary) -> [String: Int] {
        Dictionary(project.units.filter { boundary.allowedUnitIDs?.contains($0.id) ?? true }
            .map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
    }
    static func extent(_ original: TemporalExtent?, evidence: [Evidence], orders: [String: Int]) -> TemporalExtent? {
        let positions = evidence.compactMap { orders[$0.unitID] }
        guard positions.count == evidence.count, let first = positions.min(), let last = positions.max() else { return nil }
        if let original, original.precision == .narrative, original.narrativeDomain == "source-order",
           original.narrativeStart != nil { return original }
        return TemporalExtent(sourceText: "", precision: .narrative, uncertainty: .exact,
            kind: first == last ? .point : .interval, narrativeStart: first, narrativeEnd: first == last ? nil : last,
            assertion: .explicit, explanation: "按原文出处位置排列，不代表史事日期或实际经过的时间。", narrativeDomain: "source-order")
    }
    static func isSource(_ point: TemporalQueryPoint?) -> Bool {
        if case .ordered(_, "source-order") = point { return true }; return false
    }
    static func isSource(_ window: TemporalQueryWindow) -> Bool {
        if case .ordered(_, _, "source-order") = window { return true }; return false
    }
}
