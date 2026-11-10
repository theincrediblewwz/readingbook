import Foundation

/// Disposable workspace metadata, not a copy of book text, analysis or a query
/// permission. Restoring always freezes and validates current canonical data.
public struct ReadingComponentSourceBookmark: Codable, Equatable, Sendable {
    public let scope: ReadingQueryScope
    public let bookID: String
    public let sourceHash: String
    public let displayTitle: String
    public let context: ReadingContext?
    public let documentIDs: [String]
    public let authorizedNodeIDs: [String]
    public let sourceFingerprint: String
    public let updatedAt: Date
    public let storageBytes: Int

    public init(snapshot: ReadingQuerySnapshot, context: ReadingContext?, updatedAt: Date = Date()) throws {
        scope = snapshot.scope; bookID = snapshot.bookID; sourceHash = snapshot.sourceHash
        displayTitle = snapshot.displayTitle; documentIDs = snapshot.documentIDs; authorizedNodeIDs = snapshot.authorizedNodeIDs
        self.context = [.book, .notes].contains(scope) ? nil : context ??
            (scope == .readSoFar ? snapshot.unitIDs.last : snapshot.unitIDs.first).map { ReadingContext(unitID: $0) }
        sourceFingerprint = try Self.fingerprint(snapshot); self.updatedAt = updatedAt
        storageBytes = try Self.cost(context: self.context, title: displayTitle, documents: documentIDs, nodes: authorizedNodeIDs)
        guard isValid else { throw ReadingError.invalid("这个范围过大，未记入工作区；当前查看不受影响。") }
    }
    public func restore(in book: BookProject) throws -> ReadingQuerySnapshot {
        guard isValid, book.id == bookID, book.sourceHash == sourceHash else { throw ReadingError.invalid("上次范围属于其他原书或版本。") }
        let snapshot = try ReadingQuerySnapshot.freeze(scope: scope, in: book, context: context,
            documentIDs: scope == .notes ? documentIDs : nil,
            appendedDocumentIDs: scope == .notes ? [] : documentIDs, authorizedNodeIDs: authorizedNodeIDs)
        guard try Self.fingerprint(snapshot) == sourceFingerprint else { throw ReadingError.invalid("上次范围的原文或章节已变化，请重新选择。") }
        return snapshot
    }
    public var isValid: Bool {
        (1...256).contains(bookID.utf8.count) && (1...256).contains(sourceHash.utf8.count) &&
        displayTitle.utf8.count <= 4096 && sourceFingerprint.utf8.count == 64 &&
        documentIDs.count <= 1024 && authorizedNodeIDs.count <= 1024 && storageBytes <= 32_768 && updatedAt.timeIntervalSince1970.isFinite
    }
    private static func fingerprint(_ snapshot: ReadingQuerySnapshot) throws -> String {
        let sources: [[String: Any]] = snapshot.sources.map { source in
            var entry: [String: Any] = ["id": source.unitID, "hash": source.textHash]
            if let range = source.sourceRange { entry["start"] = range.startUTF16; entry["end"] = range.endUTF16 }
            if let hash = source.canonicalTextHash { entry["canonical"] = hash }
            return entry
        }
        return try BookImporter.sha256(JSONSerialization.data(withJSONObject: sources, options: [.sortedKeys]))
    }
    private static func cost(context: ReadingContext?, title: String, documents: [String], nodes: [String]) throws -> Int {
        // Calculated only on creation/load, never while scrolling the workspace.
        try JSONEncoder().encode(context).count + title.utf8.count + documents.reduce(0) { $0 + $1.utf8.count + 4 } + nodes.reduce(0) { $0 + $1.utf8.count + 4 } + 1024
    }
    private enum CodingKeys: String, CodingKey { case scope, bookID, sourceHash, displayTitle, context, documentIDs, authorizedNodeIDs, sourceFingerprint, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(ReadingQueryScope.self, forKey: .scope); bookID = try c.decode(String.self, forKey: .bookID)
        sourceHash = try c.decode(String.self, forKey: .sourceHash); displayTitle = try c.decode(String.self, forKey: .displayTitle)
        context = try c.decodeIfPresent(ReadingContext.self, forKey: .context)
        documentIDs = try c.decode([String].self, forKey: .documentIDs); authorizedNodeIDs = try c.decode([String].self, forKey: .authorizedNodeIDs)
        sourceFingerprint = try c.decode(String.self, forKey: .sourceFingerprint); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        storageBytes = try Self.cost(context: context, title: displayTitle, documents: documentIDs, nodes: authorizedNodeIDs)
    }
}
