import Foundation

extension LibraryRepository {
    /// Append only this independent AI background to the latest canonical book;
    /// never save the old request's full project or overwrite entity summaries.
    public func saveTeacherBackground(bookID: String, record: TeacherBackgroundRecord,
                                      requestHistory: [AIRequestHistoryRecord] = []) throws -> BookProject {
        try ReadingKnowledgeRuntime.validateBackground(record)
        let directory = try bookDirectory(bookID, mustExist: true)
        var canonical = try readProject(in: directory)
        guard canonical.id == bookID, canonical.sourceHash == record.sourceHash,
              ReadingKnowledgeRuntime.active(record.objectID, in: canonical) else {
            throw ReadingError.invalid("对象或原书已改变，背景未覆盖现有资料。")
        }
        let cursorID = canonical.units.first { $0.order == record.cursorOrder }?.id
        let request = try TeacherBackgroundRequest.freeze(objectID: record.objectID, in: canonical,
            currentUnitID: cursorID, avoidsSpoilers: record.avoidsSpoilers)
        guard request.contextFingerprint == record.contextFingerprint,
              ReadingKnowledgeRuntime.sourcesCurrent(record,
                  units: Dictionary(canonical.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                  allowed: request.allowedUnitIDs) else {
            throw ReadingError.invalid("讲解期间原文或对象介绍已更新；旧背景未覆盖新内容，可以重试。")
        }
        if !(canonical.readingKnowledge?.backgrounds ?? []).contains(where: { $0.id == record.id }) {
            if canonical.readingKnowledge == nil { canonical.readingKnowledge = ReadingKnowledgeState() }
            canonical.readingKnowledge?.backgrounds.append(record)
        } else if requestHistory.isEmpty { return canonical }
        if !requestHistory.isEmpty {
            var history = canonical.aiRequestHistory ?? [], known = Set(history.map(\.id))
            for item in requestHistory where known.insert(item.id).inserted { history.append(item) }
            canonical.aiRequestHistory = Array(history.suffix(1000))
        }
        return try saveCanonicalProject(canonical)
    }
}
