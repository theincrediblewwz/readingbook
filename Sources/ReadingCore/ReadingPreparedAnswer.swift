import Foundation

/// Constructed only beside the fresh snapshot below. History can consume this
/// read-only proof within this synchronous freeze, but an old public snapshot
/// cannot opt into it. It is not a grant for a later request or a writer.
struct FreshReadingAnswerInput {
    let project: BookProject
    let preferences: ReadingAnswerPreferences
    let snapshot: ReadingQuerySnapshot
    let chatContext: ReadingChatContext

    fileprivate init(project: BookProject, preferences: ReadingAnswerPreferences,
                     snapshot: ReadingQuerySnapshot, chatContext: ReadingChatContext) {
        self.project = project; self.preferences = preferences
        self.snapshot = snapshot; self.chatContext = chatContext
    }
}

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
        let history = ReadingChatHistory.automaticHistory(in: FreshReadingAnswerInput(project: project,
            preferences: preferences, snapshot: snapshot, chatContext: chatContext))
        try Task.checkCancellation()
        return Self(project: project, context: context, scope: scope, preferences: preferences,
                    snapshot: snapshot, chatContext: chatContext, history: history)
    }
}
