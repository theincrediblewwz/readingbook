import Foundation

extension LibraryRepository {
    /// Cancellation ends model work, but must not cancel its final status commit.
    /// This small independent task does not inherit the stopped reader's flag.
    public nonisolated func checkpointReadingStop(bookID: String, sessionID: String, failed: Bool, message: String) async throws -> BookProject? {
        let commit = Task.detached(priority: .userInitiated) {
            try await self.persistReadingStop(bookID: bookID, sessionID: sessionID, failed: failed, message: message)
        }
        return try await commit.value
    }

    /// Check identity and commit on the same actor turn, always from canonical data.
    /// A late old task cannot pause a replacement session or erase newer products.
    private func persistReadingStop(bookID: String, sessionID: String, failed: Bool, message: String) throws -> BookProject? {
        let directory = try bookDirectory(bookID, mustExist: true)
        let current = try readProject(in: directory)
        guard current.id == bookID, let session = current.smartReading, session.id == sessionID,
              session.status != .completed else { return nil }
        var stopped = current
        stopped.smartReading?.status = failed ? .failed : .paused
        stopped.smartReading?.updatedAt = Date()
        stopped.smartReading?.lastMessage = String(message.prefix(2000))
        return try commitAIResult(base: current, result: stopped, operationID: "reading-stop-" + UUID().uuidString)
    }
}
