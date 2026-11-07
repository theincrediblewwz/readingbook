import Foundation
import ReadingCore

/// Transient display data shared by every GraphSurface. No node/body copy is
/// written to the book; opening/attaching still reads the original Markdown.
struct GraphDocumentPreviewOwner: Hashable {
    var repository: UUID
    var bookID: String
    var sourceHash: String
    var revision: Int
    var scope: UUID?
}

struct GraphDocumentPreviewRequest: Hashable {
    var owner: GraphDocumentPreviewOwner
    var documents: [DocumentRecord]
}

struct GraphDocumentPreviewSnapshot {
    var owner: GraphDocumentPreviewOwner?
    var texts: [String: String] = [:]
    func text(for item: GraphItem, owner: GraphDocumentPreviewOwner?) -> String {
        guard let owner, self.owner == owner else { return item.subtitle }
        return item.documentIDs.compactMap { texts[$0] }.first(where: { !$0.isEmpty }) ?? item.subtitle
    }
}
