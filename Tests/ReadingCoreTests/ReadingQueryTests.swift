import Foundation
import XCTest
@testable import ReadingCore

final class ReadingQueryTests: XCTestCase {
    private func book() -> BookProject {
        var value = BookProject(id: "query-book", title: "范围测试", originalName: "book.pdf", sourceHash: "source", units: [
            SourceUnit(id: "u1", order: 0, chapter: "第一章", page: 1, text: "甲地战役。刘备在此。"),
            SourceUnit(id: "u2", order: 1, chapter: "第一章", page: 2, text: "孙权守城。第二页秘密。"),
            SourceUnit(id: "u3", order: 2, chapter: "第二章", page: 3, text: "第三页秘密。")])
        value.documents = [DocumentRecord(id: "d1", title: "已选笔记"), DocumentRecord(id: "d2", title: "别的笔记")]
        return value
    }
    func testScopesAreCapabilitiesInsteadOfRelevanceBoosts() async throws {
        let project = book(), context = ReadingContext(sourceHash: "source", unitID: "u1", selectedText: "刘备在此。", page: 1)
        let selection = try ReadingQuerySnapshot.freeze(scope: .selection, in: project, context: context)
        XCTAssertEqual(selection.sources.map(\.text), ["刘备在此。"])
        XCTAssertTrue(selection.documentIDs.isEmpty)
        var session = ReadingQuerySession(snapshot: selection, history: [], loader: nil, providedDocuments: ["d1": "未授权笔记秘密"])
        let selected = try await session.execute(name: "source_read", arguments: ["id": "u1"], maximumBytes: 8000)
        XCTAssertTrue(selected.contains("刘备在此。")); XCTAssertFalse(selected.contains("甲地战役"))
        do { _ = try await session.execute(name: "source_read", arguments: ["id": "u2"], maximumBytes: 8000); XCTFail("不能读取别页") } catch {}
        do { _ = try await session.execute(name: "document_read", arguments: ["id": "d1"], maximumBytes: 8000); XCTFail("不能顺带读取笔记") } catch {}
        XCTAssertEqual(try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: context).unitIDs, ["u1"])
        XCTAssertEqual(try ReadingQuerySnapshot.freeze(scope: .chapter, in: project, context: context).unitIDs, ["u1", "u2"])
        let notes = try ReadingQuerySnapshot.freeze(scope: .notes, in: project, documentIDs: ["d1"])
        XCTAssertEqual(notes.documentIDs, ["d1"]); XCTAssertTrue(notes.unitIDs.isEmpty)
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .notes, in: project, documentIDs: ["missing"]))
        XCTAssertTrue(project.coverage.isEmpty, "查询不增加覆盖")
    }
    func testExactCrossPageSelectionAndAmbiguityNeverWidenScope() throws {
        let project = book()
        let context = ReadingContext(sourceHash: "source", selectedText: "刘备在此。\n孙权守城。", page: 1, selectionEndPage: 2)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: project, context: context)
        XCTAssertEqual(snapshot.unitIDs, ["u1", "u2"])
        XCTAssertEqual(snapshot.sources.map(\.text), ["刘备在此。", "孙权守城。"])
        XCTAssertFalse(snapshot.sources.contains(where: { $0.text.contains("秘密") }))
        var bad = context; bad.selectedText = "刘备 在此。\n孙权守城。"
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .selection, in: project, context: bad))
        bad = context; bad.selectionEndPage = nil
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .selection, in: project, context: bad))
        var duplicate = project; duplicate.units[0].text = "同名。同名。"
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .selection, in: duplicate, context: ReadingContext(unitID: "u1", selectedText: "同名", page: 1)))
    }
    func testLazyNotesAndBoundedSearchOnlyAuthorizeActuallyReturnedEvidence() async throws {
        let project = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .notes, in: project, documentIDs: ["d1"])
        let reads = QueryReadCounter()
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: { document in
            await reads.record(document.id); return "第一行\n原始公式 $x^2$ 和关键词甲乙。\n最后一行"
        }, providedDocuments: [:])
        _ = try await session.execute(name: "documents_list", arguments: [:], maximumBytes: 2000)
        let before = await reads.values()
        XCTAssertEqual(before, [])
        let found = try await session.execute(name: "documents_search", arguments: ["keywords": ["甲乙"]], maximumBytes: 4000)
        let searchResult = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(found.utf8)) as? [String: Any])
        let hits = try XCTUnwrap(searchResult["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.compactMap { $0["id"] as? String }, ["d1"])
        XCTAssertFalse(hits.contains { ($0["id"] as? String) == "d2" })
        let expectedBody = "第一行\n原始公式 $x^2$ 和关键词甲乙。\n最后一行"
        XCTAssertEqual(hits.first?["snippet"] as? String, expectedBody)
        XCTAssertEqual(hits.first?["hash"] as? String, try BookImporter.sha256(Data(expectedBody.utf8)))
        XCTAssertEqual(session.documentExcerpts.map { $0.0 }, ["d1"], "只有真正返回的命中片段才获得引用权限")
        XCTAssertEqual(session.documentExcerpts.map { $0.1 }, [expectedBody])
        let after = await reads.values()
        XCTAssertEqual(after, ["d1"])
        let body = try await session.execute(name: "document_read", arguments: ["id": "d1", "offset": 0, "length": 12000], maximumBytes: 1000)
        XCTAssertLessThanOrEqual(body.utf8.count, 1000); XCTAssertTrue(body.contains("nextOffset"))
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("未知[doc:d2]", session: session))
        XCTAssertNoThrow(try ReadingAnswerEngine.citations("甲乙[doc:d1]", session: session))
        do { _ = try await session.execute(name: "document_read", arguments: ["id": "d1", "expectedHash": "changed"], maximumBytes: 4000); XCTFail("hash冲突不能返回正文") } catch {}
    }
    func testDerivedMemoryHasExactSourceCursorRoleAndScopeValidation() throws {
        let project = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: project)
        let history = (0..<12).map { index in ChatMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant", content: "原文消息\(index)" + String(repeating: "长", count: 100)) }
        let original = history.map(\.content)
        let batch = try XCTUnwrap(ConversationMemoryRuntime.batch(history: history, after: .init(), maximumBytes: 5000))
        let raw = #"{"requirements":[{"text":"保留原文","sources":["m0"]}],"conclusions":[],"unresolved":[]}"#
        let memory = try ConversationMemoryRuntime.parse(raw, previous: nil, next: batch.cursor, snapshot: snapshot, history: history, model: "synthetic", suppliedIDs: ["m0"])
        XCTAssertTrue(ConversationMemoryRuntime.isValid(memory, snapshot: snapshot, history: history))
        var changed = history; changed[0].content += "修改"
        XCTAssertFalse(ConversationMemoryRuntime.isValid(memory, snapshot: snapshot, history: changed))
        let narrow = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: ReadingContext(unitID: "u1", page: 1))
        XCTAssertFalse(ConversationMemoryRuntime.isValid(memory, snapshot: narrow, history: history))
        var forged = memory; forged.requirements[0].sources = ["m1"]
        XCTAssertFalse(ConversationMemoryRuntime.isValid(forged, snapshot: snapshot, history: history))
        XCTAssertEqual(history.map(\.content), original)
        XCTAssertEqual(try JSONDecoder().decode(ConversationMemory.self, from: JSONEncoder().encode(memory)), memory)
    }
    func testAnswerUsesRealReadToolsReservesFinalRequestAndNeverPersistsToolText() async throws {
        let project = book(), settings = ProviderSettings(model: "synthetic", maxRequestsPerRun: 2, contextWindowTokens: 128_000)
        let calls = QueryRequestCounter()
        let result = try await ReadingAnswerEngine.run(question: "刘备在哪里？", project: project, settings: settings, documents: [:],
            context: ReadingContext(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 2) { messages, tools, _, final in
                let index = await calls.record(final: final, tools: tools.count)
                if index == 1 {
                    XCTAssertEqual(messages.last?["content"] as? String, "刘备在哪里？")
                    return ProviderClient.Result(message: ProviderClient.Message(role: "assistant", content: nil, refusal: nil,
                        tool_calls: [ProviderClient.ToolCall(id: "read", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u1"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 100)
                }
                XCTAssertFalse(messages.contains(where: { ($0["role"] as? String) == "tool" }), "最终请求从实际片段重建，不能被旧工具意图挤掉")
                XCTAssertTrue(messages.contains(where: { ($0["content"] as? String)?.contains("actualReadFragments") == true && ($0["content"] as? String)?.contains("刘备在此") == true }))
                return ProviderClient.Result(message: ProviderClient.Message(role: "assistant", content: "原文说“刘备在此”。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
            }
        let records = await calls.values()
        XCTAssertEqual(records.map { $0.0 }, [false, true]); XCTAssertEqual(records[0].1, records[1].1)
        XCTAssertEqual(result.message.evidence.map(\.unitID), ["u1"])
        XCTAssertFalse(result.message.content.contains("nextOffset"), "工具JSON不能进入跨轮持久聊天")
        XCTAssertNil(result.memory); XCTAssertTrue(project.coverage.isEmpty)
        do {
            _ = try await ReadingAnswerEngine.run(question: String(repeating: "问", count: 4001), project: project, settings: settings, documents: [:],
                context: nil, scope: .book, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
                operationLimit: 128_000, remainingRequests: 1) { _, _, _, _ in XCTFail("过长问题不能静默裁剪后发送"); throw ReadingError.invalid("不应调用") }
            XCTFail("应拒绝过长问题")
        } catch {}
    }
    func testSummaryUsageOverflowAbortsInsteadOfBeingSwallowedAsFallback() async throws {
        let project = book(), settings = ProviderSettings(model: "synthetic", maxRequestsPerRun: 3, contextWindowTokens: 128_000)
        let history = (0..<12).map { index in ChatMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant", content: String(repeating: "旧问答", count: 1000)) }
        let calls = QueryRequestCounter()
        do {
            _ = try await ReadingAnswerEngine.run(question: "当前问题", project: project, settings: settings, documents: [:], context: nil,
                scope: .book, history: history, memory: nil, memoryEnabled: true, documentIDs: nil, loader: nil,
                operationLimit: 128_000, remainingRequests: 3) { _, tools, _, final in
                    _ = await calls.record(final: final, tools: tools.count)
                    XCTAssertTrue(tools.isEmpty, "第一调用为有界记忆请求")
                    return ProviderClient.Result(message: ProviderClient.Message(role: "assistant", content: "{}", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: Int.max)
                }
            XCTFail("超大usage必须终止")
        } catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        let records = await calls.values()
        XCTAssertEqual(records.count, 1, "不能吞掉超预算后继续调用模型")
    }

    func testEstimatorCoversProviderAndFinalReserveSurvivesVerboseToolIntent() async throws {
        let project = book(), settings = ProviderSettings(model: String(repeating: "模", count: 180), maxRequestsPerRun: 3, maxOutputTokens: 1024, contextWindowTokens: 128_000, tokenLimitParameter: "max_completion_tokens")
        let calls = QueryRequestCounter()
        let result = try await ReadingAnswerEngine.run(question: "刘备在哪里？", project: project, settings: settings, documents: [:], context: nil,
            scope: .book, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3) { messages, tools, limit, final in
                let index = await calls.record(final: final, tools: tools.count)
                let prepared = try ProviderClient.prepare(messages: messages, tools: tools, settings: settings, apiKey: "", remainingTokens: limit)
                XCTAssertGreaterThanOrEqual(try QueryBudget.inputBytes(messages, tools: tools, model: settings.model), prepared.estimatedInputTokens)
                if index == 3 {
                    XCTAssertTrue(final)
                    XCTAssertFalse(messages.contains(where: { ($0["content"] as? String)?.contains(String(repeating: "冗", count: 500)) == true }))
                    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(prepared.request.httpBody)) as? [String: Any])
                    XCTAssertGreaterThanOrEqual(body["max_completion_tokens"] as? Int ?? 0, 1024, "最终正文和输出都须留得下")
                    return ProviderClient.Result(message: .init(role: "assistant", content: "刘备在此。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
                }
                return ProviderClient.Result(message: .init(role: "assistant", content: index == 2 ? String(repeating: "冗", count: 20_000) : nil, refusal: nil,
                    tool_calls: [.init(id: "call-\(index)", type: "function", function: .init(name: index == 1 ? "source_read" : "source_outline", arguments: index == 1 ? #"{"id":"u1"}"# : "{}"))], reasoning_content: nil),
                    finishReason: "tool_calls", tokenCost: index == 2 ? limit - 1 : 100)
            }
        XCTAssertEqual(result.message.evidence.map(\.unitID), ["u1"])
    }

    func testCancellationFromSummaryAndLazyLoaderNeverFallsThrough() async throws {
        let project = book(), settings = ProviderSettings(model: "synthetic", contextWindowTokens: 128_000)
        let history = (0..<12).map { ChatMessage(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: String(repeating: "旧问答", count: 1000)) }
        let calls = QueryRequestCounter()
        do {
            _ = try await ReadingAnswerEngine.run(question: "问题", project: project, settings: settings, documents: [:], context: nil,
                scope: .book, history: history, memory: nil, memoryEnabled: true, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3) { _, tools, _, final in
                    _ = await calls.record(final: final, tools: tools.count); throw URLError(.cancelled)
                }
            XCTFail("必须取消")
        } catch { XCTAssertTrue(error is CancellationError) }
        let records = await calls.values(); XCTAssertEqual(records.count, 1)
        var session = ReadingQuerySession(snapshot: try ReadingQuerySnapshot.freeze(scope: .notes, in: project), history: [], loader: { _ in throw URLError(.cancelled) }, providedDocuments: [:])
        do { _ = try await session.execute(name: "documents_search", arguments: ["keywords": ["甲"]], maximumBytes: 4000); XCTFail("取消不是不可读笔记计数") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testExactSelectionConstrainsObjectsNodesAndDynamicWorkspace() async throws {
        var project = book()
        project.entities = [KnowledgeEntity(id: "liu", typeID: "person", name: "刘备", evidence: [Evidence(unitID: "u1", quote: "刘备在此。")]),
            KnowledgeEntity(id: "place", typeID: "place", name: "甲地", evidence: [Evidence(unitID: "u1", quote: "甲地战役。")])]
        project.nodes = [CanvasNode(id: "n1", targetID: "liu"), CanvasNode(id: "n2", targetID: "place"), CanvasNode(id: "free", targetID: "")]
        let context = ReadingContext(unitID: "u1", selectedText: "刘备在此。", page: 1)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: project, context: context)
        let feed = QueryWorkspaceFeed(ReadingWorkspaceSnapshot(bookID: project.id, sourceHash: project.sourceHash, rendererID: "map",
            selectedObjectIDs: ["liu", "place"], visibleObjects: .init(rendererID: "map", objectIDs: ["liu", "place"], nodeIDs: ["n1", "n2", "free"]), selectedNodeIDs: ["n1", "n2"]))
        let access = ReadingHostToolAccess(viewActions: ["view_focus"], performViewAction: { _, _ in Data(#"{"status":"success"}"#.utf8) }, readWorkspace: { await feed.get() })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project, hostTools: access)
        let visible = try await session.execute(name: "visible_objects_list", arguments: [:], maximumBytes: 4000)
        XCTAssertTrue(visible.contains("n1")); XCTAssertFalse(visible.contains("n2")); XCTAssertFalse(visible.contains("free")); XCTAssertFalse(visible.contains("place"))
        do { _ = try await session.execute(name: "object_get", arguments: ["id": "place"], maximumBytes: 4000); XCTFail("同unit非选段事实不可读") } catch {}
        do { _ = try await session.execute(name: "view_focus", arguments: ["nodeID": "n2"], maximumBytes: 4000); XCTFail("不能借界面工具定位范围外对象") } catch {}
        XCTAssertThrowsError(try session.validateProposal(name: "graph_changes_propose", data: Data(#"{"batch":{"graph":{"moves":[{"nodeID":"n2","x":1,"y":2}]}}}"#.utf8)), "不能猜一个范围外节点ID来移动")
        let wrongEntity = ControlledKnowledgeChanges(entities: [KnowledgeEntity(id: "place", typeID: "place", name: "甲地", evidence: [Evidence(unitID: "u1", quote: "刘备在此。")])])
        XCTAssertThrowsError(try session.validateProposal(name: "knowledge_changes_propose", data: JSONEncoder().encode(wrongEntity)), "精确引文也不能用来绕过已有对象范围")
        let newEntity = ControlledKnowledgeChanges(entities: [KnowledgeEntity(id: "new-person", typeID: "person", name: "刘备", evidence: [Evidence(unitID: "u1", quote: "刘备在此。")])], newEntityIDs: ["new-person"])
        let newData = try JSONEncoder().encode(newEntity)
        XCTAssertThrowsError(try session.validateProposal(name: "knowledge_changes_propose", data: newData), "来源虽在scope中，未实际读取前也不能生成知识")
        _ = try await session.execute(name: "source_read", arguments: ["id": "u1"], maximumBytes: 4000)
        XCTAssertNoThrow(try session.validateProposal(name: "knowledge_changes_propose", data: newData))
        await feed.setRenderer("mindmap")
        let current = try await session.execute(name: "workspace_context_get", arguments: [:], maximumBytes: 4000)
        XCTAssertTrue(current.contains("mindmap")); XCTAssertFalse(current.contains("n2"))
        let names = ReadingQueryToolCatalog.schemas(snapshot: snapshot, host: nil, proposals: nil).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertFalse(names.contains("document_read")); XCTAssertFalse(names.contains("view_focus")); XCTAssertFalse(names.contains("knowledge_changes_propose"))
        XCTAssertTrue(snapshot.admits(Evidence(unitID: "u1", quote: "刘备"))); XCTAssertFalse(snapshot.admits(Evidence(unitID: "u1", quote: "甲地")))
    }

    func testHostActionsNeedReceiptRoomAndPureStatusAnswerSurvivesFinalRebuild() async throws {
        let project = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: project), counter = QueryReadCounter()
        let host = ReadingHostToolAccess(viewActions: ["panel_present"], performViewAction: { name, _ in await counter.record(name); return Data(#"{"status":"success","message":"已打开面板"}"#.utf8) })
        let proposals = ReadingProposalToolAccess(proposalTools: ["graph_changes_propose"], prepare: { name, _ in await counter.record(name); return Data(#"{"status":"success","applied":true}"#.utf8) })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project, hostTools: host, proposalAccess: proposals)
        _ = try await session.execute(name: "panel_present", arguments: ["panelID": "nodes", "state": "open"], maximumBytes: 900)
        _ = try await session.execute(name: "graph_changes_propose", arguments: ["batch": ["graph": [:]]], maximumBytes: 3999)
        let before = await counter.values(); XCTAssertTrue(before.isEmpty, "不能先执行副作用再因预算藏掉回执")
        let calls = QueryRequestCounter()
        let result = try await ReadingAnswerEngine.run(question: "打开节点面板", project: project, settings: ProviderSettings(model: "synthetic", contextWindowTokens: 128_000), documents: [:], context: nil,
            scope: .book, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 2, hostTools: host) { messages, tools, _, final in
                let index = await calls.record(final: final, tools: tools.count)
                if index == 1 { return ProviderClient.Result(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: "open", type: "function", function: .init(name: "panel_present", arguments: #"{"panelID":"nodes","state":"open"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 100) }
                XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("hostToolReceipts") == true })
                return ProviderClient.Result(message: .init(role: "assistant", content: "节点面板已打开。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
            }
        XCTAssertTrue(result.message.content.contains("节点面板已打开")); XCTAssertFalse(result.message.content.contains("不能据此给出内容结论"))
        XCTAssertTrue(result.diagnostics.sourceReadIDs.isEmpty)
    }

    func testOnlyActualThisTaskReceiptAdmitsNewStandaloneNode() async throws {
        var original = book()
        var old = CanvasNode(id: "old-free", targetID: "old-free"); old.title = "原有独立标题"; old.isStandalone = true
        original.nodes = [old]
        var node = CanvasNode(id: "created-free", targetID: "created-free"); node.title = "新标题"; node.isStandalone = true
        let patch = ControlledRecordPatch(collection: .nodes, id: node.id, before: nil, after: try JSONEncoder().encode(node))
        let receipt = ControlledChangeReceipt(operationID: "own-op", originBookID: original.id, digest: "digest", grantID: "grant", createdAt: Date(), undoneAt: nil,
            idMap: ["new-node": node.id], groups: [.graph], patches: [patch], documents: [])
        var fresh = original, state = ControlledChangeState(); state.receipts = [receipt]; fresh.controlledChanges = state; fresh.nodes.append(node)
        let refreshedProject = fresh
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: original)
        let data: [String: Any] = ["batch": ["graph": ["createNodes": [["clientID": "new-node", "title": "新标题", "x": 0, "y": 0]]]]]
        let preview = ReadingProposalToolAccess(proposalTools: ["graph_changes_propose"], prepare: { _, _ in Data(#"{"status":"needs_confirmation","applied":false,"operationID":"own-op"}"#.utf8) }, currentProject: { refreshedProject })
        var waiting = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: original, proposalAccess: preview)
        _ = try await waiting.execute(name: "graph_changes_propose", arguments: data, maximumBytes: 5000)
        XCTAssertFalse(waiting.admitsNode(node.id, admitted: [], project: refreshedProject), "预览和主观回执不能授予节点权限")
        let applied = ReadingProposalToolAccess(proposalTools: ["graph_changes_propose"], prepare: { _, _ in Data(#"{"status":"success","applied":true,"operationID":"own-op"}"#.utf8) }, currentProject: { refreshedProject })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: original, proposalAccess: applied)
        _ = try await session.execute(name: "graph_changes_propose", arguments: data, maximumBytes: 5000)
        XCTAssertTrue(session.admitsNode(node.id, admitted: [], project: refreshedProject))
        XCTAssertFalse(session.admitsNode(old.id, admitted: [], project: refreshedProject))
        let graph = try await session.execute(name: "book_schema_get", arguments: ["section": "graph"], maximumBytes: 4000)
        XCTAssertTrue(graph.contains("created-free")); XCTAssertFalse(graph.contains("old-free"))
        XCTAssertTrue(snapshot.documentIDs.isEmpty, "没有扩大新笔记正文授权")
    }

    func testExplicitAttachedNoteCanBeEditedAlongsideExactSourceWithoutSharingOthers() async throws {
        let project = book(), context = ReadingContext(unitID: "u1", selectedText: "刘备在此。", page: 1)
        let original = try ReadingQuerySnapshot.freeze(scope: .selection, in: project, context: context)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: project, context: context, appendedDocumentIDs: ["d1"])
        XCTAssertEqual(snapshot.documentIDs, ["d1"]); XCTAssertEqual(snapshot.sources.map(\.text), ["刘备在此。"])
        XCTAssertNotEqual(original.scopeFingerprint, snapshot.scopeFingerprint)
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: context, appendedDocumentIDs: ["missing"]))
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: context, appendedDocumentIDs: ["d1", "d1"]))
        let names = ReadingQueryToolCatalog.schemas(snapshot: snapshot, host: nil, proposals: nil).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("source_read")); XCTAssertTrue(names.contains("document_read"))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: ["d1": "原笔记 $x^2$", "d2": "未分享笔记"], project: project)
        _ = try await session.execute(name: "source_read", arguments: ["id": "u1"], maximumBytes: 4000)
        _ = try await session.execute(name: "document_read", arguments: ["id": "d1"], maximumBytes: 4000)
        do { _ = try await session.execute(name: "document_read", arguments: ["id": "d2"], maximumBytes: 4000); XCTFail("附加一篇不能分享全部笔记") } catch {}
        let hash = try XCTUnwrap(session.documentHashes["d1"])
        let edits = ControlledDocumentChanges(edits: [ControlledDocumentEdit(documentID: "d1", expectedHash: hash, mode: .append, markdown: "补充 [unit:u1]")])
        XCTAssertNoThrow(try session.validateProposal(name: "document_changes_propose", data: JSONEncoder().encode(edits)))
        let unshared = ControlledDocumentChanges(edits: [ControlledDocumentEdit(documentID: "d2", expectedHash: hash, mode: .replace, markdown: "不得写")])
        XCTAssertThrowsError(try session.validateProposal(name: "document_changes_propose", data: JSONEncoder().encode(unshared)))
        XCTAssertFalse(snapshot.admits(Evidence(unitID: "u1", quote: "甲地战役。")))
    }

    func testExplicitLayoutNodeDoesNotAuthorizeItsTargetOrMountedDocument() async throws {
        var project = book()
        project.entities = [KnowledgeEntity(id: "outside", typeID: "person", name: "孙权", evidence: [Evidence(unitID: "u2", quote: "孙权守城。")])]
        var node = CanvasNode(id: "physical", targetID: "outside"); node.title = "我选中的布局"; node.documentIDs = ["d2"]
        project.nodes = [node]
        let context = ReadingContext(unitID: "u1", page: 1)
        let original = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: context)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: context, authorizedNodeIDs: ["physical"])
        XCTAssertEqual(snapshot.authorizedNodeIDs, ["physical"]); XCTAssertNotEqual(snapshot.scopeFingerprint, original.scopeFingerprint)
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: context, authorizedNodeIDs: ["guessed"]))
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: context, authorizedNodeIDs: ["physical", "physical"]))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: ["d2": "不该读到"], project: project)
        let graph = try await session.execute(name: "book_schema_get", arguments: ["section": "graph"], maximumBytes: 4000)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(graph.utf8)) as? [String: Any])
        let item = try XCTUnwrap((root["items"] as? [[String: Any]])?.first)
        let layout = try XCTUnwrap(item["value"] as? [String: Any])
        XCTAssertEqual(layout["id"] as? String, "physical"); XCTAssertNil(layout["targetID"])
        XCTAssertEqual(layout["documentIDs"] as? [String], []); XCTAssertEqual(item["contentRestricted"] as? Bool, true)
        do { _ = try await session.execute(name: "object_get", arguments: ["id": "outside"], maximumBytes: 4000); XCTFail("节点授权不是目标事实授权") } catch {}
        do { _ = try await session.execute(name: "document_read", arguments: ["id": "d2"], maximumBytes: 4000); XCTFail("节点授权不是挂载正文授权") } catch {}
        XCTAssertNoThrow(try session.validateProposal(name: "graph_changes_propose", data: Data(#"{"batch":{"graph":{"renames":[{"nodeID":"physical","title":"新标题"}]}}}"#.utf8)))
        var unshared = ReadingQuerySession(snapshot: original, history: [], loader: nil, providedDocuments: [:], project: project)
        XCTAssertFalse(unshared.admitsNode("physical", admitted: [], project: project))
        _ = try await unshared.execute(name: "source_outline", arguments: [:], maximumBytes: 2000)
    }

    func testSharedIdentityKeepsLocalEvidenceButWithholdsCrossScopeFacts() async throws {
        var project = book()
        project.entities = [KnowledgeEntity(id: "liu", typeID: "person", name: "刘备", summary: "后文秘密总结", properties: ["后文": "秘密属性"], aliases: ["先主"], latitude: 1, longitude: 2, locationNote: "后文位置", evidence: [Evidence(unitID: "u1", quote: "刘备在此。"), Evidence(unitID: "u3", quote: "第三页秘密。")])]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: project, context: ReadingContext(unitID: "u1", selectedText: "刘备在此。", page: 1))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project)
        let response = try await session.execute(name: "object_get", arguments: ["id": "liu"], maximumBytes: 5000)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let object = try XCTUnwrap(root["object"] as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "liu"); XCTAssertEqual(root["identityOnly"] as? Bool, true)
        XCTAssertEqual(object["summary"] as? String, ""); XCTAssertEqual(object["fields"] as? [String: String], [:])
        XCTAssertNil(object["latitude"]); XCTAssertFalse(response.contains("第三页秘密")); XCTAssertFalse(response.contains("秘密属性")); XCTAssertFalse(response.contains("先主"))
        XCTAssertEqual(session.sourceExcerpts.map { $0.0 }, ["u1"])
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("未共享的内容[unit:u3]", session: session))
        project.entities[0].name = "后文才揭示的身份"; project.entities[0].aliases = ["刘备", "先主"]
        var concealed = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project)
        let hiddenName = try await concealed.execute(name: "object_get", arguments: ["id": "liu"], maximumBytes: 5000)
        let concealedRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(hiddenName.utf8)) as? [String: Any])
        let concealedObject = try XCTUnwrap(concealedRoot["object"] as? [String: Any])
        XCTAssertEqual(concealedObject["name"] as? String, "刘备")
        XCTAssertFalse(hiddenName.contains("后文才揭示的身份")); XCTAssertFalse(hiddenName.contains("先主"))
        project.entities[0].aliases = []
        var unnamed = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project)
        let found = try await unnamed.execute(name: "objects_search", arguments: ["query": "刘备"], maximumBytes: 4000)
        let foundRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(found.utf8)) as? [String: Any])
        let foundItems = try XCTUnwrap(foundRoot["items"] as? [[String: Any]])
        XCTAssertEqual(foundItems.first?["id"] as? String, "liu", "本段称谓能定位同一身份，不必泄漏后文姓名")
        XCTAssertFalse(found.contains("后文才揭示的身份"))
    }

    func testFinalRequestRetainsSourcedMemoryAndHostStatusAfterRecyclingTools() async throws {
        let project = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: project)
        let history = (0..<12).map { ChatMessage(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "第\($0)条原始问答") }
        let raw = #"{"requirements":[{"text":"保留用户指定的年号表达","sources":["m0"]}],"conclusions":[],"unresolved":[]}"#
        let memory = try ConversationMemoryRuntime.parse(raw, previous: nil, next: .init(index: 8), snapshot: snapshot, history: history, model: "synthetic", suppliedIDs: ["m0"])
        let calls = QueryRequestCounter()
        _ = try await ReadingAnswerEngine.run(question: "继续解释", project: project, settings: ProviderSettings(model: "synthetic", contextWindowTokens: 128_000), documents: [:], context: nil,
            scope: .book, history: history, memory: memory, memoryEnabled: true, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 2,
            hostOperationContext: #"{"status":"applied","operationID":"op-confirmed"}"#) { messages, tools, _, final in
                let index = await calls.record(final: final, tools: tools.count)
                if index == 1 {
                    return ProviderClient.Result(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: "read", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u1"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 100)
                }
                XCTAssertTrue(final)
                XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("早前对话派生记忆") == true && ($0["content"] as? String)?.contains("保留用户指定的年号表达") == true })
                XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("op-confirmed") == true && ($0["role"] as? String) == "user" })
                XCTAssertFalse(messages.contains { ($0["role"] as? String) == "tool" })
                return ProviderClient.Result(message: .init(role: "assistant", content: "刘备在此。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
            }
        XCTAssertEqual(history.count, 12); XCTAssertTrue(ConversationMemoryRuntime.isValid(memory, snapshot: snapshot, history: history))
        XCTAssertNil(try ConversationMemoryRuntime.boundedDataMessage(memory, maximumBytes: 10))
    }
}

private actor QueryReadCounter {
    var records: [String] = []
    func record(_ value: String) { records.append(value) }
    func values() -> [String] { records }
}
private actor QueryRequestCounter {
    var records: [(Bool, Int)] = []
    func record(final: Bool, tools: Int) -> Int { records.append((final, tools)); return records.count }
    func values() -> [(Bool, Int)] { records }
}
private actor QueryWorkspaceFeed {
    var value: ReadingWorkspaceSnapshot
    init(_ value: ReadingWorkspaceSnapshot) { self.value = value }
    func get() -> ReadingWorkspaceSnapshot { value }
    func setRenderer(_ id: String) { value.rendererID = id }
}
