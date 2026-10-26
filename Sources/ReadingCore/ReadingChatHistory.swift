import Foundation

/// Frozen source scope for a user question and its answer. Older messages keep
/// nil metadata and remain readable in history; no legacy context is guessed.
public struct ReadingChatContext: Codable, Hashable, Sendable {
    public let scope: ReadingQueryScope
    public let sourceHash: String
    public let scopeFingerprint: String
    public let unitIDs: [String]
    public let documentIDs: [String]
    public let avoidsSpoilers: Bool

    public init(snapshot: ReadingQuerySnapshot, avoidsSpoilers: Bool) throws {
        scope = snapshot.scope; sourceHash = snapshot.sourceHash
        unitIDs = snapshot.unitIDs; documentIDs = snapshot.documentIDs
        self.avoidsSpoilers = avoidsSpoilers
        // Only source/slice identity and explicit document membership enter this
        // fingerprint. A new question/request never invalidates its own history.
        scopeFingerprint = try Self.fingerprint(scope: snapshot.scope, sourceHash: snapshot.sourceHash,
            sources: snapshot.sources.map { ($0.unitID, $0.textHash) }, documents: snapshot.documents,
            ranges: [.selection, .chapter].contains(snapshot.scope) ? snapshot.sources.compactMap(\.sourceRange) : nil)
    }

    fileprivate static func fingerprint(scope: ReadingQueryScope, sourceHash: String,
                                        sources: [(String, String)], documents: [DocumentRecord], ranges: [ReadingSourceRange]? = nil) throws -> String {
        var value: [String: Any] = ["scope": scope.rawValue, "sourceHash": sourceHash,
            "sources": sources.map { ["id": $0.0, "hash": $0.1] },
            "documents": documents.map { ["id": $0.id, "updatedAt": $0.updatedAt.timeIntervalSince1970] as [String: Any] }]
        if let ranges { value["sourceRanges"] = ranges.map { ["id": $0.unitID, "start": $0.startUTF16, "end": $0.endUTF16] as [String: Any] } }
        return try BookImporter.sha256(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
}

public enum ReadingChatHistory {
    public static func automaticHistory(in project: BookProject, preferences: ReadingAnswerPreferences,
                                        snapshot: ReadingQuerySnapshot) -> [ChatMessage] {
        let matching = project.chats.filter {
            ($0.conversationMode ?? .functional) == preferences.interaction && ($0.answerStyle ?? .research) == preferences.style
        }
        guard let current = try? ReadingChatContext(snapshot: snapshot, avoidsSpoilers: preferences.avoidsSpoilers) else { return [] }
        let orders = Dictionary(project.units.map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
        let cursor = current.unitIDs.compactMap { orders[$0] }.max()
        let documents = Set(current.documentIDs)
        let unitsByID = Dictionary(grouping: project.units, by: \.id)
        let documentsByID = Dictionary(project.activeDocuments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sourceHashes: [String: String] = [:], currentVersions: [ReadingChatContext: Bool] = [:]
        func sameVersion(_ context: ReadingChatContext) -> Bool {
            if let saved = currentVersions[context] { return saved }
            // A historic slice cannot be reconstructed from unit IDs alone.
            // Exact same-slice context is checked separately below.
            guard context.scope != .selection else { currentVersions[context] = false; return false }
            var sources: [(String, String)] = []
            for id in context.unitIDs {
                guard !Task.isCancelled, let matches = unitsByID[id], matches.count == 1, let unit = matches.first else { return false }
                let hash: String
                if let saved = sourceHashes[id] { hash = saved }
                else {
                    guard let value = try? BookImporter.sha256(Data(unit.text.utf8)) else { return false }
                    sourceHashes[id] = value; hash = value
                }
                sources.append((id, hash))
            }
            let notes = context.documentIDs.compactMap { documentsByID[$0] }
            let valid = notes.count == context.documentIDs.count &&
                (try? ReadingChatContext.fingerprint(scope: context.scope, sourceHash: project.sourceHash,
                    sources: sources, documents: notes)) == context.scopeFingerprint
            currentVersions[context] = valid; return valid
        }
        func admitted(_ message: ChatMessage) -> Bool {
            guard let context = message.readingContext, (!preferences.avoidsSpoilers || context.avoidsSpoilers), context.sourceHash == project.sourceHash,
                  context.scopeFingerprint.count == 64, context.unitIDs.count <= BookImporter.maximumUnits,
                  Set(context.unitIDs).count == context.unitIDs.count, context.documentIDs.count <= 1024,
                  Set(context.documentIDs).count == context.documentIDs.count,
                  Set(context.documentIDs).isSubset(of: documents) else { return false }
            if current.scope == .selection || current.scope == .chapter || current.scope == .notes {
                return context.scopeFingerprint == current.scopeFingerprint
            }
            guard sameVersion(context) else { return false }
            guard !context.unitIDs.isEmpty else { return false }
            if !preferences.avoidsSpoilers { return context.unitIDs.allSatisfy { orders[$0] != nil } }
            guard let cursor else { return false }
            return context.unitIDs.allSatisfy { orders[$0].map { $0 <= cursor } == true }
        }
        // Keep question/answer groups together; a safe-looking answer cannot
        // smuggle in an unscoped user question (or the other way around).
        var output: [ChatMessage] = [], group: [ChatMessage] = []
        func appendGroup() {
            if !group.isEmpty && group.allSatisfy(admitted) { output.append(contentsOf: group) }
        }
        for message in matching {
            if message.role == "user", !group.isEmpty { appendGroup(); group = [] }
            group.append(message)
        }
        appendGroup()
        return output
    }
}
