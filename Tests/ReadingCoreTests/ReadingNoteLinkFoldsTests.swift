import Foundation
import XCTest
@testable import ReadingCore

final class ReadingNoteLinkFoldsTests: XCTestCase {
    private let destination = "readingbook://book/book-a/unit/unit-000008?quote=%E5%BB%BA%E5%AF%A7%F0%9F%98%80&prefix=%E5%89%8D%E6%96%87&suffix=%E5%BE%8C%E6%96%87&location=8&length=22"
    private var link: String { "[回到原文](\(destination))" }

    #if os(macOS)
    func testOnlyDestinationGlyphRangeFoldsAndOriginalUTF8RemainsExact() {
        let source = "# 我的笔记\n\n译文😀。\n\n\(link)\n"
        let bytes = Data(source.utf8), original = source as NSString
        let links = ReadingNoteLinkFolds.links(in: source)
        XCTAssertEqual(links.count, 1)
        guard let target = links.first else { return }
        XCTAssertEqual(original.substring(with: target.range), link)
        XCTAssertEqual(original.substring(with: target.destinationRange), destination)
        XCTAssertEqual(target.destinationRange.location, original.range(of: destination).location,
            "源范围必须是 UTF-16，不能拿渲染后字符串或 UTF-8 下标去地址定位。")
        XCTAssertEqual(ReadingNoteLinkFolds.foldedLinks(links, selection: .init(location: 0, length: 0), expanded: false, composing: false), links)
        XCTAssertEqual(Data(source.utf8), bytes, "视图收纳不能重写百分号编码、query 参数或换行。")
    }

    func testUnicodeAndCRLFMapRepeatedLinksToTheirOwnPhysicalLines() {
        let source = "😀开头\r\n\r\n\(link)\r\n\r\n三个汉字\r\n\r\n  \(link)  \r\n"
        let links = ReadingNoteLinkFolds.links(in: source), original = source as NSString
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.map { original.substring(with: $0.destinationRange) }, [destination, destination])
        XCTAssertNotEqual(links.first?.destinationRange, links.last?.destinationRange)
        if links.count == 2 {
            XCTAssertEqual(links[0].destinationRange.location, original.range(of: destination).location)
            let afterFirst = NSMaxRange(links[0].destinationRange)
            XCTAssertEqual(links[1].destinationRange.location,
                original.range(of: destination, range: NSRange(location: afterFirst, length: original.length - afterFirst)).location)
        }
    }

    func testSameURLInCodeNeverBorrowsPermissionFromRealLink() {
        let source = "```markdown\n\(link)\n```\n\n`\(link)`\n\n    \(link)\n\n\(link)\n"
        let links = ReadingNoteLinkFolds.links(in: source), original = source as NSString
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.destinationRange.location, original.range(of: destination, options: .backwards).location)
        if let first = links.first { XCTAssertEqual(original.substring(with: first.destinationRange), destination) }
    }

    func testTildeQuoteAndListFencesRemainLiteral() {
        for source in ["~~~md\n\(link)\n~~~", "> ```\n> \(link)\n> ```", "- ~~~\n  \(link)\n  ~~~", "\t\(link)"] {
            XCTAssertTrue(ReadingNoteLinkFolds.links(in: source).isEmpty, source)
        }
    }

    func testExternalURLsCodeImagesDefinitionsAndAmbiguousSyntaxRemainVisible() {
        let sources = [
            "[外部链接](https://example.test/\(destination))",
            "![图片](\(destination))", "\\\(link)",
            "[定义]: \(destination)", "[多行]\n(\(destination))",
            "正文 \(link)", "[带 `代码` 标签](\(destination))",
            "[嵌套[标签]](\(destination))", "[带标题](\(destination) \"说明\")",
            "[地址](readingbook://other/book-a/unit/unit-000008)",
            "[不完整地址](readingbook://book/book-a)",
            "<pre>\n\(link)\n</pre>"
        ]
        for source in sources { XCTAssertTrue(ReadingNoteLinkFolds.links(in: source).isEmpty, source) }
    }

    func testCompleteLocationParametersAreNotDecodedOrNormalizedInTheSourceMap() {
        let raw = "readingbook://book/AbC/unit/U?quote=%e5%bb%ba%20%E5%AF%A7&prefix=a%2Bb&suffix=%25&quote=second&empty=&fragment=%23x#keep"
        let source = "[回到原文](\(raw))"
        let links = ReadingNoteLinkFolds.links(in: source)
        XCTAssertEqual(links.count, 1)
        guard let destinationRange = links.first?.destinationRange else { return }
        XCTAssertEqual((source as NSString).substring(with: destinationRange), raw,
            "URL 解析只能授权显示范围，不能序列化后替换原链接。")
    }
    #endif

    func testCaretAtOrInsideDestinationExposesTheWholeTarget() {
        let link = ReadingNoteLinkFolds.Link(range: .init(location: 2, length: 70), destinationRange: .init(location: 10, length: 60))
        for location in [10, 11, 35, 69, 70] {
            XCTAssertTrue(ReadingNoteLinkFolds.foldedLinks([link], selection: .init(location: location, length: 0), expanded: false, composing: false).isEmpty)
        }
        for location in [0, 9, 71, 80] {
            XCTAssertEqual(ReadingNoteLinkFolds.foldedLinks([link], selection: .init(location: location, length: 0), expanded: false, composing: false), [link])
        }
    }

    func testSelectionsCompositionAndManualExpansionNeverHideEditableTargets() {
        let first = ReadingNoteLinkFolds.Link(range: .init(location: 0, length: 31), destinationRange: .init(location: 8, length: 22))
        let second = ReadingNoteLinkFolds.Link(range: .init(location: 40, length: 31), destinationRange: .init(location: 48, length: 22))
        let both = [first, second]
        XCTAssertEqual(ReadingNoteLinkFolds.foldedLinks(both, selection: .init(location: 9, length: 2), expanded: false, composing: false), [second])
        XCTAssertTrue(ReadingNoteLinkFolds.foldedLinks(both, selection: .init(location: 0, length: 71), expanded: false, composing: false).isEmpty)
        XCTAssertTrue(ReadingNoteLinkFolds.foldedLinks(both, selection: .init(location: 0, length: 0), expanded: true, composing: false).isEmpty)
        XCTAssertTrue(ReadingNoteLinkFolds.foldedLinks(both, selection: .init(location: 0, length: 0), expanded: false, composing: true).isEmpty)
        XCTAssertTrue(ReadingNoteLinkFolds.foldedLinks(both,
            selections: [.init(location: 10, length: 1), .init(location: 50, length: 1)], expanded: false, composing: false).isEmpty,
            "原生多选区也必须先展开将被编辑的完整目标。")
    }

    func testDirectEditRevealsHiddenCharactersBeforeMutatingThem() {
        let link = ReadingNoteLinkFolds.Link(range: .init(location: 2, length: 70), destinationRange: .init(location: 10, length: 60))
        for range in [NSRange(location: 10, length: 0), .init(location: 69, length: 1), .init(location: 0, length: 72)] {
            XCTAssertTrue(ReadingNoteLinkFolds.editTouchesFold(range, folded: [link]))
        }
        XCTAssertFalse(ReadingNoteLinkFolds.editTouchesFold(.init(location: 0, length: 10), folded: [link]))
        XCTAssertFalse(ReadingNoteLinkFolds.editTouchesFold(.init(location: 71, length: 0), folded: [link]))
    }

    func testSavingNewDraftRetainsHistoryButOtherNotesAndReplacementTextDoNot() {
        func keeps(_ book: String? = "b", _ old: String?, _ nextBook: String? = "b", _ next: String?, _ incoming: String = "source") -> Bool {
            ReadingNoteEditorContinuity.preservesHistory(previousLibraryKey: "/fixture/library-a", previousBookID: book, previousDocumentID: old,
                nextLibraryKey: "/fixture/library-a", nextBookID: nextBook, nextDocumentID: next, currentMarkdown: "source", incomingMarkdown: incoming)
        }
        XCTAssertTrue(keeps("b", nil, "b", "saved-new-id"))
        XCTAssertTrue(keeps("b", "same", "b", "same"))
        XCTAssertFalse(keeps("b", "first", "b", "different"))
        XCTAssertFalse(keeps("b", nil, "other-book", "saved-new-id"))
        XCTAssertFalse(keeps("b", "saved", "b", nil))
        XCTAssertFalse(keeps("b", "same", "b", "same", "external replacement"))
        XCTAssertEqual("é", "e\u{301}", "Swift 字符串相等不代表原始字节相等。")
        XCTAssertFalse(ReadingNoteEditorContinuity.identicalSource("é", "e\u{301}"))
        for pair in [("\u{212B}", "\u{00C5}"), ("a\u{301}\u{327}", "a\u{327}\u{301}")] {
            XCTAssertEqual(pair.0, pair.1)
            XCTAssertEqual(pair.0.utf16.count, pair.1.utf16.count)
            XCTAssertFalse(ReadingNoteEditorContinuity.identicalSource(pair.0, pair.1),
                "UTF-16 长度也相同的规范等价序列仍不能误判为原文相同。")
        }
        XCTAssertFalse(ReadingNoteEditorContinuity.identicalSource("a\r\nb", "a\nb"))
    }

    func testIdenticalIDsAndTextInAnotherLibraryCannotInheritUndo() {
        XCTAssertFalse(ReadingNoteEditorContinuity.preservesHistory(
            previousLibraryKey: "/fixture/library-a", previousBookID: "same-book", previousDocumentID: "same-note",
            nextLibraryKey: "/fixture/library-b", nextBookID: "same-book", nextDocumentID: "same-note",
            currentMarkdown: "identical source", incomingMarkdown: "identical source"))
        XCTAssertEqual(ReadingNoteEditorContinuity.libraryKey(URL(fileURLWithPath: "/fixture/a/../library")),
            ReadingNoteEditorContinuity.libraryKey(URL(fileURLWithPath: "/fixture/library")))
    }

    func testOrdinaryProseEditsRemapVerifiedUTF16TargetsWithoutParsing() {
        let links = (0..<5).map { index in ReadingNoteLinkFolds.Link(
            range: .init(location: 100_000 + index * 3_000, length: 2_500),
            destinationRange: .init(location: 100_008 + index * 3_000, length: 2_490)) }
        let context = "五十万字节正文中正在编辑的普通句子。"
        XCTAssertTrue(ReadingNoteLinkFolds.canRemap(replacedText: "", replacement: "😀", editLine: context))
        let next = ReadingNoteLinkFolds.remapped(links, editedRange: .init(location: 2, length: 0), replacementLength: 2)
        XCTAssertEqual(next.count, 5)
        XCTAssertEqual(next.map(\.destinationRange.location), links.map { $0.destinationRange.location + 2 })
        XCTAssertEqual(ReadingNoteLinkFolds.remapped(links, editedRange: .init(location: 200_000, length: 2), replacementLength: 1), links)
        XCTAssertEqual(ReadingNoteLinkFolds.remapped(links, editedRange: .init(location: 100_010, length: 1), replacementLength: 1).count, 4)
        for changed in ["```", "<pre>", "\n", "\\", "\t", "[标签]"] {
            XCTAssertFalse(ReadingNoteLinkFolds.canRemap(replacedText: "", replacement: changed, editLine: context))
            XCTAssertFalse(ReadingNoteLinkFolds.canRemap(replacedText: changed, replacement: "", editLine: context))
        }
        XCTAssertFalse(ReadingNoteLinkFolds.canRemap(replacedText: "x", replacement: "", editLine: "x```"),
            "删除普通字母也可能暴露代码围栏，不能只检查插入/删除的字符。")
    }
}
