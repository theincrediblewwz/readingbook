import Foundation
import XCTest
@testable import ReadingCore

final class RequestPreviewTests: XCTestCase {
    private func legacy(_ markdown: String, query: String) -> String {
        let compact = markdown.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let match = compact.range(of: query, options: .caseInsensitive) else { return String(compact.prefix(120)) }
        let start = compact.index(match.lowerBound, offsetBy: -30, limitedBy: compact.startIndex) ?? compact.startIndex
        return (start == compact.startIndex ? "" : "…") + String(compact[start...].prefix(120))
    }
    private func book() -> BookProject {
        var p = BookProject(id: "00000000-0000-4000-8000-000000000042", title: "边界", originalName: "book.txt", sourceHash: "source", units: [
            .init(id: "u1", order: 0, chapter: "一", page: 1, text: "第一句 e\u{301} 👩🏽‍💻。"),
            .init(id: "u2", order: 1, chapter: "二", page: 2, text: "不曾分享的第二页。")])
        p.documents = [.init(id: "n1", title: "选择的笔记"), .init(id: "n2", title: "未选择的笔记")]
        var trash = DocumentRecord(id: "trash", title: "已回收"); trash.trashedAt = Date(timeIntervalSince1970: 1700000000)
        p.documents.append(trash); p.nodes = [.init(id: "node1", targetID: "u1"), .init(id: "node2", targetID: "u2")]
        return p
    }
    func testLongPreviewRetainsExactUnicodeTrimAndLineEndingBytes() {
        let tail = String(repeating: "正文 e\u{301} 👩🏽‍💻。\r\n", count: 600)
        let values = ["", String(repeating: "\t\r\n\u{2003}", count: 1500), tail,
            String(repeating: "\u{2003}\r\n", count: 2000) + tail,
            "x" + String(repeating: " ", count: 5000),
            String(repeating: "a", count: 119) + "\n\u{301}z" + tail,
            String(repeating: "\n\u{301}", count: 3000),
            "a" + String(repeating: "\u{301}", count: 5000) + tail,
            String(repeating: "王允", count: 20) + String(repeating: " ", count: 5000) + "吕布"]
        for text in values {
            let before = Data(text.utf8), actual = ReadingKnowledgeExcerpt.make(text, query: "")
            XCTAssertTrue(actual.utf8.elementsEqual(legacy(text, query: "").utf8))
            XCTAssertEqual(Data(text.utf8), before); XCTAssertLessThanOrEqual(actual.count, 120)
        }
    }
    func testShortThresholdAndNonemptySearchKeepCompleteLegacyResults() {
        for size in [0, 100, 4095, 4096, 4097, 50000] {
            let text = String(repeating: "a", count: size) + "\r\nLvBu 吕布 e\u{301} 👩🏽‍💻" + String(repeating: "z", count: 200)
            for query in ["", "lvbu", "吕布", "e\u{301}", "é", "not here"] {
                XCTAssertTrue(ReadingKnowledgeExcerpt.make(text, query: query).utf8.elementsEqual(legacy(text, query: query).utf8))
            }
        }
    }
    func testEmptyExplicitAttachmentsDoNotShareUnselectedNotesOrNodes() throws {
        let p = book(), ctx = ReadingContext(unitID: "u1", selectedText: "第一句", page: 1)
        for scope in [ReadingQueryScope.page, .selection, .book, .notes] {
            for mode in [ReadingConversationMode.reading, .functional] {
                let prepared = try ReadingPreparedAnswer.freeze(project: p, scope: scope, context: ctx,
                    documentIDs: scope == .notes ? ["n1"] : nil, preferences: .init(interaction: mode))
                XCTAssertEqual(prepared.snapshot.documentIDs, scope == .notes ? ["n1"] : [])
                XCTAssertEqual(prepared.snapshot.authorizedNodeIDs, [])
                XCTAssertEqual(prepared.snapshot.unitIDs, scope == .notes ? [] : scope == .book ? ["u1", "u2"] : ["u1"])
            }
        }
    }
    func testNonemptyAttachmentsStillRejectMissingDuplicateTrashAndOversizeIDs() throws {
        let p = book(), ctx = ReadingContext(unitID: "u1", page: 1)
        for ids in [["missing"], ["n1", "n1"], ["trash"], Array(repeating: "n1", count: 1025)] {
            XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ctx, appendedDocumentIDs: ids))
        }
        for ids in [["missing"], ["node1", "node1"], Array(repeating: "node1", count: 1025)] {
            XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ctx, authorizedNodeIDs: ids))
        }
        let valid = try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ctx, appendedDocumentIDs: ["n1"], authorizedNodeIDs: ["node1"])
        XCTAssertEqual(valid.documentIDs, ["n1"]); XCTAssertEqual(valid.authorizedNodeIDs, ["node1"])
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ReadingContext(sourceHash: "foreign", unitID: "u1", page: 1)))
    }
    func testEachFreezeSeesCurrentNoteMembershipAndSourceRatherThanEarlierInput() throws {
        var p = book(); let ctx = ReadingContext(unitID: "u1", page: 1)
        let first = try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ctx, appendedDocumentIDs: ["n1"])
        p.documents[0].updatedAt = p.documents[0].updatedAt.addingTimeInterval(1)
        p.documents[0].relativePath = "docs/revised.md"
        let second = try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ctx, appendedDocumentIDs: ["n1"])
        XCTAssertNotEqual(first.scopeFingerprint, second.scopeFingerprint)
        p.documents[0].trashedAt = Date()
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ctx, appendedDocumentIDs: ["n1"]))
        let empty = try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ctx)
        XCTAssertEqual(empty.documentIDs, []); XCTAssertEqual(empty.authorizedNodeIDs, [])
        p.sourceHash = "new-source"
        XCTAssertNotEqual(try ReadingQuerySnapshot.freeze(scope: .page, in: p, context: ctx).scopeFingerprint, empty.scopeFingerprint)
    }
}
