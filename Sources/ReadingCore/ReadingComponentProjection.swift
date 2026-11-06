import Foundation

/// Disposable presentation of the shared book, never a replacement to save.
/// A component follows the host's frozen question scope, not the moving cursor.
public enum ReadingComponentProjection {
    public static func project(_ snapshot: ReadingQuerySnapshot, in original: BookProject) throws -> BookProject {
        try Task.checkCancellation()
        let local = try snapshot.componentSnapshot(in: original)
        let units = try snapshot.scopedSourceUnits(in: original)
        if snapshot.scope == .book {
            guard Set(snapshot.unitIDs) == Set(original.units.map(\.id)), snapshot.unitIDs.count == original.units.count else {
                throw ReadingError.invalid("全书原文索引已更新，请重新选择组件范围。")
            }
            return original
        }
        let session = ReadingQuerySession(snapshot: local, history: [], loader: nil,
            providedDocuments: [:], project: original)
        guard var result = session.scopedKnowledgeProject() else { throw ReadingError.invalid("组件缺少本书资料。") }
        result.units = units
        let lengths = Dictionary(original.units.map { ($0.id, ($0.text as NSString).length) }, uniquingKeysWith: { first, _ in first })
        let wholeUnits = Set(try snapshot.sourceRanges(in: original).filter {
            $0.startUTF16 == 0 && $0.endUTF16 == lengths[$0.unitID]
        }.map(\.unitID))
        result.coverage = original.coverage.filter { wholeUnits.contains($0.key) }
        result.insights = original.insights.filter { !$0.unitIDs.isEmpty && Set($0.unitIDs).isSubset(of: wholeUnits) }
        result.syntheses = original.syntheses.filter { !$0.unitIDs.isEmpty && Set($0.unitIDs).isSubset(of: wholeUnits) }
        let targets = Set(result.entities.map(\.id) + result.events.map(\.id) + result.documents.map(\.id) + units.map(\.id))
        result.nodes = original.nodes.filter { targets.contains($0.targetID) }
        let nodes = Set(result.nodes.map(\.id))
        result.edges = original.edges.filter { nodes.contains($0.fromID) && nodes.contains($0.toID) }
        return result
    }
}
