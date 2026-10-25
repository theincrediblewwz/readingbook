import Foundation

extension ReadingQuerySession {
    /// Only an explicit get in a host-selected mentor conversation reads this
    /// separate cache. Search results and internal component queries stay clean.
    func objectResultWithTeacherBackground(_ row: [String: Any], objectID: String, visibleName: String,
                                          project: BookProject, maximumBytes: Int) throws -> String {
        let original = try json(row)
        guard answerPreferences.style == .mentor, snapshot.bookID == project.id, snapshot.sourceHash == project.sourceHash,
              original.utf8.count + 600 < maximumBytes else { return original }
        let sourceIDs = Set(snapshot.unitIDs)
        guard let cursor = project.units.filter({ sourceIDs.contains($0.id) }).max(by: { $0.order < $1.order }),
              let request = try? TeacherBackgroundRequest.freeze(objectID: objectID, in: project, currentUnitID: cursor.id,
                  avoidsSpoilers: answerPreferences.avoidsSpoilers),
              let record = ReadingKnowledgeRuntime.background(for: request, in: project),
              record.title == visibleName, !record.evidence.isEmpty,
              permitsTeacherBackgroundSources(record, project: project),
              !answerPreferences.avoidsSpoilers || record.cursorOrder <= cursor.order else { return original }
        // No unitID/quote tuple is returned in this field. The existing exact
        // object evidence remains unchanged; background never becomes a new
        // sourceExcerpts entry or a citeable source/document/message ID.
        var length = min(1600, record.markdown.count)
        while length > 0 {
            var result = row
            result["cachedTeacherBackground"] = ["id": record.id, "kind": "ai_background",
                "label": "背景补充 · AI讲解，非原文", "markdown": String(record.markdown.prefix(length)),
                "citationAllowed": false, "truncated": length < record.markdown.count]
            let encoded = try json(result)
            if encoded.utf8.count <= maximumBytes { return encoded }
            length /= 2
        }
        return original
    }

    private func permitsTeacherBackgroundSources(_ record: TeacherBackgroundRecord, project: BookProject) -> Bool {
        if snapshot.scope == .page || snapshot.scope == .chapter {
            // Match the already-saved knowledge prefix policy. Actual identity
            // was read in this scope; old context is not a new source grant.
            let slices = Dictionary(snapshot.sources.map { ($0.unitID, $0.text) }, uniquingKeysWith: { first, _ in first })
            return SavedKnowledgeReuse(project: project, currentUnitIDs: Set(snapshot.unitIDs), currentSlices: slices)?.admits(record.evidence) == true
        }
        // Selection and internal cropped .book components cannot borrow the
        // prefix permission. Explicit full-book queries already contain their
        // allowed source units, so the same exact gate is sufficient there.
        return record.evidence.allSatisfy(snapshot.admits)
    }
}
