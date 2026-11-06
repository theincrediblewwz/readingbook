import Foundation
import XCTest
@testable import ReadingCore

final class QueryBudgetRecoveryTests: XCTestCase {
    private func book() -> BookProject {
        var value = BookProject(title: "合成读本", originalName: "book.txt", sourceHash: "fixture", units: [.init(id: "u1", order: 0, chapter: "一", page: 1, text: "刘备与关羽同行。")])
        PluginEngine.seed(&value)
        return value
    }
    private func answer(_ text: String) -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: text, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
    }
    private func call(_ name: String, _ arguments: String = "{}", id: String = "one") -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: id, type: "function", function: .init(name: name, arguments: arguments))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
    }
    func testFunctionalQuestionCanContinueBeyondTwelveWithinConfiguredBudget() async throws {
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in Data("{}".utf8) })
        var count = 0
        let result = try await ReadingAnswerEngine.run(question: "仔细核对这句", project: book(), settings: .init(model: "offline", maxRequestsPerRun: 20, maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 20, hostTools: host) { _, _, _, _ in
            count += 1
            if count <= 15 { return self.call("source_read", #"{"id":"u1"}"#, id: "r\(count)") }
            return self.answer("刘备与关羽同行。[unit:u1]")
        }
        XCTAssertEqual(count, 16)
        XCTAssertEqual(result.message.evidence.map(\.unitID), ["u1"])
    }
    func testOrdinaryQuestionCanContinueBeyondSixWithoutOpeningMorePermissions() async throws {
        var count = 0
        let result = try await ReadingAnswerEngine.run(question: "核对原文", project: book(), settings: .init(model: "offline", maxRequestsPerRun: 12, maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 12) { _, tools, _, _ in
            count += 1
            XCTAssertFalse(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "knowledge_changes_propose" })
            if count < 10 { return self.call("source_read", #"{"id":"u1"}"#, id: "r\(count)") }
            return self.answer("刘备与关羽同行。[unit:u1]")
        }
        XCTAssertEqual(count, 10)
        XCTAssertEqual(result.message.evidence.count, 1)
    }
    func testOfficialDoubleBarDSMLAtFinalSlotCannotBecomeAnAnswerOrExecute() async throws {
        var requests = 0
        do {
            _ = try await ReadingAnswerEngine.run(question: "核对原文", project: book(), settings: .init(model: "deepseek-flash", maxRequestsPerRun: 2, maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 2) { _, _, _, final in
                requests += 1
                if !final { return self.call("source_read", #"{"id":"u1"}"#) }
                return self.answer("\n<｜｜DSML｜｜ calls><｜｜DSML｜｜ invoke name=\"components_list\"></｜｜DSML｜｜ invoke></｜｜DSML｜｜ calls>")
            }
            XCTFail("真实服务泄露的内部格式不能当作正文保存")
        } catch { XCTAssertTrue(error.localizedDescription.contains("工具格式")) }
        XCTAssertEqual(requests, 2, "额度耗尽不能自动增加收费修复请求")
    }
    func testFinalRequestExplainsClosureAndKeepsFailedProposalStatus() async throws {
        let proposals = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in throw ReadingError.invalid("事件扩展引用了不存在的事件或类型。") })
        var requests = 0
        _ = try await ReadingAnswerEngine.run(question: "继续整理", project: book(), settings: .init(model: "offline", maxRequestsPerRun: 2, maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 2, proposalAccess: proposals, preferences: .init(interaction: .functional)) { messages, _, _, final in
            requests += 1
            if !final { return self.call("knowledge_changes_propose", #"{"entities":[]}"#) }
            let text = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
            XCTAssertTrue(text.contains("不再调用工具"))
            XCTAssertTrue(text.contains("事件扩展引用了不存在的事件或类型"), "不能在收尾丢掉真正未保存的原因")
            return self.answer("这次补充尚未保存，已有内容保留。")
        }
        XCTAssertEqual(requests, 2)
    }
    func testKnowledgeSchemaProvidesActualTypeReferencesWithoutInventingEventType() async throws {
        let project = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: .init(unitID: "u1", page: 1))
        let proposals = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in Data("{}".utf8) })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project, proposalAccess: proposals)
        let json = try await session.execute(name: "capabilities_list", arguments: ["schemaFor": "knowledge"], maximumBytes: 64_000)
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let guide = value["referenceGuide"] as? [String: Any]
        XCTAssertEqual(guide?["knownTypeIDs"] as? [String], project.types.map(\.id).sorted())
        XCTAssertFalse((guide?["knownTypeIDs"] as? [String] ?? []).contains("event"))
        XCTAssertTrue((guide?["eventMetadataTypeID"] as? String)?.contains("可省略") == true)
    }
    func testFullFunctionalCatalogDoesNotForceClosureBeforeSourceAndProposalSteps() async throws {
        let host = ReadingHostToolAccess(viewActions: ReadingQueryToolCatalog.viewNames.union(ReadingQueryToolCatalog.componentNames), performViewAction: { _, _ in Data("{}".utf8) })
        let proposals = ReadingProposalToolAccess(proposalTools: ReadingQueryToolCatalog.proposalNames, prepare: { _, _ in Data("{}".utf8) })
        let settings = ProviderSettings(model: "offline", maxRequestsPerRun: 24, maxOutputTokens: 3000, contextWindowTokens: 128_000)
        var count = 0
        let result = try await ReadingAnswerEngine.run(question: "继续整理人物和事件，保留我的修正", project: book(), settings: settings, documents: [:], context: .init(unitID: "u1", page: 1), scope: .readSoFar, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 24, hostTools: host, proposalAccess: proposals, preferences: .init(interaction: .functional)) { messages, tools, limit, final in
            count += 1
            XCTAssertFalse(final, "有实际额度时不能因为重复预留完整工具目录而提前收尾")
            XCTAssertGreaterThan(tools.count, 20)
            _ = try ProviderClient.prepare(messages: messages, tools: tools, settings: settings, apiKey: "", remainingTokens: limit)
            if count < 8 { return self.call("source_read", #"{"id":"u1"}"#, id: "r\(count)") }
            return self.answer("刘备与关羽同行。[unit:u1]")
        }
        XCTAssertEqual(count, 8); XCTAssertEqual(result.message.evidence.map(\.unitID), ["u1"])
    }
    func testTightFinalReserveCanOmitDisabledCatalogWithoutLosingEvidenceOrOutput() async throws {
        let settings = ProviderSettings(model: "offline", maxRequestsPerRun: 3, maxOutputTokens: 1024, contextWindowTokens: 128_000)
        var count = 0
        let result = try await ReadingAnswerEngine.run(question: "核对原文", project: book(), settings: settings, documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3) { messages, tools, limit, final in
            count += 1
            let prepared = try ProviderClient.prepare(messages: messages, tools: tools, settings: settings, apiKey: "", remainingTokens: limit)
            if count == 3 {
                XCTAssertTrue(final); XCTAssertTrue(tools.isEmpty, "剩余额度应优先实际证据和答案，而非已禁用的工具目录")
                let body = try JSONSerialization.jsonObject(with: prepared.request.httpBody!) as! [String: Any]
                XCTAssertGreaterThanOrEqual(body["max_tokens"] as? Int ?? 0, 1024)
                XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("刘备与关羽同行") == true })
                return self.answer("刘备与关羽同行。[unit:u1]")
            }
            let value = self.call("source_read", #"{"id":"u1"}"#, id: "r\(count)")
            return .init(message: value.message, finishReason: value.finishReason, tokenCost: count == 2 ? limit - 1 : 20)
        }
        XCTAssertEqual(count, 3); XCTAssertEqual(result.message.evidence.count, 1)
    }
}
