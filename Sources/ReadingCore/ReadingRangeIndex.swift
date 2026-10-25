import Foundation

/// Immutable point lookup for source offsets. No text, PDFKit object or view
/// geometry is retained. Build this index when a page's matched ranges change,
/// never while drawing or processing a pointer movement.
public struct ReadingRangeIndex<ID: Hashable & Sendable>: Sendable {
    public struct Entry: Hashable, Sendable {
        public let id: ID
        public let range: NSRange

        public init(id: ID, range: NSRange) {
            self.id = id
            self.range = range
        }
    }

    private let orderedEntries: [Entry]
    private let ends: [Int]
    // Each sorted midpoint stores the largest end in its balanced subtree.
    // Unlike a prefix maximum, one long outer range cannot force a query to
    // scan all of the expired short ranges between that range and the point.
    private let subtreeMaxEnd: [Int]

    /// The same ID may occur in several disjoint or overlapping ranges. Exact
    /// duplicate records are discarded; all other valid ranges remain usable.
    public init(_ entries: [Entry] = []) {
        var valid: [(entry: Entry, end: Int, order: Int)] = []
        var seen = Set<Entry>()
        for (order, entry) in entries.enumerated() {
            let range = entry.range
            guard range.location != NSNotFound, range.length != NSNotFound,
                  range.location >= 0, range.length > 0 else { continue }
            let (end, overflow) = range.location.addingReportingOverflow(range.length)
            guard !overflow, end > range.location, seen.insert(entry).inserted else { continue }
            valid.append((entry, end, order))
        }
        valid.sort {
            if $0.entry.range.location != $1.entry.range.location { return $0.entry.range.location < $1.entry.range.location }
            return $0.order < $1.order
        }
        orderedEntries = valid.map(\.entry)
        let sortedEnds = valid.map(\.end)
        ends = sortedEnds
        subtreeMaxEnd = Self.makeSubtreeMaxEnds(sortedEnds)
    }

    /// Number of valid, distinct ID/range records, not the number of unique IDs.
    public var count: Int { orderedEntries.count }
    public var isEmpty: Bool { orderedEntries.isEmpty }

    /// End offsets are excluded. Results are ordered by range start, then input
    /// order. Each ID appears once, using its earliest matching entry in that
    /// order; disjoint occurrences of the same ID still work at other offsets.
    /// Balanced max-end subtrees prune expired intervals, while the start
    /// upper bound prunes ranges after the point. A whole-page outer passage
    /// therefore does not require visiting every preceding short sentence.
    public func entries(containing offset: Int) -> [Entry] {
        guard offset >= 0, offset != NSNotFound, !orderedEntries.isEmpty else { return [] }
        var lower = 0, upper = orderedEntries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if orderedEntries[middle].range.location <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        let limit = lower
        var seen = Set<ID>(), matches: [Entry] = []
        func visit(_ lower: Int, _ upper: Int) {
            guard lower < upper, lower < limit else { return }
            let middle = lower + (upper - lower) / 2
            guard subtreeMaxEnd[middle] > offset else { return }
            visit(lower, middle)
            if middle < limit {
                let entry = orderedEntries[middle]
                if ends[middle] > offset, seen.insert(entry.id).inserted { matches.append(entry) }
                visit(middle + 1, upper)
            }
        }
        visit(0, orderedEntries.count)
        return matches
    }

    public func ids(containing offset: Int) -> [ID] {
        entries(containing: offset).map(\.id)
    }

    private static func makeSubtreeMaxEnds(_ ends: [Int]) -> [Int] {
        var maxima = Array(repeating: 0, count: ends.count)
        func build(_ lower: Int, _ upper: Int) -> Int {
            guard lower < upper else { return 0 }
            let middle = lower + (upper - lower) / 2
            let maximum = max(ends[middle], max(build(lower, middle), build(middle + 1, upper)))
            maxima[middle] = maximum
            return maximum
        }
        _ = build(0, ends.count)
        return maxima
    }
}
