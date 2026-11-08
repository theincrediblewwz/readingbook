import Foundation

extension ReadingQuerySession {
    /// Wire presentation only. Canonical knowledge and its hashes remain intact.
    /// A reference replaces only an entire, byte-identical quotation whose
    /// host-issued reference and original text are already in this session.
    func modelReadToolResult(_ result: String, tool: String) throws -> String {
        guard ["object_get", "relations_list"].contains(tool), !sourceReferences.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else { return result }
        struct Key: Hashable { var unit: String; var bytes: Data }
        var references: [Key: String] = [:]
        for (ref, source) in sourceReferences.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard snapshot.unitIDs.contains(source.unitID), sourceExcerpts.contains(where: {
                $0.0 == source.unitID && SourceTextLiteral.contains(source.quote, in: $0.1)
            }) else { continue }
            let key = Key(unit: source.unitID, bytes: Data(source.quote.utf8))
            if references[key] == nil || ref == source.unitID { references[key] = ref }
        }
        var changed = false
        func compact(_ value: Any, depth: Int = 0, evidence: Bool = false) throws -> Any {
            try Task.checkCancellation()
            guard depth < 32 else { return value }
            if let row = value as? [String: Any] {
                if evidence, Set(row.keys) == ["unitID", "quote"],
                   let unit = row["unitID"] as? String, let quote = row["quote"] as? String,
                   let ref = references[Key(unit: unit, bytes: Data(quote.utf8))] {
                    changed = true
                    return ["sourceRef": ref]
                }
                var output: [String: Any] = [:]
                for (key, child) in row { output[key] = try compact(child, depth: depth + 1, evidence: key == "evidence") }
                return output
            }
            if let rows = value as? [Any] {
                return try rows.map { try compact($0, depth: depth + 1, evidence: evidence) }
            }
            return value
        }
        let compacted = try compact(root)
        guard changed else { return result }
        let output = try json(compacted)
        return output.utf8.count < result.utf8.count ? output : result
    }

    /// Tool origin is recorded by the host, never inferred from model prose.
    mutating func recordHostReceipt(_ result: String, tool: String) throws {
        guard var row = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else { return }
        row["tool"] = tool
        hostReceipts.append(try json(row))
    }

    /// A later decision supersedes the pending state of that exact proposal.
    /// Discovery success is not a saved analysis or an opened component.
    func closingHostReceiptSummaries() -> [[String: Any]] {
        var seenProposals = Set<String>(), receipts: [[String: Any]] = []
        for value in hostReceipts.reversed() {
            guard let original = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                  original["tool"] as? String != "components_list" else { continue }
            if let id = original["proposalID"] as? String, !seenProposals.insert(id).inserted { continue }
            var summary: [String: Any] = [:]
            for key in ["tool", "status", "message", "summary", "proposalID", "digest", "operationID", "applied", "replayed", "opened", "viewID"] {
                if let string = original[key] as? String { summary[key] = String(string.prefix(300)) }
                else if let values = original[key] as? [String] { summary[key] = values.prefix(4).map { String($0.prefix(120)) } }
                else if let number = original[key] as? NSNumber { summary[key] = number }
            }
            if !summary.isEmpty { receipts.append(summary) }
            if receipts.count == 6 { break }
        }
        return receipts.reversed()
    }
}
