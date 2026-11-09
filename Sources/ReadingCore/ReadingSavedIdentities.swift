import Foundation

extension ReadingQuerySession {
    /// Reuse only identities actually returned by a successful host operation
    /// and corroborated by its canonical transaction in this book. No body is
    /// fetched, and the existing scoped object projection remains authoritative.
    mutating func recordSavedIdentities(_ result: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
              root["applied"] as? Bool == true, root["status"] as? String == "success",
              let operation = root["operationID"] as? String, let mapping = root["idMap"] as? [String: String],
              let project, project.id == snapshot.bookID, project.sourceHash == snapshot.sourceHash,
              let receipt = project.controlledChanges?.receipts.first(where: {
                  $0.operationID == operation && $0.originBookID == snapshot.bookID && $0.undoneAt == nil
              }), let scoped = scopedKnowledgeProject() else { return }
        let ids = Set(mapping.compactMap { receipt.idMap[$0.key] == $0.value ? $0.value : nil })
        guard !ids.isEmpty else { return }
        let objects = try TemporalKnowledgeRuntime.objects(in: scoped, boundary: KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs)))
        let rows: [[String: Any]] = objects.filter { ids.contains($0.id) && !isIdentityStub($0.id) }.map {
            ["id": $0.id, "name": $0.name, "version": $0.version, "kind": $0.kind.rawValue, "typeID": $0.typeID,
             "sourceUnitIDs": Array(Set($0.evidence.map(\.unitID))).sorted()]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "items": rows], options: [.sortedKeys])
        try returnedObjectDirectory.record(String(decoding: data, as: UTF8.self), tool: "saved_identity", allowedUnits: Set(snapshot.unitIDs))
    }
}
