import Foundation
import XCTest
@testable import ReadingCore

final class ReadingAnswerPreferencesTests: XCTestCase {
    private func book() -> BookProject {
        BookProject(title: "三国", originalName: "book.txt", sourceHash: "source",
            units: [SourceUnit(id: "u1", order: 0, chapter: "开篇", page: 1, text: "贾诩在此。"),
                    SourceUnit(id: "u2", order: 1, chapter: "后文", page: 2, text: "后来的变化。")])
    }
    func testPreparedAnswerKeepsSourceHistoryAndModeInOneFrozenInput() throws {
        var project = book()
        let context = ReadingContext(unitID: "u1", page: 1)
        let scope = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: context)
        let chatContext = try ReadingChatContext(snapshot: scope, avoidsSpoilers: true)
        var question = ChatMessage(id: "old-user", role: "user", content: "他是谁？")
        question.conversationMode = .reading; question.answerStyle = .mentor; question.readingContext = chatContext
        var answer = question; answer.id = "old-answer"; answer.role = "assistant"; answer.content = "先看这一页。"
        project.chats = [question, answer]
        let prepared = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: context,
            authorizedNodeIDs: ["not-shared-by-pure-reading"])
        XCTAssertEqual(prepared.snapshot.unitIDs, ["u1"])
        XCTAssertTrue(prepared.snapshot.authorizedNodeIDs.isEmpty)
        XCTAssertEqual(prepared.history.map(\.id), ["old-user", "old-answer"])
        project.units[0].text = "OCR 后的新正文。"; project.chats.removeAll()
        XCTAssertTrue(prepared.snapshot.admits(Evidence(unitID: "u1", quote: "贾诩在此。")))
        XCTAssertFalse(prepared.snapshot.admits(Evidence(unitID: "u1", quote: "OCR 后的新正文。")))
        XCTAssertEqual(prepared.project.units[0].text, "贾诩在此。")
        XCTAssertEqual(prepared.history.count, 2)
        XCTAssertThrowsError(try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: context,
            authorizedNodeIDs: ["unknown-node"], preferences: .init(interaction: .functional)), "prepared 不能跳过功能模式的宿主节点权限校验。")
    }
    func testPureReadingRejectsAccidentallyProvidedHostToolsAndContext() async throws {
        let project = book()
        let host = ReadingHostToolAccess(viewActions: ["panel_present"], performViewAction: { _, _ in
            XCTFail("纯阅读不能执行宿主操作"); return Data()
        })
        let proposal = ReadingProposalToolAccess(proposalTools: ["graph_changes_propose"], prepare: { _, _ in
            XCTFail("纯阅读不能执行整理提案"); return Data()
        })
        let result = try await ReadingAnswerEngine.run(question: "给我讲讲这个人物", project: project,
            settings: ProviderSettings(model: "fixture", contextWindowTokens: 128_000), documents: [:],
            context: ReadingContext(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 1,
            hostOperationContext: String(repeating: "OPERATION_SHOULD_NOT_BE_SENT", count: 300), hostTools: host, proposalAccess: proposal) { messages, tools, _, _ in
                let names = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
                XCTAssertTrue(names.isSubset(of: ReadingAnswerPreferences.readingToolNames))
                XCTAssertTrue(names.contains("source_read")); XCTAssertFalse(names.contains("graph_changes_propose"))
                let text = messages.compactMap { $0["content"] as? String }.joined()
                XCTAssertFalse(text.contains("OPERATION_SHOULD_NOT_BE_SENT"))
                XCTAssertFalse(text.contains("needs_confirmation")); XCTAssertTrue(text.contains("老师"))
                return ProviderClient.Result(message: .init(role: "assistant", content: "可以先把他放在当时的时代里理解。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
            }
        XCTAssertTrue(result.message.content.hasPrefix("### 背景补充"))
        XCTAssertFalse(result.message.content.contains("实际读取原文"))
        XCTAssertTrue(result.message.evidence.isEmpty)
    }

    func testContextModeSeparatesDerivedMemoryWithoutBroadeningScope() throws {
        let project = book(), history = [ChatMessage(id: "q", role: "user", content: "不透露后文"), ChatMessage(id: "a", role: "assistant", content: "我们先读开篇。")]
        let base = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: ReadingContext(unitID: "u1", page: 1))
        let reading = try base.withContextIdentity(ReadingAnswerPreferences().contextIdentity)
        let research = try base.withContextIdentity(ReadingAnswerPreferences(interaction: .functional, style: .research).contextIdentity)
        XCTAssertEqual(reading.unitIDs, ["u1"]); XCTAssertEqual(research.unitIDs, reading.unitIDs)
        XCTAssertNotEqual(reading.scopeFingerprint, research.scopeFingerprint)
        let raw = #"{"requirements":[{"text":"不透露后文","sources":["q"]}],"conclusions":[],"unresolved":[]}"#
        let memory = try ConversationMemoryRuntime.parse(raw, previous: nil, next: .init(index: 2), snapshot: reading, history: history, model: "fixture", suppliedIDs: ["q"])
        XCTAssertTrue(ConversationMemoryRuntime.isValid(memory, snapshot: reading, history: history))
        XCTAssertFalse(ConversationMemoryRuntime.isValid(memory, snapshot: research, history: history))
        XCTAssertFalse(reading.admits(Evidence(unitID: "u2", quote: "后来的变化。")))
    }

    func testResearchModeDoesNotPresentUnseenTextAsBookEvidence() async throws {
        let project = book()
        let result = try await ReadingAnswerEngine.run(question: "原文写了什么？", project: project,
            settings: ProviderSettings(model: "fixture", contextWindowTokens: 128_000), documents: [:], context: nil,
            scope: .book, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 128_000, remainingRequests: 1, preferences: .init(style: .research)) { messages, _, _, _ in
                XCTAssertTrue((messages.first?["content"] as? String)?.contains("采用原文考据方式") == true)
                return ProviderClient.Result(message: .init(role: "assistant", content: "原文一定写了这些。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
            }
        XCTAssertFalse(result.message.content.contains("一定写了")); XCTAssertFalse(result.message.content.contains("背景补充"))
        XCTAssertTrue(result.message.evidence.isEmpty)
    }
}
