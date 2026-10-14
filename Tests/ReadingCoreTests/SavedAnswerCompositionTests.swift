import Foundation
import XCTest
@testable import ReadingCore

final class SavedAnswerCompositionTests: XCTestCase {
    private func fixture() -> BookProject {
        let evidence = Evidence(unitID: "unit-1", quote: "原文中的证据")
        var book = BookProject(id: "book-fixture", title: "样本", originalName: "sample.md", sourceHash: String(repeating: "a", count: 64),
                               units: [SourceUnit(id: "unit-1", order: 0, chapter: "一", text: "这里有原文中的证据。")])
        book.documents = [DocumentRecord(id: "note-1", title: "我的定义")]
        book.chats = [
            ChatMessage(id: "question-1", role: "user", content: "第一个问题"),
            ChatMessage(id: "answer-1", role: "assistant", content: "先看 **定义**。\n\n精确公式是 $a^2+b^2=c^2$。😀\n\n引用 [doc:note-1]", evidence: [evidence]),
            ChatMessage(id: "question-2", role: "user", content: "第二个问题"),
            ChatMessage(id: "answer-2", role: "assistant", content: "继续推导。 [我的定义](readingbook://book/book-fixture/document/note-1)", evidence: [evidence])
        ]
        return book
    }

    func testCombinesInConversationOrderAndKeepsProvenanceWithStableIdentity() throws {
        let book = fixture(), first = book.chats[1], second = book.chats[3]
        let result = try SavedAnswerComposition.build(project: book, parts: [SavedAnswerPart(answer: second), SavedAnswerPart(answer: first)], title: "我的合并")
        let repeated = try SavedAnswerComposition.build(project: book, parts: [SavedAnswerPart(answer: first), SavedAnswerPart(answer: second)], title: "改名不另建副本")
        XCTAssertEqual(result.messageIDs, [first.id, second.id])
        XCTAssertEqual(result.documentID, repeated.documentID)
        XCTAssertEqual(result.evidence, first.evidence, "Repeated evidence is deduplicated")
        XCTAssertEqual(Set(result.linkedIDs), Set(["unit-1", "note-1"]))
        XCTAssertTrue(result.markdown.contains(first.content))
        XCTAssertTrue(result.markdown.contains("conversation-message: answer-2"))
        XCTAssertTrue(result.markdown.contains("readingbook://book/book-fixture/document/note-1"))
        XCTAssertLessThan(result.markdown.range(of: "第一个问题")!.lowerBound, result.markdown.range(of: "第二个问题")!.lowerBound)
        let whole = try SavedAnswerComposition.build(project: book, parts: [SavedAnswerPart(answer: first)])
        XCTAssertEqual(whole.documentID, "answer-\(first.id)", "Preserve existing whole-answer identity")
    }

    func testMarkdownExcerptMustRemainAnExactContinuousCurrentAnswerSubstring() throws {
        let book = fixture(), answer = book.chats[1], exact = "$a^2+b^2=c^2$。😀"
        let part = SavedAnswerPart(messageID: answer.id, sourceContent: answer.content, text: exact, kind: .markdownExcerpt)
        let result = try SavedAnswerComposition.build(project: book, parts: [part])
        XCTAssertTrue(result.markdown.contains(exact))
        XCTAssertTrue(result.markdown.contains("原回答引用的文档"), "References outside the excerpt remain attributable to the original answer")
        XCTAssertThrowsError(try SavedAnswerComposition.build(project: book, parts: [SavedAnswerPart(messageID: answer.id, sourceContent: answer.content, text: "$a^2+b^2=d^2$", kind: .markdownExcerpt)]))
        var changed = book; changed.chats[1].content += " 已修订"
        XCTAssertThrowsError(try SavedAnswerComposition.build(project: changed, parts: [part]), "Stale render/source selections must be rejected")
        XCTAssertThrowsError(try SavedAnswerComposition.build(project: book, parts: [SavedAnswerPart(answer: book.chats[0])]), "User prose is not an AI answer")
        XCTAssertThrowsError(try SavedAnswerComposition.build(project: book, parts: [part, part]))
    }

    func testRenderedExcerptIsExplicitLiteralTextAndCannotChangeSourceAnswer() throws {
        let book = fixture(), answer = book.chats[1]
        let text = "定义里的语义文字 a²+b²=c²\n```\n[外观类似链接](https://example.invalid)"
        let part = SavedAnswerPart(messageID: answer.id, sourceContent: answer.content, text: text, kind: .renderedText)
        let result = try SavedAnswerComposition.build(project: book, parts: [part])
        XCTAssertTrue(result.markdown.contains("不等同于 Markdown / TeX 源码"))
        XCTAssertTrue(result.markdown.contains("````text\n\(text)\n````"), "Rendered text cannot inject Markdown formatting")
        XCTAssertEqual(book.chats[1].content, answer.content)
        let exact = SavedAnswerPart(messageID: answer.id, sourceContent: answer.content, text: text, kind: .markdownExcerpt)
        XCTAssertThrowsError(try SavedAnswerComposition.build(project: book, parts: [exact]), "Semantic text must never be labelled exact source")
    }
}
