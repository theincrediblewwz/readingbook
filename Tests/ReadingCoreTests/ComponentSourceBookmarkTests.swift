import Foundation
import XCTest
@testable import ReadingCore

final class ComponentSourceBookmarkTests: XCTestCase {
    private func book() -> BookProject {
        var value = BookProject(id: "book", title: "范围", originalName: "book.pdf", sourceHash: "source", units: [
            .init(id: "a", order: 0, chapter: "甲章", page: 1, text: "刘备在甲地。"),
            .init(id: "b", order: 1, chapter: "甲章", page: 2, text: "曹操在乙地。"),
            .init(id: "c", order: 2, chapter: "乙章", page: 3, text: "后文秘密。")])
        value.documents = [.init(id: "note", title: "原笔记")]
        return value
    }
    func testEverySourceScopeRoundTripsWithoutStoringBookTextOrAnalysis() throws {
        let value = book()
        var context = ReadingContext(sourceHash: value.sourceHash, unitID: "a", selectedText: "刘备", page: 1)
        context.queryRange = .init(pageStart: 1, pageEnd: 2)
        for scope in ReadingQueryScope.allCases {
            let source = try ReadingQuerySnapshot.freeze(scope: scope, in: value, context: context,
                documentIDs: scope == .notes ? ["note"] : nil)
            let bookmark = try ReadingComponentSourceBookmark(snapshot: source, context: context)
            let data = try JSONEncoder().encode(bookmark)
            let loaded = try JSONDecoder().decode(ReadingComponentSourceBookmark.self, from: data)
            let restored = try loaded.restore(in: value)
            XCTAssertEqual(source.unitIDs, restored.unitIDs); XCTAssertEqual(source.documentIDs, restored.documentIDs)
            XCTAssertEqual(try source.sourceRanges(in: value), try restored.sourceRanges(in: value))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("曹操在乙地"))
            XCTAssertLessThan(data.count, 2048); XCTAssertEqual(loaded, bookmark)
        }
    }
    func testWholeBookIgnoresIncidentalCursorAndReadSoFarRetainsItsEnd() throws {
        var value = book()
        let whole = try ReadingComponentSourceBookmark(snapshot: .freeze(scope: .book, in: value), context: .init(unitID: "missing", selectedText: "不相关的光标文本"))
        XCTAssertNil(whole.context); XCTAssertEqual(try whole.restore(in: value).unitIDs.count, 3)
        let soFar = try ReadingQuerySnapshot.freeze(scope: .readSoFar, in: value, context: .init(unitID: "b"))
        let bookmark = try ReadingComponentSourceBookmark(snapshot: soFar, context: nil)
        XCTAssertEqual(try bookmark.restore(in: value).unitIDs, ["a", "b"])
        value.units.append(.init(id: "d", order: 3, chapter: "丙章", page: 4, text: "新加入后文。"))
        XCTAssertEqual(try bookmark.restore(in: value).unitIDs, ["a", "b"])
    }
    func testStaleTextIdentityAndRangeNeverBecomeWholeBook() throws {
        let value = book(), context = ReadingContext(unitID: "a", page: 1)
        let bookmark = try ReadingComponentSourceBookmark(snapshot: .freeze(scope: .page, in: value, context: context), context: context)
        var changed = value; changed.units[0].text += "被替换。"
        XCTAssertThrowsError(try bookmark.restore(in: changed))
        changed = value; changed.sourceHash = "new-source"; XCTAssertThrowsError(try bookmark.restore(in: changed))
        changed = value; changed.id = "other"; XCTAssertThrowsError(try bookmark.restore(in: changed))
        changed = value; changed.units.removeFirst(); XCTAssertThrowsError(try bookmark.restore(in: changed))
        XCTAssertEqual(try bookmark.restore(in: value).unitIDs, ["a"])
    }
    func testSelectedOccurrenceRestoresExactOffsets() throws {
        var value = book(); value.units[0].text = "甲章：共用词。乙章：共用词。"
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "a", quote: "共用词", prefix: "乙章：", in: value)
        let context = ReadingContext(unitID: "a", selectedText: "共用词", page: 1, selectedSourceAnchor: anchor)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: value, context: context)
        let bookmark = try ReadingComponentSourceBookmark(snapshot: snapshot, context: context)
        let restored = try bookmark.restore(in: value)
        XCTAssertEqual(try restored.sourceRanges(in: value), try snapshot.sourceRanges(in: value))
        XCTAssertGreaterThan(try XCTUnwrap(restored.sourceRanges(in: value).first).startUTF16, 8)
    }
    func testNewAnalysisAndEditedNotesRemainSharedWithoutExpandingNoteSelection() throws {
        var value = book()
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .notes, in: value, documentIDs: ["note"])
        let bookmark = try ReadingComponentSourceBookmark(snapshot: snapshot, context: nil)
        value.documents[0].updatedAt = Date(timeIntervalSince1970: 1000)
        value.documents[0].title = "已修改笔记"; value.documents.append(.init(id: "other", title: "新笔记"))
        value.entities.append(.init(id: "person", typeID: "person", name: "刘备"))
        let restored = try bookmark.restore(in: value)
        XCTAssertEqual(restored.documentIDs, ["note"])
        XCTAssertEqual(restored.documents.first?.title, "已修改笔记")
        value.documents.removeFirst(); XCTAssertThrowsError(try bookmark.restore(in: value))
    }
    func testWorkspaceKeepsPerRouteChoicesWithLegacyCompatibilityAndBoundedCost() throws {
        let value = book()
        let first = try ReadingComponentSourceBookmark(snapshot: .freeze(scope: .book, in: value), context: nil, updatedAt: Date(timeIntervalSince1970: 1))
        let second = try ReadingComponentSourceBookmark(snapshot: .freeze(scope: .page, in: value, context: .init(unitID: "a")), context: .init(unitID: "a"), updatedAt: Date(timeIntervalSince1970: 2))
        var memory = BookWorkspaceMemory(bookID: value.id, sourceHash: value.sourceHash)
        memory.componentSources = ["map": first, "graph": second]
        let data = try JSONEncoder().encode(memory)
        let loaded = try JSONDecoder().decode(BookWorkspaceMemory.self, from: data).sanitized(bookID: value.id, sourceHash: value.sourceHash)
        XCTAssertEqual(loaded.componentSources?["map"]?.scope, .book); XCTAssertEqual(loaded.componentSources?["graph"]?.scope, .page)
        XCTAssertNil(loaded.sanitized(bookID: "other", sourceHash: value.sourceHash).componentSources)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); raw["componentSources"] = nil
        let legacy = try JSONDecoder().decode(BookWorkspaceMemory.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(legacy.componentSources); XCTAssertEqual(legacy.route, "reader")
        memory.componentSources = Dictionary(uniqueKeysWithValues: (0..<40).map { ("view-\($0)", first) })
        let bounded = memory.sanitized(bookID: value.id, sourceHash: value.sourceHash)
        XCTAssertEqual(bounded.componentSources?.count, 32)
        XCTAssertLessThan(try JSONEncoder().encode(bounded).count, 131_072)
    }
}
