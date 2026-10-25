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
        let value: [String: Any] = ["scope": snapshot.scope.rawValue, "sourceHash": snapshot.sourceHash,
            "sources": snapshot.sources.map { ["id": $0.unitID, "hash": $0.textHash] },
            "documents": snapshot.documents.map { ["id": $0.id, "updatedAt": $0.updatedAt.timeIntervalSince1970] as [String: Any] }]
        scopeFingerprint = try BookImporter.sha256(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
}

public enum ReadingChatHistory {
    public static func automaticHistory(in project: BookProject, preferences: ReadingAnswerPreferences,
                                        snapshot: ReadingQuerySnapshot) -> [ChatMessage] {
        let matching = project.chats.filter {
            ($0.conversationMode ?? .functional) == preferences.interaction && ($0.answerStyle ?? .research) == preferences.style
        }
        guard preferences.avoidsSpoilers else { return matching }
        guard let current = try? ReadingChatContext(snapshot: snapshot, avoidsSpoilers: true) else { return [] }
        let orders = Dictionary(project.units.map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
        let cursor = current.unitIDs.compactMap { orders[$0] }.max()
        let documents = Set(current.documentIDs)
        func admitted(_ message: ChatMessage) -> Bool {
            guard let context = message.readingContext, context.avoidsSpoilers, context.sourceHash == project.sourceHash,
                  context.scopeFingerprint.count == 64, context.unitIDs.count <= BookImporter.maximumUnits,
                  Set(context.unitIDs).count == context.unitIDs.count, context.documentIDs.count <= 1024,
                  Set(context.documentIDs).count == context.documentIDs.count,
                  Set(context.documentIDs).isSubset(of: documents) else { return false }
            if current.scope == .selection || current.scope == .notes {
                return context.scopeFingerprint == current.scopeFingerprint
            }
            guard let cursor, !context.unitIDs.isEmpty else { return false }
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
