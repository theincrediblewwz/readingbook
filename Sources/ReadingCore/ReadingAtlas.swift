import Foundation

public struct ReadingAtlasChapter: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var unitIDs: [String]
    public var completedUnits: Int
    public var receiptUnits: Int
    public var translatedUnits: Int
    public var translationTouchedUnits: Int
    public var translatableUnits: Int
    public var translationRatio: Double { translatableUnits == 0 ? 0 : Double(translatedUnits) / Double(translatableUnits) }
}

public struct ReadingAtlasTypeCount: Identifiable, Hashable, Sendable {
    public var typeID: String
    public var title: String
    public var entityIDs: [String]
    public var id: String { typeID }
    public var count: Int { entityIDs.count }
}

/// Density by an event's stated starting year. A spanning event is counted once, never once per year.
public struct ReadingAtlasYearBucket: Identifiable, Hashable, Sendable {
    public var start: Int
    public var end: Int
    public var eventIDs: [String]
    public var id: String { "year.\(start).\(end)" }
    public var count: Int { eventIDs.count }
}

/// A shared cited source unit, not a claim of acquaintance, causation, or logical dependency.
public struct ReadingAtlasCooccurrence: Identifiable, Hashable, Sendable {
    public var fromID: String
    public var toID: String
    public var unitIDs: [String]
    public var id: String { "\(fromID)::\(toID)" }
    public var count: Int { unitIDs.count }
}

public struct ReadingAtlasSnapshot: Hashable, Sendable {
    public var chapters: [ReadingAtlasChapter]
    public var typeCounts: [ReadingAtlasTypeCount]
    public var yearBuckets: [ReadingAtlasYearBucket]
    public var undatedEventIDs: [String]
    public var cooccurrences: [ReadingAtlasCooccurrence]
    public var invalidEvidenceCount: Int
    public var cooccurrencesBounded: Bool
}

public enum ReadingAtlasRuntime {
    public static func build(_ project: BookProject) -> ReadingAtlasSnapshot {
        if Task.isCancelled { return emptySnapshot() }
        let unitGroups = Dictionary(grouping: project.units, by: \.id)
        let units = project.units.filter { unitGroups[$0.id]?.count == 1 }.sorted {
            $0.order == $1.order ? less($0.id, $1.id) : $0.order < $1.order
        }
        let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let unitOrder = Dictionary(uniqueKeysWithValues: units.enumerated().map { ($0.element.id, $0.offset) })
        func orderedUnitIDs(_ ids: Set<String>) -> [String] {
            ids.sorted { (unitOrder[$0] ?? Int.max) == (unitOrder[$1] ?? Int.max) ? less($0, $1) : (unitOrder[$0] ?? Int.max) < (unitOrder[$1] ?? Int.max) }
        }
        var invalidEvidenceCount = 0
        func validEvidenceUnits(_ evidence: [Evidence]) -> Set<String> {
            var valid = Set<String>()
            for source in evidence {
                if Task.isCancelled { break }
                guard let unit = byID[source.unitID], !source.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let range = unit.text.range(of: source.quote, options: [.literal]),
                      unit.text[range].utf8.elementsEqual(source.quote.utf8) else { invalidEvidenceCount += 1; continue }
                valid.insert(unit.id)
            }
            return valid
        }
        let entityGroups = Dictionary(grouping: project.entities, by: \.id)
        let entities = project.entities.filter { entityGroups[$0.id]?.count == 1 }.sorted { less($0.id, $1.id) }
        var entitiesByUnit: [String: Set<String>] = [:]
        for entity in entities {
            if Task.isCancelled { return emptySnapshot() }
            for id in validEvidenceUnits(entity.evidence) { entitiesByUnit[id, default: []].insert(entity.id) }
        }
        let eventGroups = Dictionary(grouping: project.events, by: \.id)
        let events = project.events.filter { eventGroups[$0.id]?.count == 1 }.sorted { less($0.id, $1.id) }
        var dated: [(id: String, year: Int)] = [], undated: [String] = []
        for event in events {
            if Task.isCancelled { return emptySnapshot() }
            guard !validEvidenceUnits(event.evidence).isEmpty else { continue }
            if let year = event.startYear { dated.append((event.id, year)) }
            else { undated.append(event.id) }
        }
        dated.sort { $0.year == $1.year ? less($0.id, $1.id) : $0.year < $1.year }
        var buckets: [ReadingAtlasYearBucket] = []
        if let first = dated.first, let last = dated.last {
            let bucketCount = min(24, dated.count)
            let minimum = Double(first.year), span = Double(last.year) - minimum
            var groups: [Int: [(id: String, year: Int)]] = [:]
            for event in dated {
                if Task.isCancelled { return emptySnapshot() }
                // Double arithmetic avoids overflowing Int.min...Int.max subtraction.
                // Bucket boundaries below are actual Int years, never a rounded Double-to-Int year conversion.
                let position = span > 0 ? (Double(event.year) - minimum) / span : 0
                let slot = max(0, min(bucketCount - 1, Int((position * Double(bucketCount)).rounded(.down))))
                groups[slot, default: []].append(event)
            }
            buckets = groups.keys.sorted().compactMap { key in
                guard let values = groups[key], let start = values.first?.year, let end = values.last?.year else { return nil }
                return ReadingAtlasYearBucket(start: start, end: end, eventIDs: values.map { $0.id })
            }
        }

        var translationRanges: [String: [NSRange]] = [:]
        let experience = project.readingExperience ?? ReadingExperienceState()
        let anchors = Dictionary(experience.anchors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolvedTranslations: [String: ResolvedSourceAnchor] = [:]
        var unitResolvers: [String: (SourceAnchor) throws -> ResolvedSourceAnchor] = [:]
        for layer in experience.layers where layer.kind == "translation" {
            if Task.isCancelled { return emptySnapshot() }
            for id in Set(layer.sourceAnchorIDs) {
                if Task.isCancelled { return emptySnapshot() }
                if let resolved = resolvedTranslations[id] { translationRanges[resolved.unitID, default: []].append(resolved.range); continue }
                guard let anchor = anchors[id], byID[anchor.unitID] != nil else { continue }
                let resolved: ResolvedSourceAnchor
                do {
                    let resolver: (SourceAnchor) throws -> ResolvedSourceAnchor
                    if let existing = unitResolvers[anchor.unitID] { resolver = existing }
                    else {
                        resolver = try ReadingExperienceRuntime.anchorResolver(sourceHash: project.sourceHash, unitID: anchor.unitID, in: project)
                        unitResolvers[anchor.unitID] = resolver
                    }
                    resolved = try resolver(anchor)
                } catch { continue }
                resolvedTranslations[id] = resolved
                translationRanges[resolved.unitID, default: []].append(resolved.range)
            }
        }
        var chapterTitles: [String] = [], chapterUnits: [String: [SourceUnit]] = [:]
        for unit in units {
            if Task.isCancelled { return emptySnapshot() }
            let title = unit.chapter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未分章" : unit.chapter
            if chapterUnits[title] == nil { chapterTitles.append(title) }
            chapterUnits[title, default: []].append(unit)
        }
        let receiptUnitIDs = Set((project.paragraphReceipts ?? []).map(\.unitID))
        let receiptsByUnit = (project.paragraphReceipts?.count ?? 0) > 16
            ? Dictionary(grouping: project.paragraphReceipts ?? [], by: \.unitID) : nil
        var chapters: [ReadingAtlasChapter] = []
        for title in chapterTitles {
            if Task.isCancelled { return emptySnapshot() }
            let group = chapterUnits[title] ?? []
            var translated = 0, receipted = 0, completed = 0, touched = 0, translatable = 0
            for unit in group {
                if Task.isCancelled { return emptySnapshot() }
                if rangesCoverSource(translationRanges[unit.id] ?? [], text: unit.text) { translated += 1 }
                if receiptUnitIDs.contains(unit.id) {
                    var receiptProject = project
                    if let receiptsByUnit {
                        receiptProject.units = [unit]
                        receiptProject.paragraphReceipts = receiptsByUnit[unit.id] ?? []
                    }
                    if (try? ReadingLedger.requireComplete(unitIDs: [unit.id], in: receiptProject)) != nil { receipted += 1 }
                }
                if project.coverage[unit.id]?.status == .completed { completed += 1 }
                if !(translationRanges[unit.id] ?? []).isEmpty { touched += 1 }
                if !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translatable += 1 }
            }
            chapters.append(ReadingAtlasChapter(id: stableID(project.sourceHash + "\n" + title), title: title, unitIDs: group.map(\.id),
                                       completedUnits: completed,
                                       receiptUnits: receipted, translatedUnits: translated,
                                       translationTouchedUnits: touched, translatableUnits: translatable))
        }
        let typeTitles = Dictionary(project.types.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let typeGroups = Dictionary(grouping: entities, by: \.typeID)
        let types = typeGroups.map { key, values in ReadingAtlasTypeCount(typeID: key, title: typeTitles[key] ?? key, entityIDs: values.map(\.id)) }.sorted {
            $0.count == $1.count ? less($0.typeID, $1.typeID) : $0.count > $1.count
        }
        var pairs: [Pair: Set<String>] = [:], bounded = false
        var combinations = 0
        // Bound total traversal and stored pair/unit contributions, not just distinct pairs.
        // Otherwise the same pair repeated across a huge book could grow without limit.
        cooccurrenceScan: for unit in units {
            if Task.isCancelled { return emptySnapshot() }
            let all = (entitiesByUnit[unit.id] ?? []).sorted(by: less)
            if all.count > 128 { bounded = true }
            let ids = Array(all.prefix(128))
            guard ids.count >= 2 else { continue }
            for from in 0..<(ids.count - 1) {
                for to in (from + 1)..<ids.count {
                    if Task.isCancelled { return emptySnapshot() }
                    guard combinations < 200_000 else { bounded = true; break cooccurrenceScan }
                    combinations += 1
                    let pair = Pair(from: ids[from], to: ids[to])
                    if pairs[pair] == nil && pairs.count >= 100_000 { bounded = true; continue }
                    pairs[pair, default: []].insert(unit.id)
                }
            }
        }
        if Task.isCancelled { return emptySnapshot() }
        let allPairs = pairs.map { pair, ids in ReadingAtlasCooccurrence(fromID: pair.from, toID: pair.to, unitIDs: orderedUnitIDs(ids)) }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.fromID != $1.fromID { return less($0.fromID, $1.fromID) }
            return less($0.toID, $1.toID)
        }
        if allPairs.count > 40 { bounded = true }
        if Task.isCancelled { return emptySnapshot() }
        return ReadingAtlasSnapshot(chapters: chapters, typeCounts: types, yearBuckets: buckets, undatedEventIDs: undated,
                                    cooccurrences: Array(allPairs.prefix(40)), invalidEvidenceCount: invalidEvidenceCount, cooccurrencesBounded: bounded)
    }

    private static func emptySnapshot() -> ReadingAtlasSnapshot {
        ReadingAtlasSnapshot(chapters: [], typeCounts: [], yearBuckets: [], undatedEventIDs: [], cooccurrences: [], invalidEvidenceCount: 0, cooccurrencesBounded: false)
    }

    private struct Pair: Hashable { var from: String; var to: String }
    private static func less(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }
    private static func stableID(_ value: String) -> String {
        if let hash = try? BookImporter.sha256(Data(value.utf8)) { return "chapter." + String(hash.prefix(32)) }
        // Deterministic fallback for source inspection on platforms without CryptoKit.
        var valueHash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { valueHash ^= UInt64(byte); valueHash = valueHash &* 1_099_511_628_211 }
        return "chapter." + String(valueHash, radix: 16)
    }
    private static func rangesCoverSource(_ ranges: [NSRange], text: String) -> Bool {
        guard !ranges.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let source = text as NSString
        var covered = 0
        for range in ranges.sorted(by: { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }) {
            guard range.location >= 0, range.length >= 0, range.location <= source.length, range.length <= source.length - range.location else { return false }
            if range.location > covered, !source.substring(with: NSRange(location: covered, length: range.location - covered)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            covered = max(covered, range.location + range.length)
        }
        return source.substring(from: covered).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
