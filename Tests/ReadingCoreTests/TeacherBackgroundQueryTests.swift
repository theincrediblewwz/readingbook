import Foundation
import XCTest
@testable import ReadingCore

private actor TeacherQueryRequests {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

final class TeacherBackgroundQueryTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let first = "贾诩善谋。", next = "贾诩又与诸人论事。"
        var book = BookProject(title: "老师缓存", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data((first + next).utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: first), SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: next)])
        PluginEngine.seed(&book)
        book.entities = [KnowledgeEntity(id: "jia", typeID: "person", name: "贾诩", summary: "善于观察局势。", evidence: [Evidence(unitID: "u1", quote: first)])]
        let request = try TeacherBackgroundRequest.freeze(objectID: "jia", in: book, currentUnitID: "u1", avoidsSpoilers: true)
        book.readingKnowledge = ReadingKnowledgeState()
        book.readingKnowledge?.backgrounds = [TeacherBackgroundRecord(id: "teacher-query", objectID: "jia", sourceHash: request.sourceHash,
            contextFingerprint: request.contextFingerprint, unitHashes: request.unitHashes, evidence: request.evidence, avoidsSpoilers: true,
            cursorOrder: 0, title: request.title, markdown: "旧缓存独有的老师介绍：贾诩是汉末的一位谋士，读到这里可以留意他如何观察局势。", model: "fixture")]
        return book
    }
    private func snapshot(_ book: BookProject, unit: String = "u1", selection: Bool = false) throws -> ReadingQuerySnapshot {
        let value = try XCTUnwrap(book.units.first { $0.id == unit })
        return try ReadingQuerySnapshot.freeze(scope: selection ? .selection : .page, in: book,
            context: ReadingContext(unitID: unit, selectedText: selection ? value.text : nil, page: value.page))
    }
    private func result(_ session: inout ReadingQuerySession) async throws -> [String: Any] {
        let value = try await session.execute(name: "object_get", arguments: ["id": "jia"], maximumBytes: 8000)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    func testOnlyMentorExplicitGetReadsSeparateBackgroundWithoutNewCitations() async throws {
        let book = try fixture(), scope = try snapshot(book)
        var mentor = ReadingQuerySession(snapshot: scope, history: [], loader: nil, providedDocuments: [:], project: book,
            answerPreferences: .init(interaction: .reading, style: .mentor))
        let withBackground = try await result(&mentor)
        let background = try XCTUnwrap(withBackground["cachedTeacherBackground"] as? [String: Any])
        XCTAssertEqual(background["id"] as? String, "teacher-query"); XCTAssertEqual(background["citationAllowed"] as? Bool, false)
        XCTAssertNil(background["unitID"]); XCTAssertNil(background["quote"])
        var research = ReadingQuerySession(snapshot: scope, history: [], loader: nil, providedDocuments: [:], project: book)
        let without = try await result(&research)
        XCTAssertNil(without["cachedTeacherBackground"])
        XCTAssertEqual(mentor.sourceExcerpts.map { $0.0 + $0.1 }, research.sourceExcerpts.map { $0.0 + $0.1 }, "背景不增加原文引用许可。")
        XCTAssertFalse(mentor.sourceExcerpts.contains { $0.1.contains("旧缓存独有") })
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("[unit:teacher-query]", session: mentor))
        let search = try await mentor.execute(name: "objects_search", arguments: ["query": "贾诩"], maximumBytes: 8000)
        XCTAssertFalse(search.contains("cachedTeacherBackground"), "搜索不能批量夹带人物背景。")
    }

    func testPageTwoReusesEarlierCacheButSelectionAndCroppedBookStayStrict() async throws {
        let previous = try fixture()
        var book = previous; book.entities[0].evidence.append(Evidence(unitID: "u2", quote: book.units[1].text))
        try ReadingKnowledgeRuntime.captureVersions(before: previous, in: &book)
        let second = try snapshot(book, unit: "u2")
        var page = ReadingQuerySession(snapshot: second, history: [], loader: nil, providedDocuments: [:], project: book, answerPreferences: .init())
        let reused = try await result(&page)
        XCTAssertNotNil(reused["cachedTeacherBackground"])
        XCTAssertFalse(page.sourceExcerpts.contains { $0.0 == "u1" }, "前页背景不是本轮读取前页的回执。")
        let selection = try snapshot(book, unit: "u2", selection: true)
        var chosen = ReadingQuerySession(snapshot: selection, history: [], loader: nil, providedDocuments: [:], project: book, answerPreferences: .init())
        let selected = try await result(&chosen)
        XCTAssertNil(selected["cachedTeacherBackground"], "选段不能借此前背景扩大来源。")
        var cropped = book; cropped.units = [book.units[1]]
        let croppedScope = try ReadingQuerySnapshot.freeze(scope: .book, in: cropped)
        var component = ReadingQuerySession(snapshot: croppedScope, history: [], loader: nil, providedDocuments: [:], project: cropped, answerPreferences: .init())
        let hidden = try await result(&component)
        XCTAssertNil(hidden["cachedTeacherBackground"], "内部.book不等于用户授予全书背景。")
    }

    func testEarlierPageModeAndChangedSourceRejectUnsafeCache() async throws {
        let original = try fixture()
        var future = original; future.readingKnowledge?.backgrounds[0].cursorOrder = 1
        let early = try snapshot(future)
        var query = ReadingQuerySession(snapshot: early, history: [], loader: nil, providedDocuments: [:], project: future, answerPreferences: .init())
        let hidden = try await result(&query)
        XCTAssertNil(hidden["cachedTeacherBackground"], "即使旧引用仍相同，后页生成的背景不能回流早页。")
        var source = original; source.units[0].text += "修订。"
        let revised = try snapshot(source)
        var changed = ReadingQuerySession(snapshot: revised, history: [], loader: nil, providedDocuments: [:], project: source, answerPreferences: .init())
        let stale = try await result(&changed)
        XCTAssertNil(stale["cachedTeacherBackground"])
        var open = ReadingQuerySession(snapshot: try snapshot(original), history: [], loader: nil, providedDocuments: [:], project: original,
            answerPreferences: .init(style: .mentor, avoidsSpoilers: false))
        let differentMode = try await result(&open)
        XCTAssertNil(differentMode["cachedTeacherBackground"], "避免把另一种剧透偏好的缓存静默混入。")
    }

    func testCanonicalRevertWinsOverLaterHistoricalVersionAndNewPromptKeepsPriorBackgroundSeparate() throws {
        let first = try fixture()
        var updated = first; updated.entities[0].summary += "新增的一段理解。"
        try ReadingKnowledgeRuntime.captureVersions(before: first, in: &updated)
        XCTAssertEqual(updated.readingKnowledge?.versions.count, 2)
        let request = try TeacherBackgroundRequest.freeze(objectID: "jia", in: updated, currentUnitID: "u1", avoidsSpoilers: true)
        XCTAssertTrue(request.priorBackgroundMarkdown?.contains("旧缓存独有") == true)
        XCTAssertFalse(request.knownFacts.contains("旧缓存独有"))
        XCTAssertNotEqual(request.contextFingerprint, first.readingKnowledge?.backgrounds.first?.contextFingerprint)
        var reverted = updated; reverted.entities[0] = first.entities[0]
        try ReadingKnowledgeRuntime.captureVersions(before: updated, in: &reverted)
        XCTAssertEqual(reverted.readingKnowledge?.versions.count, 2, "历史不能删除，也不靠重复版本掩盖撤销。")
        XCTAssertEqual(ReadingSpoilerProjection.entity(reverted.entities[0], in: reverted, allowedUnitIDs: ["u1"])?.summary, first.entities[0].summary)
        XCTAssertEqual(SavedKnowledgeReuse(project: reverted, currentUnitIDs: ["u1"])?.entity(reverted.entities[0])?.summary, first.entities[0].summary)
    }

    func testAnswerEngineActuallyPassesHostStyleAndPureReadingKeepsOnlyReadTools() async throws {
        let book = try fixture(), count = TeacherQueryRequests()
        let answer = try await ReadingAnswerEngine.run(question: "给我讲讲贾诩", project: book,
            settings: ProviderSettings(model: "synthetic", contextWindowTokens: 128_000), documents: [:],
            context: ReadingContext(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3,
            preferences: .init(interaction: .reading, style: .mentor)) { messages, tools, _, _ in
            let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            XCTAssertFalse(names.contains("cards_upsert")); XCTAssertFalse(names.contains("views_configure")); XCTAssertFalse(names.contains("knowledge_changes_propose"))
            if await count.next() == 1 {
                return ProviderClient.Result(message: ProviderClient.Message(role: "assistant", content: nil, refusal: nil,
                    tool_calls: [ProviderClient.ToolCall(id: "get", type: "function", function: .init(name: "object_get", arguments: #"{"id":"jia"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 300)
            }
            let returned = messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }.joined()
            XCTAssertTrue(returned.contains("cachedTeacherBackground"))
            return ProviderClient.Result(message: ProviderClient.Message(role: "assistant", content: "这段话写他很善于谋划。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 300)
        }
        XCTAssertTrue(answer.message.content.contains("善于谋划"))
        XCTAssertEqual(answer.diagnostics.sourceReadIDs, ["u1"])
    }
}
