import SwiftUI
import CryptoKit
import ReadingCore

struct QueryMemoryDisplay: Sendable {
    var memory: ConversationMemory?
    var messages: [String: ChatMessage] = [:]
}

/// Derived context is prepared on demand, never while SwiftUI computes body.
struct QueryMemoryPreparationKey: Hashable {
    var root: URL
    var bookID: String?
    var revision: Int
    var memoryRevision: Int
    var scope: ReadingQueryScope
    var context: ReadingContext
    var documents: [String]?
    var attachments: [String]
    var nodes: [String]
    var mode: String
}

actor QueryMemoryFiles {
    static let shared = QueryMemoryFiles()
    nonisolated static func url(snapshot: ReadingQuerySnapshot, root: URL) -> URL {
        let identity = snapshot.bookID + "|" + snapshot.scopeFingerprint
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("ConversationMemory", isDirectory: true).appendingPathComponent(name + ".json")
    }
    func read(snapshot: ReadingQuerySnapshot, history: [ChatMessage], root: URL) -> ConversationMemory? {
        let path = Self.url(snapshot: snapshot, root: root)
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: path), let memory = try? JSONDecoder().decode(ConversationMemory.self, from: data),
              ConversationMemoryRuntime.isValid(memory, snapshot: snapshot, history: history) else { return nil }
        return memory
    }
    func write(_ memory: ConversationMemory, snapshot: ReadingQuerySnapshot, root: URL) throws {
        let path = Self.url(snapshot: snapshot, root: root)
        let data = try JSONEncoder().encode(memory)
        guard data.count <= 1_048_576 else { return }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }
    func remove(snapshot: ReadingQuerySnapshot, root: URL) throws {
        let path = Self.url(snapshot: snapshot, root: root)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}

@MainActor extension AppStore {
    var queryMemoryPreparationKey: QueryMemoryPreparationKey {
        QueryMemoryPreparationKey(root: libraryRootURL, bookID: bookID, revision: projectRevision, memoryRevision: queryMemoryRevision, scope: queryScope,
            context: queryReadingContext, documents: queryDocumentIDs.map { $0.sorted() },
            attachments: queryAttachedDocumentIDs.sorted(), nodes: queryInteractionMode == .functional ? queryAuthorizedNodeIDs.sorted() : [],
            mode: currentQueryPreferences.contextIdentity)
    }
    func loadPreparedQueryMemory(snapshot: ReadingQuerySnapshot, history: [ChatMessage], root: URL) async -> ConversationMemory? {
        await QueryMemoryFiles.shared.read(snapshot: snapshot, history: history, root: root)
    }
    func prepareQueryMemoryDisplay() async -> QueryMemoryDisplay {
        // A valid derived memory must cite admitted history. With no messages
        // there can be none; avoid outline/snapshot/file preparation entirely.
        guard let original = book, !original.chats.isEmpty else { return QueryMemoryDisplay() }
        let key = queryMemoryPreparationKey, preferences = currentQueryPreferences
        let project: BookProject
        do { project = key.scope == .chapter ? try await ensureBookChapterOutline(project: original) : original }
        catch { return QueryMemoryDisplay() }
        guard !Task.isCancelled, bookID == original.id, libraryRootURL == key.root else { return QueryMemoryDisplay() }
        let worker = Task.detached(priority: .userInitiated) { () throws -> (ReadingQuerySnapshot, [ChatMessage])? in
            guard project.chats.contains(where: {
                ($0.conversationMode ?? .functional) == preferences.interaction && ($0.answerStyle ?? .research) == preferences.style
            }) else { return nil }
            if key.scope == .book {
                // This proof belongs to this immutable preparation only. Public
                // old snapshots and every other scope keep full revalidation.
                let prepared = try ReadingPreparedAnswer.freeze(project: project, scope: key.scope, context: key.context,
                    documentIDs: key.documents, appendedDocumentIDs: key.attachments,
                    authorizedNodeIDs: key.nodes, preferences: preferences)
                return (prepared.snapshot, prepared.history)
            }
            let snapshot = try ReadingQuerySnapshot.freeze(scope: key.scope, in: project, context: key.context,
                documentIDs: key.documents, appendedDocumentIDs: key.scope == .notes ? [] : key.attachments, authorizedNodeIDs: key.nodes)
                .withContextIdentity(preferences.contextIdentity)
            return (snapshot, ReadingChatHistory.automaticHistory(in: project, preferences: preferences, snapshot: snapshot))
        }
        guard let (snapshot, history) = try? await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }),
              !Task.isCancelled, queryMemoryPreparationKey == key else { return QueryMemoryDisplay() }
        let memory = await loadPreparedQueryMemory(snapshot: snapshot, history: history, root: key.root)
        guard !Task.isCancelled, queryMemoryPreparationKey == key else { return QueryMemoryDisplay() }
        let ids = Set(((memory?.requirements ?? []) + (memory?.conclusions ?? []) + (memory?.unresolved ?? [])).flatMap(\.sources))
        return QueryMemoryDisplay(memory: memory, messages: Dictionary(history.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }
}
