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
}

public struct LibrarySearchResponse: Sendable {
    public var query: String
    public var matches: [LibraryTextMatch]
    public var entityMatches: [LibraryEntityMatch]
    public var searchedBookCount: Int
    public var scannedUnitCount: Int
    /// Reaching a bound stops scanning; counts must not be presented as whole-library totals.
    public var bounded: Bool
    public init(query: String, matches: [LibraryTextMatch] = [], entityMatches: [LibraryEntityMatch] = [], searchedBookCount: Int = 0, scannedUnitCount: Int = 0, bounded: Bool = false) {
        self.query = query; self.matches = matches; self.entityMatches = entityMatches
        self.searchedBookCount = searchedBookCount; self.scannedUnitCount = scannedUnitCount; self.bounded = bounded
    }
}

public enum LibraryTextSearch {
    /// Literal Unicode text search over original strings. Case folding is used
    /// only to find a range; returned quotes and offsets always come from the source.
    public static func search(query: String, snapshots: [LibrarySourceSnapshot], bookID: String? = nil,
                              resultLimit: Int = 150, entityLimit: Int = 36) throws -> LibrarySearchResponse {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= 400, (1...500).contains(resultLimit), (0...100).contains(entityLimit) else {
            throw ReadingError.invalid("检索词最多400字，原文结果上限须在1–500之间。")
        }
        let books = snapshots.filter { bookID == nil || $0.bookID == bookID }
        guard !query.isEmpty else { return LibrarySearchResponse(query: query, searchedBookCount: books.count) }
        var response = LibrarySearchResponse(query: query, searchedBookCount: books.count)
        sourceScan: for book in books {
            try Task.checkCancellation()
            for unit in book.units.sorted(by: { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }) {
                try Task.checkCancellation()
                response.scannedUnitCount += 1
                var remaining = unit.text.startIndex..<unit.text.endIndex
                var unitHash: String?
                while let found = unit.text.range(of: query, options: [.caseInsensitive], range: remaining) {
                    try Task.checkCancellation()
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
                                                             hasLaterText: snippetEnd < unit.text.endIndex))
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
                    guard let matched = ([entity.name] + entity.aliases).first(where: { $0.range(of: query, options: [.caseInsensitive]) != nil }) else { continue }
                    response.entityMatches.append(LibraryEntityMatch(bookID: book.bookID, bookTitle: book.title, sourceHash: book.sourceHash, entity: entity, matchedName: matched))
                    if response.entityMatches.count == entityLimit { response.bounded = true; break entityScan }
                }
            }
        }
        return response
    }
}
