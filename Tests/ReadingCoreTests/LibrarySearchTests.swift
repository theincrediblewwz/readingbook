import Foundation
import XCTest
@testable import ReadingCore

final class LibrarySearchTests: XCTestCase {
    private func book(id: String = "book-a", text: String = "😀曹操屯兵。阿瞒归来。", name: String = "曹操") -> BookProject {
        var value = BookProject(id: id, title: "原书 \(id)", originalName: "source.md", sourceHash: "source-\(id)",
                                units: [SourceUnit(id: "unit-1", order: 0, chapter: "第一章", text: text)])
        value.entities = [KnowledgeEntity(id: "same-id-in-independent-books", typeID: "person", name: name, aliases: ["阿瞒"], evidence: [Evidence(unitID: "unit-1", quote: "曹操")])]
        return value
    }

    func testUnicodeMatchUsesOriginalQuoteAndUTF16Range() throws {
        let project = book(text: "😀曹操屯兵。CAFÉ 与 e\u{301} 并列。")
        let snapshot = LibrarySourceSnapshot(project: project)
        let response = try LibraryTextSearch.search(query: "曹操", snapshots: [snapshot])
        let match = try XCTUnwrap(response.matches.first)
        XCTAssertEqual(match.utf16Location, 2, "UTF16范围须计算前方emoji的代理对。")
        XCTAssertEqual(match.utf16Length, 2)
        XCTAssertEqual(match.quote, "曹操")
        XCTAssertEqual(match.bookID, project.id)
        XCTAssertEqual(match.unitID, "unit-1")
        XCTAssertNoThrow(try match.validate(in: project))
        let folded = try LibraryTextSearch.search(query: "café", snapshots: [snapshot])
        XCTAssertEqual(folded.matches.first?.quote, "CAFÉ", "返回原书大小写，不能以查询文本伪造引文。")
        let combined = try LibraryTextSearch.search(query: "e\u{301} 并列", snapshots: [snapshot])
        let composedMatch = try XCTUnwrap(combined.matches.first)
        XCTAssertTrue(composedMatch.quote.utf8.elementsEqual("e\u{301} 并列".utf8))
        XCTAssertNoThrow(try composedMatch.validate(in: project))
    }

    func testRepeatedWordReturnsSeparateExactAnchorsWithAdjacentContext() throws {
        let project = book(text: "春记：曹操在北。\n秋记：曹操在南。")
        let response = try LibraryTextSearch.search(query: "曹操", snapshots: [LibrarySourceSnapshot(project: project)])
        XCTAssertEqual(response.matches.count, 2)
        XCTAssertNotEqual(response.matches[0].id, response.matches[1].id)
        let anchors = try response.matches.map { match in
            try ReadingExperienceRuntime.createAnchor(sourceHash: match.sourceHash, unitID: match.unitID, quote: match.quote,
                                                       prefix: match.prefix, suffix: match.suffix, in: project)
        }
        XCTAssertNotEqual(anchors[0].id, anchors[1].id)
        for (match, anchor) in zip(response.matches, anchors) {
            XCTAssertEqual(try ReadingExperienceRuntime.resolve(anchor, in: project).range, match.range)
        }
    }

    func testBookScopeAndCrossBookAliasCardsNeverMergeIdentity() throws {
        let first = book(id: "one")
        let second = book(id: "two", text: "另书说曹操。", name: "另书中的曹操")
        let snapshots = [first, second].map { LibrarySourceSnapshot(project: $0) }
        let all = try LibraryTextSearch.search(query: "曹操", snapshots: snapshots)
        XCTAssertEqual(all.matches.map(\.bookID), ["one", "two"])
        XCTAssertEqual(all.entityMatches.count, 2)
        XCTAssertNotEqual(all.entityMatches[0].id, all.entityMatches[1].id)
        XCTAssertEqual(all.entityMatches[0].entity.id, all.entityMatches[1].entity.id)
        let scoped = try LibraryTextSearch.search(query: "曹操", snapshots: snapshots, bookID: "two")
        XCTAssertEqual(scoped.matches.map(\.bookID), ["two"])
        XCTAssertEqual(scoped.entityMatches.map(\.bookID), ["two"])
        let alias = try LibraryTextSearch.search(query: "阿瞒", snapshots: snapshots)
        XCTAssertEqual(alias.matches.map(\.bookID), ["one"], "名称索引不能凭别名给另一原书捏造文字命中。")
        XCTAssertEqual(alias.entityMatches.count, 2)
        XCTAssertEqual(alias.entityMatches.map(\.matchedName), ["阿瞒", "阿瞒"])
    }

    func testResultBoundStopsScanAndEmptyQueryDoesNotScan() throws {
        let first = book(text: String(repeating: "曹操出行。", count: 100))
        let second = book(id: "later", text: "曹操到此。")
        let snapshots = [first, second].map { LibrarySourceSnapshot(project: $0) }
        let result = try LibraryTextSearch.search(query: "曹操", snapshots: snapshots, resultLimit: 3, entityLimit: 0)
        XCTAssertEqual(result.matches.count, 3)
        XCTAssertEqual(result.scannedUnitCount, 1)
        XCTAssertTrue(result.bounded)
        XCTAssertTrue(result.entityMatches.isEmpty)
        let empty = try LibraryTextSearch.search(query: "  \n", snapshots: snapshots)
        XCTAssertTrue(empty.matches.isEmpty)
        XCTAssertEqual(empty.scannedUnitCount, 0)
        XCTAssertFalse(empty.bounded)
    }

    func testStaleOCRTextAndDifferentBookCannotReuseSearchOffset() throws {
        let original = book()
        let match = try XCTUnwrap(LibraryTextSearch.search(query: "曹操", snapshots: [LibrarySourceSnapshot(project: original)]).matches.first)
        var changed = original
        changed.units[0].text += "末尾OCR修订。"
        XCTAssertEqual(changed.sourceHash, original.sourceHash)
        XCTAssertThrowsError(try match.validate(in: changed), "PDF原文件哈希不变也须识别OCR文本版本变化。")
        changed = original; changed.id = "different-book"
        XCTAssertThrowsError(try match.validate(in: changed))
        changed = original; changed.sourceHash = "different-source"
        XCTAssertThrowsError(try match.validate(in: changed))
    }

    func testQueryAndBudgetsAreBounded() throws {
        let snapshots = [LibrarySourceSnapshot(project: book())]
        XCTAssertThrowsError(try LibraryTextSearch.search(query: String(repeating: "字", count: 401), snapshots: snapshots))
        XCTAssertThrowsError(try LibraryTextSearch.search(query: "曹操", snapshots: snapshots, resultLimit: 0))
        XCTAssertThrowsError(try LibraryTextSearch.search(query: "曹操", snapshots: snapshots, entityLimit: 101))
    }

    func testCancelledBackgroundSearchStopsBeforeScanning() async throws {
        let snapshots = [LibrarySourceSnapshot(project: book())]
        let task = Task.detached { () throws -> LibrarySearchResponse in
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibraryTextSearch.search(query: "曹操", snapshots: snapshots)
        }
        do { _ = try await task.value; XCTFail("已取消的查询不应产生结果。") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
