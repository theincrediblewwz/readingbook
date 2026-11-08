import Foundation
import XCTest
@testable import ReadingCore

final class ReadingContinuationContextTests: XCTestCase {
    private func fixture(entities: Int = 11, events: Int = 10) -> BookProject {
        var book = BookProject(id: "continuation-context", title: "同一本书", originalName: "book.pdf", sourceHash: "original", units: [
            .init(id: "one", order: 0, chapter: "一", page: 1, text: "208年，曹操到江陵。"),
            .init(id: "two", order: 1, chapter: "二", page: 2, text: "209年，后文秘密。")])
        PluginEngine.seed(&book)
        let evidence = [Evidence(unitID: "one", quote: book.units[0].text)]
        book.entities = (0..<entities).map { .init(id: "person-\($0)", typeID: "person", name: "人物\($0)", evidence: evidence) }
        book.events = (0..<events).map { .init(id: "event-\($0)", name: "事件\($0)", evidence: evidence) }
        book.documents = [.init(id: "private", title: "未分享的笔记标题")]
        return book
    }
    private func session(_ book: BookProject) throws -> ReadingQuerySession {
        var context = ReadingContext(sourceHash: book.sourceHash, unitID: "one", page: 1)
        context.queryRange = .init(pageStart: 1, pageEnd: 1)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context)
        return ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: ["private": "未分享的秘密正文"], project: book,
            proposalAccess: .init(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in Data("{}".utf8) }))
    }
    private func object(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
    func testFirstTurnShowsBothPeopleAndEventsWithScopedCountsAndMissingTime() throws {
        let book = fixture(), query = try session(book)
        let text = try XCTUnwrap(query.organizationStartingPoint(maximumBytes: 6000)), value = try object(text)
        let rows = try XCTUnwrap(value["savedObjects"] as? [[String: String]])
        XCTAssertEqual(rows.count, 21)
        XCTAssertEqual(rows.filter { $0["kind"] == "entity" }.count, 11)
        XCTAssertEqual(rows.filter { $0["kind"] == "event" }.count, 10)
        XCTAssertEqual(rows.filter { $0["timeState"] == "missing" }.count, 10)
        XCTAssertEqual(value["savedCounts"] as? [String: Int], ["entities": 11, "events": 10, "relations": 0, "eventsWithoutTime": 10])
        XCTAssertEqual(value["savedObjectsPartial"] as? Bool, false)
        XCTAssertLessThanOrEqual(text.utf8.count, 6000)
        XCTAssertFalse(text.contains("未分享的")); XCTAssertFalse(text.contains("后文秘密"))
        XCTAssertTrue(query.sourceExcerpts.isEmpty, "身份概览不能授予原文引用或读取笔记")
    }
    func testLargeLibrariesKeepBalancedBoundedOverviewAndHonestPartialFlags() throws {
        var book = fixture(entities: 200, events: 200)
        for i in book.entities.indices { book.entities[i].name = String(repeating: "很长的人物名称", count: 30) }
        for i in book.events.indices { book.events[i].name = String(repeating: "很长的事件名称", count: 30) }
        for cap in [6000, 2500, 1200] {
            let query = try session(book), text = try XCTUnwrap(query.organizationStartingPoint(maximumBytes: cap)), value = try object(text)
            let rows = try XCTUnwrap(value["savedObjects"] as? [[String: String]])
            XCTAssertLessThanOrEqual(text.utf8.count, cap)
            XCTAssertTrue(rows.contains { $0["kind"] == "entity" })
            XCTAssertTrue(rows.contains { $0["kind"] == "event" }, "不能再让人物挤掉所有事件")
            XCTAssertLessThanOrEqual(abs(rows.filter { $0["kind"] == "entity" }.count - rows.filter { $0["kind"] == "event" }.count), 1)
            XCTAssertEqual(value["savedObjectsPartial"] as? Bool, true)
            XCTAssertEqual((value["savedCounts"] as? [String: Int])?["events"], 200)
            XCTAssertTrue(query.sourceExcerpts.isEmpty)
        }
    }
    func testFutureObjectsAndTheirTimeMetadataDoNotLeakIntoContinuationIndex() throws {
        var book = fixture(entities: 1, events: 1)
        book.events.append(.init(id: "future", name: "未来事件秘密", evidence: [.init(unitID: "two", quote: book.units[1].text)]))
        let future = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "two", quote: book.units[1].text, in: book)
        book.temporalKnowledge = .init(anchors: [future], eventMetadata: [.init(eventID: "future", kind: "秘密分类", extent: .init(sourceText: "209年", calendar: "gregorian", start: .init(year: 209), precision: .year, uncertainty: .exact), sourceAnchorIDs: [future.id], assertion: .explicit)])
        let text = try XCTUnwrap(try session(book).organizationStartingPoint(maximumBytes: 6000)), value = try object(text)
        XCTAssertFalse(text.contains("future")); XCTAssertFalse(text.contains("秘密")); XCTAssertFalse(text.contains("209"))
        XCTAssertEqual((value["savedCounts"] as? [String: Int])?["events"], 1)
        XCTAssertEqual(value["otherSavedObjectsMayBeReusable"] as? Bool, true)
    }
    func testToolSchemasRequireActualNonemptyEvidenceAndTemporalAnchorIDs() throws {
        for record in [ReadingProposalSchemas.entity, ReadingProposalSchemas.event, ReadingProposalSchemas.relation] {
            let fields = try XCTUnwrap(record["properties"] as? [String: Any])
            XCTAssertEqual((fields["evidence"] as? [String: Any])?["minItems"] as? Int, 1)
        }
        let fields = try XCTUnwrap(ReadingProposalSchemas.eventMetadata["properties"] as? [String: Any])
        XCTAssertEqual((fields["sourceAnchorIDs"] as? [String: Any])?["minItems"] as? Int, 1)
        XCTAssertEqual((ReadingProposalSchemas.extent["properties"] as? [String: Any])?["narrativeStart"].flatMap { ($0 as? [String: Any])?["maximum"] } as? Int, 1_000_000_000)
        XCTAssertEqual(ReadingProposalSchemas.eventMetadata["additionalProperties"] as? Bool, false)
    }
    func testReusableViewOverviewIsBoundedAndExcludesDisabledViewsAndDocumentBodies() throws {
        var book = fixture(entities: 20, events: 14)
        book.views = [.init(id: "saved-map", title: "地图和时间轴", kind: .knowledge, rendererID: "reading.composition"), .init(id: "disabled-view", title: "停用视图", kind: .map)]
        let plugin = PluginManifest(id: "disabled-plugin", name: "停用组件", description: "合成样例", views: [book.views[1]])
        book.plugins = [plugin]; book.disabledPluginIDs = [plugin.id]
        let base = try session(book)
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in Data("{}".utf8) })
        let query = ReadingQuerySession(snapshot: base.snapshot, history: [], loader: nil, providedDocuments: ["private": "未分享的秘密正文"], project: book,
            hostTools: host, proposalAccess: base.proposalAccess)
        let text = try XCTUnwrap(query.organizationStartingPoint(maximumBytes: 9000)), value = try object(text)
        let views = try XCTUnwrap(value["availableViews"] as? [[String: String]])
        XCTAssertEqual(views.map { $0["id"] ?? "" }, ["saved-map"])
        XCTAssertFalse(text.contains("停用视图")); XCTAssertFalse(text.contains("未分享的"))
        XCTAssertLessThanOrEqual(text.utf8.count, 9000)
        XCTAssertEqual((value["savedObjects"] as? [[String: String]])?.count, 34)
        XCTAssertTrue(query.sourceExcerpts.isEmpty)
        let noHost = try object(try XCTUnwrap(base.organizationStartingPoint(maximumBytes: 9000)))
        XCTAssertEqual((noHost["availableViews"] as? [[String: String]])?.count, 0)
    }
    func testSerializedInstructionsAreBoundedAndKeepGrantedToolsAndSourceReferences() async throws {
        let book = fixture(entities: 1, events: 1), settings = ProviderSettings(model: "offline", maxRequestsPerRun: 20, maxOutputTokens: 6000, contextWindowTokens: 100000)
        var context = ReadingContext(sourceHash: book.sourceHash, unitID: "one", page: 1); context.queryRange = .init(pageStart: 1, pageEnd: 1)
        let host = ReadingHostToolAccess(viewActions: ReadingQueryToolCatalog.componentNames) { _, _ in Data("{}".utf8) }
        let proposals = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in Data("{}".utf8) })
        var calls = 0
        _ = try await ReadingAnswerEngine.run(question: "把这一页的人物和事件串起来", project: book, settings: settings, documents: [:], context: context,
            scope: .range, history: [], memory: nil, memoryEnabled: false, documentIDs: [], loader: nil, operationLimit: 100000, remainingRequests: 20,
            hostTools: host, proposalAccess: proposals, preferences: .init(interaction: .functional)) { messages, tools, _, _ in
                calls += 1
                if calls == 1 {
                    let system = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined()
                    XCTAssertLessThan(system.utf8.count, 6500, "工具字段格式不能重新膨胀成重复总说明")
                    let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                    XCTAssertTrue(names.contains("knowledge_changes_propose")); XCTAssertTrue(names.contains("component_show"))
                    XCTAssertFalse(names.contains("book_scheme_propose"))
                    let originals = messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }.filter { $0.hasPrefix("宿主已提供本次所选范围的实际原文") }
                    XCTAssertEqual(originals.count, 1); XCTAssertTrue(originals[0].contains(book.units[0].text))
                    XCTAssertFalse(originals[0].contains(book.units[1].text))
                }
                return .init(message: .init(role: "assistant", content: "曹操到江陵。[unit:one]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 10)
            }
        XCTAssertEqual(calls, 1)
    }
}
