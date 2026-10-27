import Foundation
import XCTest
@testable import ReadingCore

final class ReadingRangeIndexTests: XCTestCase {
    func testAdjacentRangesUseExclusiveEndOffsets() {
        let index = ReadingRangeIndex<String>([
            .init(id: "second", range: NSRange(location: 5, length: 3)),
            .init(id: "first", range: NSRange(location: 0, length: 5))
        ])
        XCTAssertEqual(index.ids(containing: 0), ["first"])
        XCTAssertEqual(index.ids(containing: 4), ["first"])
        XCTAssertEqual(index.ids(containing: 5), ["second"])
        XCTAssertEqual(index.ids(containing: 7), ["second"])
        XCTAssertTrue(index.ids(containing: 8).isEmpty)
        XCTAssertTrue(index.ids(containing: -1).isEmpty)
        XCTAssertTrue(index.ids(containing: NSNotFound).isEmpty)
    }

    func testNestedAndCrossingRangesDoNotLoseEarlierLongMatches() {
        let index = ReadingRangeIndex<String>([
            .init(id: "same-start-first", range: NSRange(location: 20, length: 2)),
            .init(id: "outer", range: NSRange(location: 0, length: 100)),
            .init(id: "crossing", range: NSRange(location: 15, length: 70)),
            .init(id: "same-start-second", range: NSRange(location: 20, length: 10)),
            .init(id: "middle", range: NSRange(location: 10, length: 30)),
            .init(id: "later", range: NSRange(location: 200, length: 5))
        ])
        XCTAssertEqual(index.ids(containing: 21), ["outer", "middle", "crossing", "same-start-first", "same-start-second"])
        XCTAssertEqual(index.ids(containing: 40), ["outer", "crossing"])
        XCTAssertEqual(index.ids(containing: 85), ["outer"])
        XCTAssertTrue(index.ids(containing: 100).isEmpty)
        XCTAssertEqual(index.ids(containing: 200), ["later"])
    }

    func testInvalidAndOverflowingRangesAreIgnoredWithoutClamping() {
        let index = ReadingRangeIndex<String>([
            .init(id: "not-found", range: NSRange(location: NSNotFound, length: 2)),
            .init(id: "not-found-length", range: NSRange(location: 0, length: NSNotFound)),
            .init(id: "negative-location", range: NSRange(location: -1, length: 2)),
            .init(id: "negative-length", range: NSRange(location: 1, length: -2)),
            .init(id: "empty", range: NSRange(location: 3, length: 0)),
            .init(id: "overflow", range: NSRange(location: Int.max - 2, length: 4)),
            .init(id: "last-valid", range: NSRange(location: Int.max - 2, length: 2))
        ])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.ids(containing: Int.max - 1), ["last-valid"])
        XCTAssertTrue(index.ids(containing: Int.max).isEmpty)
        XCTAssertTrue(index.ids(containing: 0).isEmpty)
        XCTAssertTrue(ReadingRangeIndex<String>().isEmpty)
    }

    func testRepeatedIDKeepsDisjointOccurrencesAndStableSingleResults() {
        let index = ReadingRangeIndex<String>([
            .init(id: "same", range: NSRange(location: 30, length: 10)),
            .init(id: "same", range: NSRange(location: 0, length: 10)),
            .init(id: "other", range: NSRange(location: 5, length: 8)),
            .init(id: "same", range: NSRange(location: 5, length: 10)),
            .init(id: "same", range: NSRange(location: 0, length: 10))
        ])
        XCTAssertEqual(index.count, 4, "Only the completely identical record is discarded.")
        XCTAssertEqual(index.ids(containing: 7), ["same", "other"])
        XCTAssertEqual(index.entries(containing: 7).first?.range, NSRange(location: 0, length: 10))
        XCTAssertEqual(index.ids(containing: 12), ["other", "same"])
        XCTAssertEqual(index.ids(containing: 35), ["same"], "A duplicate ID must not erase a later disjoint source occurrence.")
    }

    func testPageSizedValueIndexCanBeQueriedFromAnotherTask() async {
        let index = ReadingRangeIndex<Int>((0..<2000).map { value in
            .init(id: value, range: NSRange(location: value * 12, length: 10))
        })
        let result = await Task.detached { index.ids(containing: 1000 * 12 + 9) }.value
        XCTAssertEqual(result, [1000])
        XCTAssertTrue(index.ids(containing: 1000 * 12 + 10).isEmpty)
    }

    func testWholePageOuterPassageDoesNotHideThousandsOfShortSentenceRanges() {
        let count = 6000
        var entries: [ReadingRangeIndex<String>.Entry] = [
            .init(id: "page", range: NSRange(location: 0, length: count * 12 + 100))
        ]
        entries += (0..<count).map {
            .init(id: "sentence-\($0)", range: NSRange(location: $0 * 12, length: 10))
        }
        let index = ReadingRangeIndex(entries)
        for sentence in [0, 1, count / 2, count - 2, count - 1] {
            XCTAssertEqual(index.ids(containing: sentence * 12 + 9), ["page", "sentence-\(sentence)"])
            XCTAssertEqual(index.ids(containing: sentence * 12 + 10), ["page"])
        }
        XCTAssertEqual(index.ids(containing: count * 12 + 50), ["page"])
        XCTAssertTrue(index.ids(containing: count * 12 + 100).isEmpty)
    }

    func testIntersectionQueriesExcludeAdjacentEndpoints() {
        let index = ReadingRangeIndex<String>([
            .init(id: "second", range: NSRange(location: 5, length: 3)),
            .init(id: "first", range: NSRange(location: 0, length: 5))
        ])
        XCTAssertEqual(index.entries(intersecting: NSRange(location: 2, length: 3)).map(\.id), ["first"])
        XCTAssertEqual(index.entries(intersecting: NSRange(location: 5, length: 1)).map(\.id), ["second"])
        XCTAssertEqual(index.entries(intersecting: NSRange(location: 4, length: 2)).map(\.id), ["first", "second"])
        XCTAssertTrue(index.entries(intersecting: NSRange(location: 8, length: 1)).isEmpty)

        var visited: [ReadingRangeIndex<String>.Entry] = []
        index.forEachEntry(intersecting: NSRange(location: 4, length: 2)) { visited.append($0) }
        XCTAssertEqual(visited, index.entries(intersecting: NSRange(location: 4, length: 2)))
    }

    func testIntersectionQueriesPreserveNestedCrossingAndSameStartOrder() {
        let index = ReadingRangeIndex<String>([
            .init(id: "same-start-first", range: NSRange(location: 20, length: 2)),
            .init(id: "outer", range: NSRange(location: 0, length: 100)),
            .init(id: "crossing", range: NSRange(location: 15, length: 70)),
            .init(id: "same-start-second", range: NSRange(location: 20, length: 10)),
            .init(id: "middle", range: NSRange(location: 10, length: 30)),
            .init(id: "later", range: NSRange(location: 200, length: 5))
        ])
        XCTAssertEqual(index.entries(intersecting: NSRange(location: 21, length: 1)).map(\.id),
                       ["outer", "middle", "crossing", "same-start-first", "same-start-second"])
        XCTAssertEqual(index.entries(intersecting: NSRange(location: 22, length: 18)).map(\.id),
                       ["outer", "middle", "crossing", "same-start-second"])
        XCTAssertEqual(index.entries(intersecting: NSRange(location: 85, length: 115)).map(\.id), ["outer"])
        XCTAssertEqual(index.entries(intersecting: NSRange(location: 0, length: 205)).map(\.id),
                       ["outer", "middle", "crossing", "same-start-first", "same-start-second", "later"])
    }

    func testIntersectionQueriesDeduplicateIDsUsingEarliestMatchingRange() {
        let index = ReadingRangeIndex<String>([
            .init(id: "same", range: NSRange(location: 30, length: 10)),
            .init(id: "same", range: NSRange(location: 0, length: 10)),
            .init(id: "other", range: NSRange(location: 5, length: 8)),
            .init(id: "same", range: NSRange(location: 5, length: 10)),
            .init(id: "same", range: NSRange(location: 0, length: 10))
        ])
        let acrossOccurrences = index.entries(intersecting: NSRange(location: 7, length: 30))
        XCTAssertEqual(acrossOccurrences.map(\.id), ["same", "other"])
        XCTAssertEqual(acrossOccurrences.first?.range, NSRange(location: 0, length: 10))
        let afterFirst = index.entries(intersecting: NSRange(location: 10, length: 25))
        XCTAssertEqual(afterFirst.map(\.id), ["other", "same"])
        XCTAssertEqual(afterFirst.last?.range, NSRange(location: 5, length: 10))
        XCTAssertEqual(index.entries(intersecting: NSRange(location: 35, length: 1)).map(\.id), ["same"])
        XCTAssertTrue(index.entries(intersecting: NSRange(location: 15, length: 15)).isEmpty)
    }

    func testInvalidIntersectionQueriesAreRejectedWithoutClamping() {
        let index = ReadingRangeIndex<String>([
            .init(id: "first", range: NSRange(location: 0, length: 10)),
            .init(id: "last", range: NSRange(location: Int.max - 2, length: 2))
        ])
        let invalidQueries = [
            NSRange(location: NSNotFound, length: 1),
            NSRange(location: 0, length: NSNotFound),
            NSRange(location: -1, length: 2),
            NSRange(location: 1, length: -2),
            NSRange(location: 3, length: 0),
            NSRange(location: Int.max - 2, length: 4)
        ]
        for query in invalidQueries {
            XCTAssertTrue(index.entries(intersecting: query).isEmpty)
            index.forEachEntry(intersecting: query) { _ in XCTFail("Invalid query must not visit any entry: \(query)") }
        }
        XCTAssertEqual(index.entries(intersecting: NSRange(location: Int.max - 2, length: 2)).map(\.id), ["last"])
        ReadingRangeIndex<String>().forEachEntry(intersecting: NSRange(location: 0, length: 1)) { _ in
            XCTFail("An empty index must not visit any entry.")
        }
    }

    func testLateIntersectionQueryKeepsWholePageAndNearbyShortRanges() {
        let count = 6000
        var entries: [ReadingRangeIndex<String>.Entry] = [
            .init(id: "page", range: NSRange(location: 0, length: count * 12 + 100))
        ]
        entries += (0..<count).map {
            .init(id: "sentence-\($0)", range: NSRange(location: $0 * 12, length: 10))
        }
        let index = ReadingRangeIndex(entries)
        for sentence in [count / 2, count - 2, count - 1] {
            var visited: [String] = []
            index.forEachEntry(intersecting: NSRange(location: sentence * 12 + 9, length: 3)) { visited.append($0.id) }
            XCTAssertEqual(visited, ["page", "sentence-\(sentence)"])
            XCTAssertEqual(index.entries(intersecting: NSRange(location: sentence * 12 + 10, length: 2)).map(\.id), ["page"])
        }
        XCTAssertEqual(index.entries(intersecting: NSRange(location: count * 12 + 50, length: 50)).map(\.id), ["page"])
        XCTAssertTrue(index.entries(intersecting: NSRange(location: count * 12 + 100, length: 1)).isEmpty)
    }
}
