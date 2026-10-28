import Foundation

/// One request's immutable project, source permissions and automatic history.
/// Keeping them together avoids freezing the entire book a second time after
/// the UI has already prepared its context. This is not a reusable writer grant.
public struct ReadingPreparedAnswer: Sendable {
    let project: BookProject
    let context: ReadingContext?
    let scope: ReadingQueryScope
    public let preferences: ReadingAnswerPreferences
    public let snapshot: ReadingQuerySnapshot
    public let chatContext: ReadingChatContext
    public let history: [ChatMessage]

    private init(project: BookProject, context: ReadingContext?, scope: ReadingQueryScope,
                 preferences: ReadingAnswerPreferences, snapshot: ReadingQuerySnapshot,
                 chatContext: ReadingChatContext, history: [ChatMessage]) {
        self.project = project; self.context = context; self.scope = scope
        self.preferences = preferences; self.snapshot = snapshot
        self.chatContext = chatContext; self.history = history
    }

    public static func freeze(project: BookProject, scope: ReadingQueryScope, context: ReadingContext? = nil,
                              documentIDs: [String]? = nil, appendedDocumentIDs: [String] = [],
                              authorizedNodeIDs: [String] = [], preferences: ReadingAnswerPreferences = .init()) throws -> Self {
        try Task.checkCancellation()
        let snapshot = try ReadingQuerySnapshot.freeze(scope: scope, in: project, context: context,
            documentIDs: documentIDs, appendedDocumentIDs: appendedDocumentIDs,
            authorizedNodeIDs: preferences.interaction == .functional ? authorizedNodeIDs : [])
            .withContextIdentity(preferences.contextIdentity)
        let chatContext = try ReadingChatContext(snapshot: snapshot, avoidsSpoilers: preferences.avoidsSpoilers)
        let history = ReadingChatHistory.automaticHistory(in: project, preferences: preferences, snapshot: snapshot)
        try Task.checkCancellation()
        return Self(project: project, context: context, scope: scope, preferences: preferences,
                    snapshot: snapshot, chatContext: chatContext, history: history)
    }
}
