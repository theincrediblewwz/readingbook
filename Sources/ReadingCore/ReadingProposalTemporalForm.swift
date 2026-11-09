import Foundation

/// Repair feedback is scoped to text already supplied to this task. Failed
/// forms remain atomic: reporting several fields never applies a partial batch.
struct ReadingProposalTemporalError: LocalizedError {
    let issues: [[String: Any]]
    var metadataIssues: [[String: String]] = []
    var errorDescription: String? { "时间资料有字段需要核对；请一起修正temporalIssues与metadataIssues后显式重交。整批未保存。" }
}

extension ReadingQuerySession {
    /// sourceSpan is a transport convenience, not a second stored time model.
    /// Resolve anchor identities to real SourceUnit.order; never parse IDs or
    /// search unseen book text to guess the model's intended location.
    func resolveTemporalSourceSpans(in data: Data) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var batch = root["batch"] as? [String: Any] ?? root
        let wrapped = root["batch"] != nil
        let grouped = batch["knowledge"] != nil
        var knowledge = batch["knowledge"] as? [String: Any] ?? batch
        let path = (wrapped ? "$.batch" : "$") + (grouped ? ".knowledge" : "")
        let anchors = suppliedTemporalAnchors(knowledge: knowledge)
        var issues: [[String: Any]] = []
        for (collection, field) in [("presences", "extent"), ("participations", "extent"), ("eventMetadata", "extent"), ("relationMetadata", "validity")] {
            guard var rows = knowledge[collection] as? [[String: Any]] else { continue }
            for index in rows.indices {
                guard var extent = rows[index][field] as? [String: Any], let rawSpan = extent["sourceSpan"] else { continue }
                let prefix = path + ".\(collection)[\(index)].\(field)"
                func fail(_ reason: String) { issues.append(["path": prefix + ".sourceSpan", "reason": reason]) }
                guard let span = rawSpan as? [String: Any], Set(span.keys).isSubset(of: ["startAnchorID", "endAnchorID"]),
                      let startID = span["startAnchorID"] as? String, !startID.isEmpty,
                      span["endAnchorID"] == nil || span["endAnchorID"] is String else {
                    fail("只填startAnchorID及可选endAnchorID，使用本条sourceAnchorIDs中的真实锚点编号。"); continue
                }
                guard extent["precision"] as? String == "narrative",
                      extent["narrativeDomain"] == nil || extent["narrativeDomain"] as? String == "source-order",
                      ["start", "end", "calendar", "narrativeStart", "narrativeEnd"].allSatisfy({ extent[$0] == nil }) else {
                    fail("sourceSpan只确定原文先后；precision用narrative，不混填日期、历法或手算的叙事序号。"); continue
                }
                let endID = span["endAnchorID"] as? String ?? startID
                let declared = Set(rows[index]["sourceAnchorIDs"] as? [String] ?? [])
                guard declared.contains(startID), declared.contains(endID), let start = anchors[startID], let end = anchors[endID] else {
                    // A malformed quotation must not look like a missing time
                    // endpoint. Return the existing evidence repair shape;
                    // never normalize or silently replace the proposed quote.
                    if declared.contains(startID), declared.contains(endID) {
                        let evidenceIssues = suppliedAnchorQuoteIssues(knowledge: knowledge, path: path,
                            ids: Set([startID, endID]).subtracting(anchors.keys))
                        if !evidenceIssues.isEmpty { throw ReadingProposalEvidenceError(issues: evidenceIssues) }
                    }
                    fail("两端都须在本条sourceAnchorIDs中，且其逐字原文已实际提供；不能借用未读取、范围外或未知锚点。"); continue
                }
                guard end.order >= start.order else { fail("结束锚点在开始锚点之前，请核对原文先后。"); continue }
                extent.removeValue(forKey: "sourceSpan")
                extent["narrativeDomain"] = "source-order"; extent["narrativeStart"] = start.order
                if span["endAnchorID"] != nil { extent["narrativeEnd"] = end.order }
                rows[index][field] = extent
            }
            knowledge[collection] = rows
        }
        if !issues.isEmpty { throw ReadingProposalTemporalError(issues: Array(issues.prefix(16))) }
        if grouped { batch["knowledge"] = knowledge } else { batch = knowledge }
        if wrapped { root["batch"] = batch } else { root = batch }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func suppliedAnchorQuoteIssues(knowledge: [String: Any], path: String, ids: Set<String>) -> [[String: String]] {
        let rows = knowledge["anchors"] as? [[String: Any]] ?? []
        let counts = Dictionary(rows.compactMap { ($0["clientID"] as? String).map { ($0, 1) } }, uniquingKeysWith: +)
        let existing = Set(((project?.readingExperience?.anchors ?? []) + (project?.temporalKnowledge?.anchors ?? [])).map(\.id))
        var issues = [[String: String]]()
        for (index, row) in rows.enumerated() {
            guard let id = row["clientID"] as? String, ids.contains(id), counts[id] == 1, !existing.contains(id),
                  let unitID = row["unitID"] as? String, snapshot.unitIDs.contains(unitID),
                  let quote = row["quote"] as? String, !quote.isEmpty,
                  sourceExcerpts.contains(where: { $0.0 == unitID }),
                  !sourceExcerpts.contains(where: { $0.0 == unitID && SourceTextLiteral.contains(quote, in: $0.1) }) else { continue }
            var issue = ["path": path + ".anchors[\(index)]", "unitID": unitID,
                "reason": "这个单元已提供，但锚点引文不逐字匹配（包括原始换行）；请核对quote。可保留clientID，用有效sourceRef替代unitID/quote，由软件定位已提供片段。"]
            if let ref = sourceReferences.keys.sorted().first(where: { key in
                guard let value = sourceReferences[key], value.unitID == unitID else { return false }
                return sourceExcerpts.contains { $0.0 == unitID && SourceTextLiteral.contains(value.quote, in: $0.1) }
            }) { issue["suppliedUnitSourceRef"] = ref }
            issues.append(issue)
            if issues.count == 4 { break }
        }
        return issues
    }

    private struct SuppliedTemporalAnchor {
        var unitID: String
        var order: Int
        var quote: String
    }

    private func suppliedTemporalAnchors(knowledge: [String: Any]) -> [String: SuppliedTemporalAnchor] {
        guard let project else { return [:] }
        let units = Dictionary(project.units.filter { snapshot.unitIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: SuppliedTemporalAnchor] = [:]
        func insert(id: String, unitID: String, quote: String) {
            guard let unit = units[unitID], !quote.isEmpty,
                  SourceTextLiteral.contains(quote, in: unit.text),
                  sourceExcerpts.contains(where: { $0.0 == unitID && SourceTextLiteral.contains(quote, in: $0.1) }) else { return }
            result[id] = .init(unitID: unitID, order: unit.order, quote: quote)
        }
        for anchor in (project.readingExperience?.anchors ?? []) + (project.temporalKnowledge?.anchors ?? []) {
            insert(id: anchor.id, unitID: anchor.unitID, quote: anchor.quote)
        }
        // A proposed alias cannot shadow an existing anchor, even in feedback.
        let existing = Set(((project.readingExperience?.anchors ?? []) + (project.temporalKnowledge?.anchors ?? [])).map(\.id))
        let rows = knowledge["anchors"] as? [[String: Any]] ?? []
        let counts = Dictionary(rows.compactMap { ($0["clientID"] as? String).map { ($0, 1) } }, uniquingKeysWith: +)
        for row in rows {
            if let id = row["clientID"] as? String, !existing.contains(id), counts[id] == 1,
               let unitID = row["unitID"] as? String, let quote = row["quote"] as? String {
                insert(id: id, unitID: unitID, quote: quote)
            }
        }
        return result
    }

    func temporalFormIssues(in data: Data) throws -> [[String: Any]] {
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let batch = raw["batch"] as? [String: Any] ?? raw
        let knowledge = batch["knowledge"] as? [String: Any] ?? batch
        let path = (raw["batch"] != nil ? "$.batch" : "$") + (batch["knowledge"] != nil ? ".knowledge" : "")
        let anchors = suppliedTemporalAnchors(knowledge: knowledge)
        var issues: [[String: Any]] = []
        for (collection, field) in [("presences", "extent"), ("participations", "extent"), ("eventMetadata", "extent"), ("relationMetadata", "validity")] {
            for (index, row) in (knowledge[collection] as? [[String: Any]] ?? []).enumerated() {
                guard let rawExtent = row[field] as? [String: Any] else { continue }
                let extentData = try JSONSerialization.data(withJSONObject: rawExtent)
                var extent = try JSONDecoder().decode(TemporalExtent.self, from: extentData)
                let prefix = path + ".\(collection)[\(index)].\(field)"
                let ids = row["sourceAnchorIDs"] as? [String] ?? []
                let sources = ids.compactMap { anchors[$0] }
                var reasons: [(String, String)] = []
                // Use the same newline-only matching as the controlled builder.
                // Punctuation, spelling, dates and unseen text are not repaired.
                let literalAnchors = sources.map { SourceAnchor(id: "", sourceHash: snapshot.sourceHash, unitID: $0.unitID, quote: $0.quote) }
                extent.sourceText = ReadingTemporalSourceText.canonical(extent.sourceText, anchors: literalAnchors)
                if !extent.sourceText.isEmpty, !sources.contains(where: { SourceTextLiteral.contains(extent.sourceText, in: $0.quote) }) {
                    reasons.append((".sourceText", "时间短语不在本条引用的逐字原文中。核对引文；若只表示原文先后，用sourceSpan，并将sourceText留空，不能补写一句原文。"))
                }
                do { try TemporalKnowledgeRuntime.validateExtent(extent) }
                catch { reasons.append(("", error.localizedDescription)) }
                if extent.narrativeDomain == "source-order" {
                    let orders = Set(sources.map(\.order))
                    if extent.narrativeStart.map(orders.contains) != true || !(extent.narrativeEnd.map(orders.contains) ?? true) {
                        reasons.append((".narrativeStart", "序号不属于本条引用的原文。可用sourceSpan交给软件按真实order定位，无需手算页码或章回。"))
                    }
                }
                for (suffix, reason) in reasons where issues.count < 16 {
                    var issue: [String: Any] = ["path": prefix + suffix, "reason": reason]
                    issue["providedAnchors"] = ids.prefix(4).compactMap { id -> [String: Any]? in
                        guard let anchor = anchors[id] else { return nil }
                        return ["anchorID": id, "unitID": anchor.unitID, "order": anchor.order, "textPreview": String(anchor.quote.prefix(160))]
                    }
                    issues.append(issue)
                }
            }
        }
        return issues
    }
}
