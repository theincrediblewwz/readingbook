import Foundation
import XCTest
@testable import ReadingCore

final class ReadingChatHistoryTests: XCTestCase {
    private func book() -> BookProject {
        BookProject(title: "对话", originalName: "book.txt", sourceHash: "source", units: [
            SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: "开篇。另一句。"),
            SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "人物来到这里。"),
            SourceUnit(id: "u3", order: 2, chapter: "三", page: 3, text: "最后的结局。")])
    }
    private func pair(_ id: String, context: ReadingChatContext?, mode: ReadingConversationMode = .reading) -> [ChatMessage] {
        ["user", "assistant"].map { role in
            var value = ChatMessage(id: id + "-" + role, role: role, content: id)
            value.conversationMode = mode; value.answerStyle = .mentor; value.readingContext = context
            return value
        }
    }
    func testAutomaticContextExcludesFutureOpenSpoilerLegacyAndOtherModeWithoutChangingHistory() throws {
        var book = book()
        func snapshot(_ id: String, _ page: Int) throws -> ReadingQuerySnapshot {
            try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: id, page: page))
        }
        let first = try snapshot("u1", 1), current = try snapshot("u2", 2), future = try snapshot("u3", 3)
        book.chats = try pair("past", context: ReadingChatContext(snapshot: first, avoidsSpoilers: true))
            + pair("here", context: ReadingChatContext(snapshot: current, avoidsSpoilers: true))
            + pair("future", context: ReadingChatContext(snapshot: future, avoidsSpoilers: true))
            + pair("open", context: ReadingChatContext(snapshot: current, avoidsSpoilers: false))
            + pair("legacy", context: nil)
            + pair("functional", context: ReadingChatContext(snapshot: current, avoidsSpoilers: true), mode: .functional)
        let original = book.chats
        let safe = ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: current)
        XCTAssertEqual(safe.map(\.id), ["past-user", "past-assistant", "here-user", "here-assistant"])
        XCTAssertEqual(book.chats.map(\.id), original.map(\.id)); XCTAssertNil(book.chats.first(where: { $0.id == "legacy-user" })?.readingContext)
        let open = ReadingChatHistory.automaticHistory(in: book, preferences: .init(avoidsSpoilers: false), snapshot: current)
        XCTAssertEqual(open.count, 10, "明确关闭防剧透后仍可使用本模式完整历史，旧数据没有删除。")
        let raw = #"{"requirements":[],"conclusions":[{"text":"后文结局","sources":["future-assistant"]}],"unresolved":[]}"#
        let memory = try ConversationMemoryRuntime.parse(raw, previous: nil, next: .init(index: original.count), snapshot: current,
            history: original, model: "fixture", suppliedIDs: Set(original.map(\.id)))
        XCTAssertFalse(ConversationMemoryRuntime.isValid(memory, snapshot: current, history: safe), "旧派生记忆不能把已过滤后文重新带回。")
    }
    func testSelectionHistoryRequiresSameStableSliceAndExplicitDocumentMembership() throws {
        var book = book()
        let first = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: ReadingContext(unitID: "u1", selectedText: "开篇。", page: 1))
        let other = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: ReadingContext(unitID: "u1", selectedText: "另一句。", page: 1))
        let same = try ReadingChatContext(snapshot: first.withContextIdentity("reading:mentor:current"), avoidsSpoilers: true)
        let plain = try ReadingChatContext(snapshot: first, avoidsSpoilers: true)
        XCTAssertEqual(same.scopeFingerprint, plain.scopeFingerprint, "请求/模式派生标识不应使相同原文选段的追问丢失历史。")
        book.chats = try pair("same", context: same) + pair("other", context: ReadingChatContext(snapshot: other, avoidsSpoilers: true))
        XCTAssertEqual(ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: first).map(\.id), ["same-user", "same-assistant"])
        book.documents = [DocumentRecord(id: "note", title: "明确附加的笔记")]
        let shared = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u1", page: 1), appendedDocumentIDs: ["note"])
        let current = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u1", page: 1))
        book.chats = try pair("attachment", context: ReadingChatContext(snapshot: shared, avoidsSpoilers: true))
        XCTAssertTrue(ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: current).isEmpty)
        XCTAssertEqual(ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: shared).count, 2)
    }
}
