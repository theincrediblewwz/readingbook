import Foundation

/// A host-validated response batch, separate from the analysis completion
/// checkpoint. Source text and user Markdown remain protected by the plugin
/// invariants and the repository's three-way merge.
public struct AIReadingPublication: Sendable {
    public let before: BookProject
    public let after: BookProject
    public let operationID: String
    public let toolNames: [String]
    public let isAnalysisComplete: Bool
    public let unitIDs: [String]
}

public typealias AIReadingPublicationHandler = @Sendable (AIReadingPublication) async throws -> Void
