import Foundation

extension ReadingQuerySession {
    /// Explicit unit IDs only. All pages share the same byte/character budget,
    /// and only fragments actually included in the final envelope are recorded.
    mutating func readSourceBatch(_ arguments: [String: Any], maximumBytes cap: Int) throws -> String {
        guard let ids = arguments["ids"] as? [String], (1...8).contains(ids.count),
              Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.count <= 400 && !$0.contains("\n") && !$0.contains("\r") }),
              Set(arguments.keys).isSubset(of: ["ids", "length"]) else {
            throw invalid("批量原文需1至8个不重复的ids，与id二选一；从各页开头读，局部续读或核hash用单个id/offset。")
        }
        var remainingCharacters = try number(arguments, "length", fallback: 12000, maximum: 12000)
        guard remainingCharacters > 0 else { throw invalid("length须为1至12000的总字符上限。") }
        let index = Dictionary(snapshot.sources.map { ($0.unitID, $0) }, uniquingKeysWith: { first, _ in first })
        let sources = try ids.map { id in
            guard let value = index[id] else { throw invalid("批量原文含不在本次冻结范围内的ID；整次未读取。") }
            return value
        }
        var items = [[String: Any]](), fragments = [(String, String)](), consumed = 0, truncated = false
        func envelope(_ items: [[String: Any]], consumed: Int, partial: Bool) -> [String: Any] {
            ["ok": true, "items": items, "remainingIDs": Array(ids.dropFirst(consumed)),
             "partial": partial || consumed < ids.count, "bodyProvided": !items.isEmpty,
             "budgetLimited": items.isEmpty && consumed < ids.count]
        }
        for (offset, source) in sources.enumerated() {
            try Task.checkCancellation()
            guard remainingCharacters > 0 else { break }
            // Complete metadata and the still-unread ID list are inside the
            // budget. Two safety bytes cover the comma and true -> false when
            // the final row completes the whole requested batch.
            let overhead = try json(envelope(items, consumed: offset + 1, partial: true)).utf8.count
            let available = cap - overhead - 2
            guard available > 0 else { break }
            let slice: (text: String, result: String)
            do {
                slice = try readSlice(source.text, ["length": remainingCharacters], available,
                    metadata: ["ok": true, "id": source.unitID, "citation": "[unit:\(source.unitID)]",
                               "locator": source.locator, "hash": source.textHash, "scope": snapshot.scope.rawValue])
            } catch let error as ReadingError {
                // Input length and every ID were already validated. At this
                // point readSlice can fail only to fit a whole character plus
                // its metadata. Leave the unit unread, rather than discarding
                // preceding actual fragments or granting this page.
                if items.isEmpty { throw error }
                break
            }
            let row = try JSONSerialization.jsonObject(with: Data(slice.result.utf8)) as! [String: Any]
            let partial = row["nextOffset"] is Int
            let candidate = items + [row]
            guard try json(envelope(candidate, consumed: offset + 1, partial: partial)).utf8.count <= cap else { break }
            items = candidate; consumed = offset + 1; truncated = partial
            remainingCharacters -= slice.text.count
            if !slice.text.isEmpty { fragments.append((source.unitID, slice.text)) }
            if partial { break }
        }
        let result = try json(envelope(items, consumed: consumed, partial: truncated))
        guard result.utf8.count <= cap else {
            return try json(["ok": false, "budgetLimited": true, "message": "剩余空间不足以返回批读的单元定位；请缩短ids列表。"])
        }
        for (id, text) in fragments { recordSourceExcerpt(id, text: text) }
        return result
    }
}
