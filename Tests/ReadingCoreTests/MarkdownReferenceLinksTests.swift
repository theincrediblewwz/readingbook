import XCTest
@testable import ReadingCore

final class MarkdownReferenceLinksTests: XCTestCase {
    func testOnlyActualShorthandBecomesNavigation() {
        let result = MarkdownReferenceLinks.render("中文 [unit:page-1] 与 [doc:my.note]。", bookID: "book-a")
        XCTAssertEqual(result, "中文 [原文](readingbook://book/book-a/unit/page-1) 与 [笔记](readingbook://book/book-a/document/my.note)。")
        XCTAssertEqual(MarkdownReferenceLinks.render("[doc:x]", bookID: ""), "[doc:x]")
    }
    func testCodeFencesInlineCodeAndEscapedMarkersStayLiteral() {
        let source = "`[doc:a]` 与 ``代码 `[unit:b]` ``\n```markdown\n[doc:c]\n```\n> ~~~\n> [unit:d]\n> ~~~\n    [doc:e]\n\\[doc:f]\n[unit:real]"
        let result = MarkdownReferenceLinks.render(source, bookID: "b")
        XCTAssertEqual(result, source.replacingOccurrences(of: "[unit:real]", with: "[原文](readingbook://book/b/unit/real)"))
    }
    func testExistingLinksImagesDestinationsAndDefinitionsDoNotBecomeNestedLinks() {
        let source = "[doc:label](https://example.test/[doc:destination])\n![unit:alt](images/[doc:filename].png)\n[label][doc:reference]\n[ref]: https://example.test/[unit:path]\n<https://example.test/[doc:literal]>"
        XCTAssertEqual(MarkdownReferenceLinks.render(source, bookID: "b"), source)
    }
    func testMathDelimitersAndUnicodeRemainByteFaithful() {
        let source = "$\\text{[doc:a]}$\n$$\n[unit:b] + x\n$$\n\\([doc:c]\\) 与 \\[[unit:d]\\]\n中文🙂 [doc:yes]"
        XCTAssertEqual(MarkdownReferenceLinks.render(source, bookID: "b"), source.replacingOccurrences(of: "[doc:yes]", with: "[笔记](readingbook://book/b/document/yes)"))
    }
    func testShortcutLinksCodeInLabelsAndListFencesMatchTheRealMarkdownParser() {
        let sources = [
            "[doc:x]\n\n[doc:x]: https://example.test/a",
            "[see `[`](https://example.test/[doc:x])",
            "- ~~~\n  [doc:x]\n  ~~~",
            "`[doc:x]\\`",
            "[doc:x]\n\n[DOC\\:X]: https://example.test/a"
        ]
        for source in sources { XCTAssertEqual(MarkdownReferenceLinks.render(source, bookID: "b"), source) }
    }
    func testReadableLabelDoesNotLeakIDOrChangeStableDestination() {
        let result = MarkdownReferenceLinks.render("见[unit:unit-000002]。", bookID: "book", labelForReference: { _, _ in "第 2 页" })
        XCTAssertEqual(result, "见[第 2 页](readingbook://book/book/unit/unit-000002)。")
        let unsafe = MarkdownReferenceLinks.render("[doc:note]", bookID: "book", labelForReference: { _, _ in "]\n[x](https://evil.test)" })
        XCTAssertTrue(unsafe.contains("\\] \\[x\\]\\("))
        XCTAssertTrue(unsafe.hasSuffix("](readingbook://book/book/document/note)"))
    }
    func testMessageCitationUsesReadableChatLabelAndStableMessageRoute() {
        var project = BookProject(title: "对话", originalName: "book.txt", sourceHash: "fixture", units: [])
        project.chats = [ChatMessage(id: "old-answer", role: "assistant", content: "之前的回答")]
        XCTAssertEqual(MarkdownReferenceLinks.render("参考[message:old-answer]。", bookID: project.id, project: project),
            "参考[先前的回答](readingbook://book/\(project.id)/message/old-answer)。")
        XCTAssertEqual(MarkdownReferenceLinks.render("[message:missing]", bookID: "b"), "[历史对话](readingbook://book/b/message/missing)")
        let literal = "`[message:old-answer]` 与 [message:old-answer](https://example.test)"
        XCTAssertEqual(MarkdownReferenceLinks.render(literal, bookID: "b"), literal, "代码和已有链接不能被重写。")
    }
}
