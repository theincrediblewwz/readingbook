import Foundation

/// A bounded, per-question index of objects actually returned by read tools.
/// This is derived context, never evidence, a second knowledge store or a grant.
struct ReadingReturnedObjectDirectory {
    private struct Entry { var id: String; var version: String; var json: String }
    private var entries: [Entry] = []
    var isEmpty: Bool { entries.isEmpty }

    mutating func removeAll() { entries.removeAll() }

    mutating func record(_ result: String, tool: String, allowedUnits: Set<String>) throws {
        guard ["object_get", "objects_search", "events_query"].contains(tool),
              let root = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
              root["ok"] as? Bool != false else { return }
        let rows = (root["items"] as? [[String: Any]] ?? []) + (root["object"] != nil ? [root] : [])
        for wrapper in rows {
            try Task.checkCancellation()
            let object = wrapper["object"] as? [String: Any] ?? wrapper
            guard let id = object["id"] as? String, let name = object["name"] as? String,
                  let version = object["version"] as? String else { continue }
            if wrapper["identityOnly"] as? Bool == true {
                entries.removeAll { $0.id == id }; continue
            }
            var row: [String: Any] = ["id": id, "name": String(name.prefix(200)), "version": version]
            if name.count > 200 { row["nameTruncated"] = true }
            for key in ["kind", "typeID"] { if let value = object[key] as? String { row[key] = String(value.prefix(80)) } }
            if let summary = object["summary"] as? String {
                row["summary"] = String(summary.prefix(160))
                if summary.count > 160 { row["summaryTruncated"] = true }
            }
            if let fields = object["fields"] as? [String: String] {
                var kept: [String: String] = [:]
                for key in fields.keys.sorted().prefix(16) where key.count <= 80 { kept[key] = String(fields[key]!.prefix(160)) }
                row["fields"] = kept
                if kept != fields { row["fieldsPartial"] = true }
            }
            if let references = object["references"] as? [String: [String]] {
                row["references"] = references.mapValues { Array($0.prefix(16)) }
                if references.values.contains(where: { $0.count > 16 }) { row["referencesPartial"] = true }
            }
            let units = object["sourceUnitIDs"] as? [String]
                ?? (object["evidence"] as? [[String: Any]] ?? []).compactMap { $0["unitID"] as? String }
            row["sourceUnitIDs"] = Array(Set(units).intersection(allowedUnits)).sorted().prefix(32).map { $0 }
            if Set(units).intersection(allowedUnits).count > 32 { row["sourcesPartial"] = true }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                let prior = entries.remove(at: index)
                // A same-version name search is a thinner view, not a new
                // object that should erase fields already actually returned.
                if prior.version == version,
                   var merged = try JSONSerialization.jsonObject(with: Data(prior.json.utf8)) as? [String: Any] {
                    merged.merge(row) { _, new in new }; row = merged
                }
            }
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            guard data.count <= 4096 else { continue }
            entries.append(Entry(id: id, version: version, json: String(decoding: data, as: UTF8.self)))
            while entries.count > 64 || entries.reduce(0, { $0 + $1.json.utf8.count }) > 48_000 { entries.removeFirst() }
        }
    }

    func rows(maximumBytes: Int) throws -> (values: [[String: Any]], partial: Bool) {
        var rows: [[String: Any]] = [], used = 2
        for entry in entries.reversed() {
            try Task.checkCancellation()
            guard entry.json.utf8.count + used + 1 <= maximumBytes else { break }
            used += entry.json.utf8.count + 1
            rows.append(try JSONSerialization.jsonObject(with: Data(entry.json.utf8)) as! [String: Any])
        }
        return (rows.reversed(), rows.count < entries.count)
    }
}
