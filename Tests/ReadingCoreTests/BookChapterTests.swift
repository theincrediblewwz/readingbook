import Foundation
import XCTest
@testable import ReadingCore
#if os(macOS)
import PDFKit
import CoreGraphics
import CoreText
#endif

final class BookChapterTests: XCTestCase {
    private func project(_ texts: [String]) throws -> BookProject {
        BookProject(title: "章界", originalName: "book.pdf", sourceHash: try BookImporter.sha256(Data("original".utf8)),
            units: texts.enumerated().map { SourceUnit(id: "u\($0.offset)", order: $0.offset, chapter: "章界", page: $0.offset + 1, text: $0.element) })
    }
    private func entry(_ title: String, unit: SourceUnit, level: Int = 0, id: String? = nil, in project: BookProject) throws -> BookOutlineEntry {
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: unit.id, quote: title, in: project)
        return BookOutlineEntry(id: id ?? anchor.id, title: title, level: level, page: unit.page, anchor: anchor)
    }
    private func native(_ entries: [BookOutlineEntry], in project: BookProject) throws -> BookChapterOutline {
        BookChapterOutline(sourceHash: project.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: project),
            scannedUnitCount: project.units.count, totalUnitCount: project.units.count, entries: entries)
    }

    func testSamePageChaptersUseExactBoundariesAndNeverMergeRepeatedNames() throws {
        var book = try project(["前言\n第一章\n甲章正文。\n第二章\n乙章正文。", "第一章\n丙章正文。"])
        let first = try entry("第一章", unit: book.units[0], in: book), second = try entry("第二章", unit: book.units[0], in: book)
        let repeated = try entry("第一章", unit: book.units[1], in: book)
        book.originalBookOutline = try native([first, second, repeated], in: book)
        let before = try JSONEncoder().encode(book.units)
        let index = try XCTUnwrap(BookChapterRuntime.index(in: book))
        XCTAssertEqual(index.chapters.count, 3); XCTAssertEqual(index.segments.count, 4)
        XCTAssertEqual(index.chapters[0].ranges.map { try! $0.text(in: book) }.joined(), "第一章\n甲章正文。\n")
        XCTAssertEqual(index.chapters[1].ranges.map { try! $0.text(in: book) }.joined(), "第二章\n乙章正文。")
        XCTAssertNotEqual(index.chapters[0].id, index.chapters[2].id)
        XCTAssertThrowsError(try index.chapter(unitID: "u0"))
        XCTAssertEqual(try index.chapter(unitID: "u0", offsetUTF16: second.anchor!.utf16Location).id, second.id)
        XCTAssertEqual(try JSONEncoder().encode(book.units), before)
    }

    func testParentAndChildMayShareStartButParentEndsAtNextSibling() throws {
        var book = try project(["第一卷\n正文甲。", "第二节\n正文乙。", "第二卷\n正文丙。"])
        var parent = try entry("第一卷", unit: book.units[0], id: "parent", in: book)
        var child = parent; child.id = "child"; child.title = "第一节"; child.level = 1
        let nextChild = try entry("第二节", unit: book.units[1], level: 1, id: "child2", in: book)
        let next = try entry("第二卷", unit: book.units[2], id: "next", in: book)
        parent.level = 0
        book.originalBookOutline = try native([parent, child, nextChild, next], in: book)
        let index = try XCTUnwrap(BookChapterRuntime.index(in: book))
        XCTAssertEqual(index.chapters[0].ranges.map(\.unitID), ["u0", "u1"])
        XCTAssertEqual(index.chapters[1].ranges.map(\.unitID), ["u0"])
        XCTAssertEqual(index.segments.map(\.id), ["child", "child2", "next"])
        try BookChapterRuntime.validate(index: index, in: book)
        XCTAssertEqual(try index.chapter(unitID: "u1").id, "child2")
        var sibling = child; sibling.level = 0
        book.originalBookOutline = try native([parent, sibling, next], in: book)
        XCTAssertThrowsError(try BookChapterRuntime.index(in: book))
    }

    func testPartialGeneratedDirectoryDoesNotClaimLastChapterToBookEnd() throws {
        var book = try project(["第一章\n甲。", "第二章\n乙。", "第三章\n丙。"])
        let first = try entry("第一章", unit: book.units[0], in: book), second = try entry("第二章", unit: book.units[1], in: book)
        book.generatedOutline = GeneratedBookOutline(sourceHash: book.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: book),
            scannedUnitCount: 2, totalUnitCount: 3, entries: [first, second])
        let index = try XCTUnwrap(BookChapterRuntime.index(in: book))
        XCTAssertTrue(index.chapters[0].isComplete); XCTAssertFalse(index.chapters[1].isComplete)
        XCTAssertEqual(index.chapters[1].ranges.map(\.unitID), ["u1"])
        XCTAssertThrowsError(try index.chapter(unitID: "u1")); XCTAssertThrowsError(try index.chapter(unitID: "u2"))
        XCTAssertEqual(try index.chapter(unitID: "u0").id, first.id)
        try BookChapterRuntime.validate(index: index, in: book)
    }

    func testFrozenHierarchyValidationDoesNotFollowNewDirectoryOrAllowExpandedSegments() throws {
        var book = try project(["第一章\n甲。", "第二章\n乙。"])
        let first = try entry("第一章", unit: book.units[0], in: book), second = try entry("第二章", unit: book.units[1], in: book)
        book.originalBookOutline = try native([first, second], in: book)
        let frozen = try XCTUnwrap(BookChapterRuntime.index(in: book))
        book.originalBookOutline = try native([first], in: book)
        try BookChapterRuntime.validate(index: frozen, in: book)
        var forged = frozen
        forged.segments[0].ranges.append(contentsOf: forged.segments[1].ranges)
        XCTAssertThrowsError(try BookChapterRuntime.validate(index: forged, in: book))
        forged = frozen; forged.chapters[0].ranges.append(contentsOf: forged.chapters[1].ranges)
        XCTAssertThrowsError(try BookChapterRuntime.validate(index: forged, in: book))
    }

    func testUnresolvedNativeEntryCannotAuthorizeChapterAndStaleBytesInvalidateCache() throws {
        var book = try project(["第一章\né。", "第二章\n乙。"])
        let first = try entry("第一章", unit: book.units[0], in: book)
        let unresolved = BookOutlineEntry(id: "missing", title: "第二章", page: 2)
        book.originalBookOutline = try native([first, unresolved], in: book)
        try BookChapterRuntime.validateStored(book.originalBookOutline)
        XCTAssertThrowsError(try BookChapterRuntime.index(in: book))
        let second = try entry("第二章", unit: book.units[1], in: book)
        book.originalBookOutline = try native([BookOutlineEntry(id: "external", title: "外部资料")], in: book)
        book.generatedOutline = GeneratedBookOutline(sourceHash: book.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: book),
            scannedUnitCount: 2, totalUnitCount: 2, entries: [first, second])
        XCTAssertEqual(try BookChapterRuntime.index(in: book)?.chapters.count, 2, "只有外部链接的原目录不能压住有效生成章界。")
        book.generatedOutline = nil
        book.originalBookOutline = try native([first], in: book)
        book.units[0].text = "第一章\ne\u{301}。"
        XCTAssertNil(try BookChapterRuntime.index(in: book))
        let decoded = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded.originalBookOutline, book.originalBookOutline)
        book.originalBookOutline = nil
        XCTAssertNil(try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(book)).originalBookOutline)
    }

    func testLegacyLabelsRemainContiguousAndPlaceholderPDFDoesNotGrantWholeBook() throws {
        var book = try project(["甲。", "乙。", "丙。"])
        XCTAssertTrue(try BookChapterRuntime.legacyChapters(in: book).isEmpty)
        book.units[0].chapter = "第一章"; book.units[1].chapter = "第二章"; book.units[2].chapter = "第一章"
        let chapters = try BookChapterRuntime.legacyChapters(in: book)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(try BookChapterRuntime.legacyChapter(in: book, unitID: "u2")?.ranges.map(\.unitID), ["u2"])
        XCTAssertNotEqual(chapters[0].id, chapters[2].id)
        for index in book.units.indices { book.units[index].chapter = "第 \(index + 1) 页" }
        XCTAssertTrue(try BookChapterRuntime.legacyChapters(in: book).isEmpty)
        book.originalName = "book.md"
        XCTAssertEqual(try BookChapterRuntime.legacyChapters(in: book).count, 3)
    }

    func testSourceRangesRejectSurrogateAndCombiningCharacterSplits() throws {
        let book = try project(["甲😀e\u{301}乙"]), unit = book.units[0]
        XCTAssertEqual(try ReadingSourceRange(unitID: unit.id, startUTF16: 1, endUTF16: 3).text(in: unit), "😀")
        XCTAssertThrowsError(try ReadingSourceRange(unitID: unit.id, startUTF16: 1, endUTF16: 2).text(in: unit))
        XCTAssertThrowsError(try ReadingSourceRange(unitID: unit.id, startUTF16: 3, endUTF16: 4).text(in: unit))
        XCTAssertThrowsError(try ReadingSourceRange(unitID: unit.id, startUTF16: 4, endUTF16: 5).text(in: unit))
        XCTAssertThrowsError(try ReadingSourceRange(unitID: unit.id, startUTF16: 0, endUTF16: Int.max).text(in: unit))
    }

    #if os(macOS)
    func testOriginalPDFSamePageTargetsBecomeExactCanonicalChapterStarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-ChapterPDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chapters.pdf"), output = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for (text, y) in [("Chapter One", 700.0), ("First body.", 660.0), ("Chapter Two", 400.0), ("Second body.", 360.0)] {
            let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(value), context)
        }
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: output as Data)), page = try XCTUnwrap(document.page(at: 0)), root = PDFOutline()
        for (index, title, y) in [(0, "Chapter One", 720.0), (1, "Chapter Two", 420.0)] {
            let node = PDFOutline(); node.label = title; node.destination = PDFDestination(page: page, at: CGPoint(x: 40, y: y)); root.insertChild(node, at: index)
        }
        document.outlineRoot = root; try XCTUnwrap(document.dataRepresentation()).write(to: url)
        let source = try Data(contentsOf: url)
        var book = try await BookImporter.importFile(at: url)
        let outline = try XCTUnwrap(BookChapterRuntime.originalPDFOutline(at: url, project: book, password: nil))
        XCTAssertEqual(outline.entries.count, 2); XCTAssertTrue(outline.entries.allSatisfy { $0.anchor != nil })
        XCTAssertEqual(outline.entries.map(\.destinationY), [720, 420])
        book.originalBookOutline = outline
        let index = try XCTUnwrap(BookChapterRuntime.index(in: book)), first = index.chapters[0]
        let text = try first.ranges.map { try $0.text(in: book) }.joined()
        XCTAssertTrue(text.contains("Chapter One")); XCTAssertTrue(text.contains("First body.")); XCTAssertFalse(text.contains("Chapter Two"))
        XCTAssertThrowsError(try index.chapter(unitID: book.units[0].id))
        XCTAssertEqual(try Data(contentsOf: url), source)
        book.units[0].text += " OCR changed text"
        let changed = try XCTUnwrap(BookChapterRuntime.originalPDFOutline(at: url, project: book, password: nil))
        XCTAssertTrue(changed.entries.allSatisfy { $0.anchor == nil })
    }
    #endif
}
