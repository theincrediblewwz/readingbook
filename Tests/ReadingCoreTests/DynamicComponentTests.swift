import Foundation
import XCTest
@testable import ReadingCore

final class DynamicComponentTests: XCTestCase {
    private func project() -> BookProject {
        var value = BookProject(title: "中途整理", originalName: "book.txt", sourceHash: "fixture", units: [
            SourceUnit(id: "u1", order: 0, chapter: "开头", page: 1, text: "刘备与关羽同行。"),
            SourceUnit(id: "u2", order: 1, chapter: "相逢", page: 2, text: "张飞来到这里。"),
            SourceUnit(id: "u3", order: 2, chapter: "相逢", page: 2, text: "三人结为兄弟。"),
            SourceUnit(id: "u4", order: 3, chapter: "后文", page: 3, text: "后文尚未分享。")])
        PluginEngine.seed(&value); value.views = []
        return value
    }
    private func fixture() async throws -> (URL, LibraryRepository, BookProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Dynamic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("book.txt")
        try Data("刘备与关羽同行。\n张飞来到这里。\n三人结为兄弟。\n后文尚未分享。".utf8).write(to: source)
        var book = project(); book.sourceHash = try BookImporter.sha256(Data(contentsOf: source))
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        return (root, repository, try await repository.create(book, sourceURL: source))
    }
    private func composition(_ primitive: CompositionPrimitive = .objectList) -> CompositionDefinition {
        CompositionDefinition(sources: [.init(id: "people", collection: .objects)],
            parts: [.init(id: "list", primitive: primitive, sourceID: "people")],
            layout: [.init(id: "root", kind: .part, partID: "list")], rootID: "root")
    }
    private func view(_ id: String, kind: ComponentKind = .relations) -> ViewDefinition { .init(id: id, title: "关系", kind: kind, scope: "current") }

    func testReadSoFarIncludesWholeCurrentPageButNotFutureAndIgnoresOldSelection() throws {
        let book = project()
        let context = ReadingContext(unitID: "u2", selectedText: "张飞", page: 2)
        let prefix = try ReadingQuerySnapshot.freeze(scope: .readSoFar, in: book, context: context)
        XCTAssertEqual(prefix.unitIDs, ["u1", "u2", "u3"])
        XCTAssertTrue(prefix.admits(.init(unitID: "u3", quote: "三人结为兄弟。")))
        XCTAssertFalse(prefix.admits(.init(unitID: "u4", quote: "后文尚未分享。")))
        XCTAssertNotEqual(prefix.scopeFingerprint, try ReadingQuerySnapshot.freeze(scope: .book, in: book, context: context).scopeFingerprint)
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .readSoFar, in: book))
    }
    func testReadSoFarForUnpaginatedTextStopsAtCurrentUnit() throws {
        var book = project(); for index in book.units.indices { book.units[index].page = nil }
        XCTAssertEqual(try ReadingQuerySnapshot.freeze(scope: .readSoFar, in: book, context: .init(unitID: "u2")).unitIDs, ["u1", "u2"])
    }
    func testDirectoryPaginationRejectsUnknownFieldsBooleanAndUnboundedPages() throws {
        let defaults = try ReadingComponentDirectoryRequest.decode(Data("{}".utf8))
        XCTAssertEqual(defaults.offset, 0); XCTAssertEqual(defaults.limit, 8)
        let next = try ReadingComponentDirectoryRequest.decode(Data(#"{"offset":8,"limit":4}"#.utf8))
        XCTAssertEqual(next.offset, 8); XCTAssertEqual(next.limit, 4)
        for raw in [#"{"offset":-1}"#, #"{"limit":9}"#, #"{"offset":true}"#, #"{"limit":1.5}"#, #"{"code":"run"}"#] {
            XCTAssertThrowsError(try ReadingComponentDirectoryRequest.decode(Data(raw.utf8)))
        }
    }
    func testAtomicAppendKeepsLatestNotesAnalysisAndOtherViewsAndReusesAlias() async throws {
        let (root, repository, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var edited = initial
        edited.entities = [.init(id: "liu", typeID: "person", name: "刘备", evidence: [.init(unitID: "u1", quote: "刘备与关羽同行。")])]
        edited.views.append(view("manual-map", kind: .timeline))
        let note = DocumentRecord(id: "reader-note", title: "用户笔记")
        let body = "保存原句 e\u{301} 🙂 和 $x^2$。"
        let latest = try await repository.saveDocument(project: edited, document: note, markdown: body)
        let result = try await repository.ensureReadingComponent(bookID: initial.id, sourceHash: initial.sourceHash, view: view("new-relations"))
        XCTAssertTrue(result.created); XCTAssertEqual(result.project.entities, latest.entities)
        XCTAssertEqual(result.project.documents, latest.documents)
        let savedBody = try await repository.readDocument(bookID: initial.id, document: note)
        XCTAssertEqual(savedBody, body)
        let alias = try await repository.ensureReadingComponent(bookID: initial.id, sourceHash: initial.sourceHash,
            view: view("another-map", kind: .map), equivalentKinds: [.timeline])
        XCTAssertFalse(alias.created); XCTAssertEqual(alias.view.id, "manual-map")
        XCTAssertEqual(alias.project.views.map(\.id), ["manual-map", "new-relations"])
    }
    func testDuplicateComponentDoesNotWriteMetadata() async throws {
        let (root, repository, book) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: view("first"))
        let file = root.appendingPathComponent("library/books/\(book.id)/project.json")
        let bytes = try Data(contentsOf: file), modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let second = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: view("second"))
        XCTAssertFalse(second.created); XCTAssertEqual(second.view, first.view)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
    }
    func testDisabledPluginComponentCannotBeDuplicatedOrReenabledByChat() async throws {
        let (root, repository, book) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var staged = book
        let pack = PluginManifest(id: "optional-relations", name: "可选关系", description: "测试声明包", views: [view("pack-relations")])
        try PluginEngine.install(pack, into: &staged)
        try PluginEngine.setEnabled(false, pluginID: pack.id, in: &staged)
        _ = try await repository.save(staged)
        let file = root.appendingPathComponent("library/books/\(book.id)/project.json"), before = try Data(contentsOf: root.appendingPathComponent("library/books/\(book.id)/project.json"))
        do { _ = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: view("new-relations")); XCTFail("停用组件不能复制绕过") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testCancelledAppendLeavesMetadataUntouched() async throws {
        let (root, repository, book) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library/books/\(book.id)/project.json"), before = try Data(contentsOf: root.appendingPathComponent("library/books/\(book.id)/project.json"))
        let request = view("cancelled")
        let task = Task { () throws -> ReadingComponentInstallation in
            while !Task.isCancelled { await Task.yield() }
            return try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: request)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("取消任务不应落盘") } catch is CancellationError {} catch { XCTFail("取消须返回取消状态") }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testDistinctCompositionPagesCoexistAndIdenticalRequestReuses() async throws {
        let (root, repository, book) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = ViewDefinition(id: "a", title: "人物联动", kind: .knowledge, rendererID: "reading.composition", scope: "current", composition: composition())
        var b = a; b.id = "b"; b.title = "原文对照"; b.composition = composition(.sourceExcerpt)
        let first = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: a)
        let second = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: b)
        var retry = a; retry.id = "retry"
        let third = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: retry)
        XCTAssertTrue(first.created && second.created); XCTAssertFalse(third.created)
        XCTAssertEqual(third.view.id, "a"); XCTAssertEqual(third.project.views.map(\.id), ["a", "b"])
    }
    func testRepositoryAlsoRejectsBookWideCompositionWithoutWriting() async throws {
        let (root, repository, book) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var definition = composition(); definition.sources[0].scope = .book
        let request = ViewDefinition(id: "all-book", title: "越界组合", kind: .knowledge, rendererID: "reading.composition", scope: "current", composition: definition)
        let file = root.appendingPathComponent("library/books/\(book.id)/project.json"), before = try Data(contentsOf: root.appendingPathComponent("library/books/\(book.id)/project.json"))
        do { _ = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: request); XCTFail("仓库入口也必须限制范围") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testSourceMismatchAndIDCollisionLeaveAllBytesUntouched() async throws {
        let (root, repository, book) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: view("one"))
        let file = root.appendingPathComponent("library/books/\(book.id)/project.json"), before = try Data(contentsOf: root.appendingPathComponent("library/books/\(book.id)/project.json"))
        do { _ = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: "different", view: view("two")); XCTFail("source mismatch") } catch {}
        do { _ = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: view("one", kind: .map)); XCTFail("ID collision") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testOwnViewAppendKeepsGrantUsableButDoesNotForgiveInterveningContentEdit() async throws {
        let (root, repository, book) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let own = try await repository.issueChangeGrant(bookID: book.id, permissions: [.knowledge], allowedUnitIDs: ["u1"], requiresReceipts: false, reason: "本次整理")
        let other = try await repository.issueChangeGrant(bookID: book.id, permissions: [.knowledge], allowedUnitIDs: ["u1"], requiresReceipts: false, reason: "另一个任务")
        let added = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: view("own-view"), grant: own)
        let batch = ControlledChangeBatch(knowledge: .init(entities: [.init(id: "liu", typeID: "person", name: "刘备", evidence: [.init(unitID: "u1", quote: "刘备与关羽同行。")])], newEntityIDs: ["liu"]))
        let proposal = try await repository.prepareChanges(batch, grant: own)
        XCTAssertFalse(proposal.requiresConfirmation)
        do { _ = try await repository.prepareChanges(batch, grant: other); XCTFail("另一个任务不能越过自己的旧版本检查") } catch {}
        var edited = added.project; edited.views[0].title = "读者刚刚修改的布局"
        _ = try await repository.save(edited)
        _ = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash, view: view("second", kind: .map), grant: own)
        do { _ = try await repository.prepareChanges(batch, grant: own); XCTFail("新增组件不能宽免此前的内容修改") } catch {}
    }
    func testRequestRejectsCodeUnexpectedFieldsInvalidTitlesAndWrongDefinitionTarget() throws {
        for raw in [#"{"componentID":"relations","script":"fetch('https://example.com')"}"#,
                    #"{"componentID":"relations","title":"   "}"#,
                    #"{"componentID":""}"#] { XCTAssertThrowsError(try ReadingComponentRequest.decode(Data(raw.utf8))) }
        let invalid = ReadingComponentRequest(componentID: "relations", composition: composition())
        XCTAssertThrowsError(try ReadingComponentRequest.decode(JSONEncoder().encode(invalid)))
    }
    func testComponentToolReservesBudgetBeforeCallingHostAndRejectsBookWideComposition() async throws {
        let project = project(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: .init(unitID: "u1"))
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in XCTFail("must not execute"); return Data() })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project, hostTools: host)
        let limited = try await session.execute(name: "component_show", arguments: ["componentID": "relations"], maximumBytes: 1999)
        XCTAssertTrue(limited.contains("budgetLimited"))
        var definition = composition(); definition.sources[0].scope = .book
        let request = ReadingComponentRequest(componentID: "reading.composition", composition: definition)
        let arguments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        do { _ = try await session.execute(name: "component_show", arguments: arguments, maximumBytes: 16_000); XCTFail("scope escalation") } catch {}
    }
    func testReadingModeExposesOnlyComponentPresentationAndKeepsQuestionExact() async throws {
        actor Trace { var names: [String] = []; func add(_ value: String) { names.append(value) } }
        let trace = Trace(), book = project(), question = "我记不太清了，帮我理一理这些人物剧情的关系。"
        let host = ReadingHostToolAccess(viewActions: ["components_list", "component_show", "view_select"], performViewAction: { name, _ in
            await trace.add(name)
            return Data(#"{"ok":true,"status":"success","created":true,"opened":true,"analysisCreated":false}"#.utf8)
        })
        let result = try await ReadingAnswerEngine.run(question: question, project: book,
            settings: .init(model: "fixture", maxOutputTokens: 500, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u2", page: 2),
            scope: .readSoFar, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 4,
            hostTools: host) { messages, tools, _, _ in
                let names = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
                XCTAssertTrue(names.contains("components_list") && names.contains("component_show"))
                XCTAssertFalse(names.contains("view_select") || names.contains("knowledge_changes_propose"))
                XCTAssertEqual(messages.last { $0["role"] as? String == "user" }?["content"] as? String, question)
                let calls = messages.filter { $0["role"] as? String == "tool" }.count
                if calls >= 2 { return .init(message: .init(role: "assistant", content: "已打开关系图谱，显示已有资料。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20) }
                let name = calls == 0 ? "components_list" : "component_show", arguments = calls == 0 ? "{}" : #"{"componentID":"relations"}"#
                return .init(message: .init(role: "assistant", content: nil, refusal: nil,
                    tool_calls: [.init(id: "c\(calls)", type: "function", function: .init(name: name, arguments: arguments))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
            }
        let performed = await trace.names
        XCTAssertEqual(performed, ["components_list", "component_show"])
        XCTAssertTrue(result.message.content.contains("关系图谱"))
    }
}
