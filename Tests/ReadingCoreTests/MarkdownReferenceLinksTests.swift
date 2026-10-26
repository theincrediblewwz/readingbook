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
    func testManyUnclosedMathOpenersLeaveTextAndFollowingReferencesIntact() {
        for opener in [#"\(x "#, #"\[x "#] {
            let source = String(repeating: opener, count: 20_000) + "中文🙂 [doc:yes]"
            let expected = source.replacingOccurrences(of: "[doc:yes]", with: "[笔记](readingbook://book/b/document/yes)")
            XCTAssertEqual(MarkdownReferenceLinks.render(source, bookID: "b"), expected)
        }
    }
    func testIndexedMathClosersKeepBackslashPairAndCodeSemantics() {
        let mathSources = [
            #"\([doc:inside]\\) [doc:also-inside] \) [doc:yes]"#,
            #"\[[doc:inside]\\] [doc:also-inside] \] [doc:yes]"#,
            #"\([doc:inside]\\\) [doc:yes]"#,
            #"\[[doc:inside]\\\] [doc:yes]"#,
            "`\\([doc:code]\\)` 与 \\([doc:math]\\) [doc:yes]",
            "```\n\\([doc:code]\\)\n```\n\\[[doc:math]\\]\n[doc:yes]"
        ]
        for source in mathSources {
            XCTAssertEqual(MarkdownReferenceLinks.render(source, bookID: "b"),
                source.replacingOccurrences(of: "[doc:yes]", with: "[笔记](readingbook://book/b/document/yes)"))
        }
        for source in [#"\\([doc:open] \) [doc:yes]"#, #"\([doc:open]\\) [doc:yes]"#] {
            let expected = source.replacingOccurrences(of: "[doc:open]", with: "[笔记](readingbook://book/b/document/open)")
                .replacingOccurrences(of: "[doc:yes]", with: "[笔记](readingbook://book/b/document/yes)")
            XCTAssertEqual(MarkdownReferenceLinks.render(source, bookID: "b"), expected)
        }
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
    func testProjectLabelIndicesPreserveFirstMatchAndMissingReferenceFallbacks() {
        var project = BookProject(title: "引用索引", originalName: "book.txt", sourceHash: "fixture", units: [
            SourceUnit(id: "page", order: 0, chapter: "第一章", page: 2, text: "甲"),
            SourceUnit(id: "page", order: 1, chapter: "第二章", page: 9, text: "乙"),
            SourceUnit(id: "chapter", order: 2, chapter: "第三章", text: "丙")
        ])
        project.documents = [DocumentRecord(id: "note", title: "最初标题"), DocumentRecord(id: "note", title: "后来标题")]
        project.chats = [ChatMessage(id: "old", role: "user", content: "问题"), ChatMessage(id: "old", role: "assistant", content: "回答")]
        let source = "[unit:page] [unit:page] [unit:chapter] [doc:note] [message:old] [unit:missing] [doc:missing] [message:missing]"
        let result = MarkdownReferenceLinks.render(source, bookID: "b", project: project)
        XCTAssertEqual(result, "[第 2 页](readingbook://book/b/unit/page) [第 2 页](readingbook://book/b/unit/page) [第三章](readingbook://book/b/unit/chapter) [最初标题](readingbook://book/b/document/note) [先前的问题](readingbook://book/b/message/old) [原文](readingbook://book/b/unit/missing) [笔记](readingbook://book/b/document/missing) [历史对话](readingbook://book/b/message/missing)")
        XCTAssertEqual(MarkdownReferenceLinks.render(source, bookID: "b", project: nil), MarkdownReferenceLinks.render(source, bookID: "b"))
    }
}
