import Foundation

/// Immutable in-memory input. Searching never opens book files, notes, or a network connection.
public struct LibrarySourceSnapshot: Hashable, Sendable {
    public var bookID: String
    public var title: String
    public var sourceHash: String
    public var units: [SourceUnit]
    public var entities: [KnowledgeEntity]
    public init(bookID: String, title: String, sourceHash: String, units: [SourceUnit], entities: [KnowledgeEntity] = []) {
        self.bookID = bookID; self.title = title; self.sourceHash = sourceHash
        self.units = units; self.entities = entities
    }
    public init(project: BookProject) {
        self.init(bookID: project.id, title: project.title, sourceHash: project.sourceHash, units: project.units, entities: project.entities)
    }
}

public struct LibraryTextMatch: Identifiable, Hashable, Sendable {
    public var id: String { bookID + "::" + unitID + "::" + String(utf16Location) }
    public var bookID: String
    public var bookTitle: String
    public var sourceHash: String
    public var unitID: String
    public var unitTextHash: String
    public var locator: String
    public var page: Int?
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var utf16Location: Int
    public var utf16Length: Int
    public var snippetBefore: String
    public var snippetAfter: String
    public var hasEarlierText: Bool
    public var hasLaterText: Bool
    /// The user's original or explicitly expanded keyword, never a model quote.
    public var matchedQuery: String = ""
    public var range: NSRange { NSRange(location: utf16Location, length: utf16Length) }

    /// A stale result cannot silently acquire a different source position.
    public func validate(in project: BookProject) throws {
        guard project.id == bookID, project.sourceHash == sourceHash,
              let unit = project.units.first(where: { $0.id == unitID }),
              try BookImporter.sha256(Data(unit.text.utf8)) == unitTextHash,
              let sourceRange = Range(range, in: unit.text),
              String(unit.text[sourceRange]).utf8.elementsEqual(quote.utf8) else {
            throw ReadingError.invalid("检索结果的原文版本已变化，请重新搜索后定位。")
        }
    }
}

/// Matching names in different books remain separate records. This is a discovery
/// aid, not an assertion that two people or concepts have the same identity.
public struct LibraryEntityMatch: Identifiable, Hashable, Sendable {
    public var id: String { bookID + "::" + entity.id }
    public var bookID: String
    public var bookTitle: String
    public var sourceHash: String
    public var entity: KnowledgeEntity
    public var matchedName: String
    public var matchedQuery: String = ""
}

public struct LibrarySearchResponse: Sendable {
    public var query: String
    public var matches: [LibraryTextMatch]
    public var entityMatches: [LibraryEntityMatch]
    public var searchedBookCount: Int
    public var scannedUnitCount: Int
    /// Reaching a bound stops scanning; counts must not be presented as whole-library totals.
    public var bounded: Bool
    public var searchedQueries: [String]
    public init(query: String, matches: [LibraryTextMatch] = [], entityMatches: [LibraryEntityMatch] = [], searchedBookCount: Int = 0, scannedUnitCount: Int = 0, bounded: Bool = false, searchedQueries: [String]? = nil) {
        self.query = query; self.matches = matches; self.entityMatches = entityMatches
        self.searchedBookCount = searchedBookCount; self.scannedUnitCount = scannedUnitCount; self.bounded = bounded
        self.searchedQueries = searchedQueries ?? (query.isEmpty ? [] : [query])
    }
}

public enum LibraryTextSearch {
    private struct Term {
        let query: String
        let literals: [String]
        let canonical: [String]
    }
    private struct Found { let range: Range<String.Index>; let query: String }

    /// Offline script/case/width equivalence over original strings. A temporary
    /// character-boundary map keeps returned quotes and UTF-16 offsets exact.
    /// Contextual ICU phrase variants supplement, but do not promise all synonyms.
    public static func search(query: String, snapshots: [LibrarySourceSnapshot], bookID: String? = nil,
                              resultLimit: Int = 150, entityLimit: Int = 36,
                              additionalQueries: [String] = []) throws -> LibrarySearchResponse {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= 400, (1...500).contains(resultLimit), (0...100).contains(entityLimit) else {
            throw ReadingError.invalid("检索词最多400字，原文结果上限须在1–500之间。")
        }
        guard additionalQueries.count <= 8 else { throw ReadingError.invalid("扩展检索最多8个关键词。") }
        let additional = additionalQueries.isEmpty ? [] : try LibrarySearchExpansionPlan(keywords: additionalQueries).keywords
        let books = snapshots.filter { bookID == nil || $0.bookID == bookID }
        guard !query.isEmpty else { return LibrarySearchResponse(query: query, searchedBookCount: books.count) }
        var canonicalizer = LibrarySearchCanonicalizer()
        var queryIdentities = Set<String>(), queries: [String] = []
        for word in [query] + additional {
            let identity = word.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if queryIdentities.insert(identity).inserted { queries.append(word) }
        }
        let terms = try queries.map { try term($0, canonicalizer: &canonicalizer) }
        let needsCanonical = terms.contains { !$0.canonical.isEmpty }
        var response = LibrarySearchResponse(query: query, searchedBookCount: books.count, searchedQueries: queries)
        sourceScan: for book in books {
            try Task.checkCancellation()
            for unit in book.units.sorted(by: { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }) {
                try Task.checkCancellation()
                response.scannedUnitCount += 1
                let mapped = needsCanonical && LibrarySearchCanonicalizer.containsHan(unit.text)
                    ? try LibrarySearchMappedText(unit.text, canonicalizer: &canonicalizer) : nil
                var remaining = unit.text.startIndex..<unit.text.endIndex
                var unitHash: String?
                while let candidate = try next(in: unit.text, remaining: remaining, terms: terms, mapped: mapped, canonicalizer: &canonicalizer) {
                    try Task.checkCancellation()
                    let found = candidate.range
                    guard !found.isEmpty else { break }
                    if unitHash == nil { unitHash = try BookImporter.sha256(Data(unit.text.utf8)) }
                    let snippetStart = unit.text.index(found.lowerBound, offsetBy: -80, limitedBy: unit.text.startIndex) ?? unit.text.startIndex
                    let snippetEnd = unit.text.index(found.upperBound, offsetBy: 120, limitedBy: unit.text.endIndex) ?? unit.text.endIndex
                    let before = String(unit.text[snippetStart..<found.lowerBound])
                    let after = String(unit.text[found.upperBound..<snippetEnd])
                    let range = NSRange(found, in: unit.text)
                    response.matches.append(LibraryTextMatch(bookID: book.bookID, bookTitle: book.title, sourceHash: book.sourceHash,
                                                             unitID: unit.id, unitTextHash: unitHash ?? "", locator: unit.locator, page: unit.page,
                                                             quote: String(unit.text[found]), prefix: String(before.suffix(64)), suffix: String(after.prefix(64)),
                                                             utf16Location: range.location, utf16Length: range.length,
                                                             snippetBefore: before, snippetAfter: after,
                                                             hasEarlierText: snippetStart > unit.text.startIndex,
                                                             hasLaterText: snippetEnd < unit.text.endIndex, matchedQuery: candidate.query))
                    if response.matches.count == resultLimit { response.bounded = true; break sourceScan }
                    remaining = found.upperBound..<unit.text.endIndex
                }
            }
        }
        if entityLimit > 0 {
            entityScan: for book in books {
                try Task.checkCancellation()
                for entity in book.entities {
                    try Task.checkCancellation()
                    var matched: (String, String)?
                    for name in [entity.name] + entity.aliases {
                        let mapped = needsCanonical && LibrarySearchCanonicalizer.containsHan(name)
                            ? try LibrarySearchMappedText(name, canonicalizer: &canonicalizer) : nil
                        if let found = try next(in: name, remaining: name.startIndex..<name.endIndex, terms: terms, mapped: mapped, canonicalizer: &canonicalizer) {
                            matched = (name, found.query); break
                        }
                    }
                    guard let matched else { continue }
                    response.entityMatches.append(LibraryEntityMatch(bookID: book.bookID, bookTitle: book.title, sourceHash: book.sourceHash, entity: entity, matchedName: matched.0, matchedQuery: matched.1))
                    if response.entityMatches.count == entityLimit { response.bounded = true; break entityScan }
                }
            }
        }
        return response
    }

    private static func term(_ query: String, canonicalizer: inout LibrarySearchCanonicalizer) throws -> Term {
        guard LibrarySearchCanonicalizer.containsHan(query) else { return Term(query: query, literals: [query], canonical: []) }
        var variants = [query]
        for transform in ["Traditional-Simplified", "Simplified-Traditional"] {
            if let variant = query.applyingTransform(StringTransform(rawValue: transform), reverse: false), !variants.contains(variant) {
                variants.append(variant)
            }
        }
        var canonical: [String] = []
        for variant in variants {
            let folded = try canonicalizer.fold(variant)
            if !folded.isEmpty, !canonical.contains(folded) { canonical.append(folded) }
        }
        return Term(query: query, literals: variants, canonical: canonical)
    }

    private static func next(in text: String, remaining: Range<String.Index>, terms: [Term],
                             mapped: LibrarySearchMappedText?, canonicalizer: inout LibrarySearchCanonicalizer) throws -> Found? {
        guard !remaining.isEmpty else { return nil }
        var best: Found?
        func consider(_ range: Range<String.Index>, query: String) {
            guard !range.isEmpty else { return }
            if best == nil || range.lowerBound < best!.range.lowerBound { best = Found(range: range, query: query) }
        }
        for term in terms {
            try Task.checkCancellation()
            for literal in term.literals {
                if let found = text.range(of: literal, options: [.caseInsensitive, .widthInsensitive], range: remaining) { consider(found, query: term.query) }
            }
            guard let mapped, !term.canonical.isEmpty else { continue }
            let offset = NSRange(remaining, in: text).location
            let start = mapped.canonicalStart(atOrAfter: offset)
            guard let searchStart = Range(NSRange(location: start, length: 0), in: mapped.text)?.lowerBound else { continue }
            for needle in term.canonical {
                var canonicalRemaining = searchStart..<mapped.text.endIndex
                while let found = mapped.text.range(of: needle, options: [.caseInsensitive], range: canonicalRemaining) {
                    try Task.checkCancellation()
                    guard !found.isEmpty else { break }
                    if let range = mapped.originalRange(NSRange(found, in: mapped.text)), let original = Range(range, in: text),
                       original.lowerBound >= remaining.lowerBound,
                       try canonicalizer.fold(String(text[original])).compare(needle, options: [.caseInsensitive]) == .orderedSame {
                        consider(original, query: term.query); break
                    }
                    // A hit inside an expanded Character is not a source range.
                    canonicalRemaining = found.upperBound..<mapped.text.endIndex
                }
            }
        }
        return best
    }
}
