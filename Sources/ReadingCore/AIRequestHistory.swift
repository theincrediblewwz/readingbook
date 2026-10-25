import Foundation

/// Transport metadata only: no prompts, reasoning text, credentials or arguments.
public struct AIRequestHistoryRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var number: Int
    public var startedAt: Date
    public var finishedAt: Date
    public var status: String
    public var reasoningCharacters: Int
    public var answerCharacters: Int
    public init(id: String, title: String, number: Int, startedAt: Date, finishedAt: Date, status: String,
                reasoningCharacters: Int, answerCharacters: Int) {
        self.id = id; self.title = String(title.prefix(160)); self.number = number
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.status = status
        self.reasoningCharacters = reasoningCharacters; self.answerCharacters = answerCharacters
    }
}

extension LibraryRepository {
    public func aiRequestHistory(bookID: String) throws -> [AIRequestHistoryRecord] {
        let directory = try bookDirectory(bookID, mustExist: true)
        return try readProject(in: directory).aiRequestHistory ?? []
    }
    public func recordAIRequestHistory(bookID: String, sourceHash: String, records: [AIRequestHistoryRecord]) throws {
        guard records.count <= 300 else { throw ReadingError.invalid("请求记录数量无效。") }
        let directory = try bookDirectory(bookID, mustExist: true)
        var canonical = try readProject(in: directory)
        guard canonical.sourceHash == sourceHash else { return }
        var all = canonical.aiRequestHistory ?? [], known = Set((canonical.aiRequestHistory ?? []).map(\.id))
        for record in records where known.insert(record.id).inserted { all.append(record) }
        canonical.aiRequestHistory = Array(all.suffix(1000))
        try save(canonical)
    }
}
