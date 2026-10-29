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
    func testEmptyOrIncompatibleHistoryPreservesArchivesAndPreparedScopeGrants() throws {
        let context = ReadingContext(unitID: "u2", page: 2)
        let preferences = ReadingAnswerPreferences(interaction: .functional, style: .mentor)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for scope in [ReadingQueryScope.page, .book] {
            for archiveKind in ["empty", "other-mode", "other-style"] {
                var project = book()
                project.documents = [DocumentRecord(id: "shared-note", title: "已附加笔记"),
                                     DocumentRecord(id: "private-note", title: "未附加笔记")]
                project.nodes = [CanvasNode(id: "shared-layout", targetID: "u2"),
                                 CanvasNode(id: "private-layout", targetID: "u3")]
                let snapshot = try ReadingQuerySnapshot.freeze(scope: scope, in: project, context: context,
                    appendedDocumentIDs: ["shared-note"], authorizedNodeIDs: ["shared-layout"])
                let chatContext = try ReadingChatContext(snapshot: snapshot, avoidsSpoilers: true)
                if archiveKind != "empty" {
                    project.chats = pair(archiveKind, context: chatContext,
                        mode: archiveKind == "other-mode" ? .reading : .functional)
                    for index in project.chats.indices {
                        if archiveKind == "other-style" { project.chats[index].answerStyle = .research }
                        project.chats[index].createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                        project.chats[index].evidence = [Evidence(unitID: "u2", quote: "人物来到这里。")]
                    }
                }
                let label = "\(scope.rawValue)/\(archiveKind)"
                let archives = try encoder.encode(project.chats)
                XCTAssertTrue(ReadingChatHistory.automaticHistory(in: project, preferences: preferences,
                    snapshot: snapshot).isEmpty, label)
                let prepared = try ReadingPreparedAnswer.freeze(project: project, scope: scope, context: context,
                    appendedDocumentIDs: ["shared-note"], authorizedNodeIDs: ["shared-layout"], preferences: preferences)
                XCTAssertTrue(prepared.history.isEmpty, label)
                XCTAssertEqual(prepared.snapshot.unitIDs, scope == .page ? ["u2"] : ["u1", "u2", "u3"], label)
                XCTAssertEqual(prepared.snapshot.documentIDs, ["shared-note"], label)
                XCTAssertEqual(prepared.snapshot.authorizedNodeIDs, ["shared-layout"], label)
                XCTAssertEqual(prepared.chatContext, chatContext, label)
                XCTAssertEqual(try encoder.encode(project.chats), archives, label)
                XCTAssertEqual(try encoder.encode(prepared.project.chats), archives, label)
                XCTAssertThrowsError(try ReadingPreparedAnswer.freeze(project: project, scope: scope, context: context,
                    authorizedNodeIDs: ["missing-layout"], preferences: preferences), label)
            }
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
        XCTAssertEqual(open.map(\.id), ["past-user", "past-assistant", "here-user", "here-assistant", "future-user", "future-assistant", "open-user", "open-assistant"],
            "关闭防剧透允许有来源的后文和开放模式历史，不把旧无范围记录自动发送。")
        XCTAssertEqual(book.chats.map(\.id), original.map(\.id), "未自动发送的旧记录仍保留在历史中。")
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

    func testDisablingSpoilersDoesNotReauthorizeNotesOrOtherSelectionSlices() throws {
        var book = book()
        book.documents = [DocumentRecord(id: "private-note", title: "曾经附加的笔记")]
        let shared = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u1", page: 1), appendedDocumentIDs: ["private-note"])
        let current = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u1", page: 1))
        let selected = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: ReadingContext(unitID: "u1", selectedText: "开篇。", page: 1))
        let other = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: ReadingContext(unitID: "u1", selectedText: "另一句。", page: 1))
        book.chats = try pair("private", context: ReadingChatContext(snapshot: shared, avoidsSpoilers: false))
            + pair("selected", context: ReadingChatContext(snapshot: selected, avoidsSpoilers: false))
            + pair("other", context: ReadingChatContext(snapshot: other, avoidsSpoilers: false))
        let open = ReadingAnswerPreferences(avoidsSpoilers: false)
        XCTAssertFalse(ReadingChatHistory.automaticHistory(in: book, preferences: open, snapshot: current).contains { $0.id.hasPrefix("private-") })
        XCTAssertEqual(ReadingChatHistory.automaticHistory(in: book, preferences: open, snapshot: selected).map(\.id), ["selected-user", "selected-assistant"])
        XCTAssertTrue(ReadingChatHistory.automaticHistory(in: book, preferences: open, snapshot: shared).contains { $0.id == "private-assistant" }, "明确附加后仍可复用对应历史。")
        XCTAssertEqual(book.chats.count, 6)
    }

    func testAutomaticHistoryRechecksOCRAndAttachedNoteVersionsWithoutChangingArchives() throws {
        var book = book()
        book.documents = [DocumentRecord(id: "note", title: "附加笔记")]
        let first = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u1", page: 1))
        let attached = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u1", page: 1), appendedDocumentIDs: ["note"])
        book.chats = try pair("first", context: ReadingChatContext(snapshot: first, avoidsSpoilers: true))
            + pair("attached", context: ReadingChatContext(snapshot: attached, avoidsSpoilers: true))
        let originalIDs = book.chats.map(\.id)
        let same = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u2", page: 2), appendedDocumentIDs: ["note"])
        XCTAssertEqual(ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: same).count, 4)
        book.documents[0].updatedAt += 1
        let updatedNote = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u2", page: 2), appendedDocumentIDs: ["note"])
        XCTAssertEqual(ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: updatedNote).map(\.id), ["first-user", "first-assistant"])
        book.units[0].text += "OCR修订。"
        let updatedSource = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u2", page: 2), appendedDocumentIDs: ["note"])
        XCTAssertTrue(ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: updatedSource).isEmpty)
        XCTAssertTrue(ReadingChatHistory.automaticHistory(in: book, preferences: .init(avoidsSpoilers: false), snapshot: updatedSource).isEmpty)
        XCTAssertEqual(book.chats.map(\.id), originalIDs)
    }

    func testHistoricSelectionIsOnlyAutomaticWhenItsExactSliceCanBeProved() throws {
        var book = book()
        let selected = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: ReadingContext(unitID: "u1", selectedText: "开篇。", page: 1))
        book.chats = try pair("slice", context: ReadingChatContext(snapshot: selected, avoidsSpoilers: true))
        let page = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u2", page: 2))
        XCTAssertTrue(ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: page).isEmpty)
        XCTAssertEqual(ReadingChatHistory.automaticHistory(in: book, preferences: .init(), snapshot: selected).count, 2)
        XCTAssertEqual(book.chats.count, 2, "无法重建的旧slice没有删除，仍能在历史查看。")
    }
}
