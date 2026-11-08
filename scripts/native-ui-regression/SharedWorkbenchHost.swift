import AppKit
import Foundation
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

private actor WorkbenchTransport {
    var continuing = false
    var records: [[String: Any]] = []
    func configure(_ value: Bool) { continuing = value }
    func count() -> Int { records.count }
    func allRecords() -> [[String: Any]] { records }
    func perform(_ request: ProviderClient.Prepared) throws -> ProviderClient.Result {
        guard request.request.url?.host == "127.0.0.1", request.request.value(forHTTPHeaderField: "Authorization") == nil,
              let body = request.request.httpBody, let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw ReadingError.invalid("只允许离线替身。") }
        let messages = payload["messages"] as? [[String: Any]] ?? []
        let user = messages.lastIndex { $0["role"] as? String == "user" } ?? -1
        let results = Array(messages.dropFirst(user + 1).filter { $0["role"] as? String == "tool" })
        records.append(["continuing": continuing, "messages": messages, "tools": payload["tools"] ?? []])
        func answer() -> ProviderClient.Result {
            .init(message: .init(role: "assistant", content: continuing ? "补充提案已经准备，待你审阅；用户修正和笔记保留。刘备与关羽重逢，张飞来到这里。[unit:u2]" : "已打开联动工作台，使用已有资料，没有重新分析。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
        }
        if payload["tool_choice"] as? String == "none" { return answer() }
        let name: String, args: [String: Any]
        if !continuing {
            switch results.count {
            case 0: name = "components_list"; args = [:]
            case 1: name = "component_show"; args = ["componentID": "reading.composition", "templateID": ReadingWorkbench.templateID]
            default: return answer()
            }
        } else {
            switch results.count {
            case 0: name = "components_list"; args = [:]
            case 1: name = "component_show"; args = ["componentID": "reading.composition", "templateID": ReadingWorkbench.templateID, "title": "模型新起的标题"]
            case 2: name = "reading_coverage_get"; args = [:]
            case 3: name = "object_get"; args = ["id": "liu"]
            case 4: name = "source_read"; args = ["id": "u2"]
            case 5:
                name = "knowledge_changes_propose"
                let proof: [[String: Any]] = [["unitID": "u2", "quote": "刘备与关羽重逢，张飞来到这里。"]]
                args = ["newEntityIDs": ["zhang"], "newEventIDs": ["reunion"],
                    "entities": [
                        ["id": "liu", "typeID": "person", "name": "刘备", "summary": "不应改掉用户的概述", "properties": [:], "aliases": [], "evidence": proof],
                        ["id": "zhang", "typeID": "person", "name": "张飞", "summary": "本页到来的人", "properties": [:], "aliases": [], "evidence": proof]],
                    "events": [["id": "reunion", "name": "重逢", "summary": "二人重逢，张飞到来", "dateText": "时间待考", "placeIDs": [], "participantIDs": ["liu", "zhang"], "evidence": proof]]]
            case 6: name = "component_show"; args = ["componentID": "reading.composition", "templateID": ReadingWorkbench.templateID]
            default: return answer()
            }
        }
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)
        return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: UUID().uuidString, type: "function", function: .init(name: name, arguments: arguments))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
    }
}

@MainActor private final class WorkbenchHost: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: AppStore!
    var output: URL!
    let transport = WorkbenchTransport()
    var checks: [String: Bool] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try await finish(nil) } catch { try? await finish(error) }
            NSApp.terminate(nil)
        }
    }
    func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws { checks[name] = try value(); if checks[name] != true { throw ReadingError.invalid("共享资料检查失败：" + name) } }
    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 20
        while !condition() { guard ProcessInfo.processInfo.systemUptime < end else { throw ReadingError.invalid("共享资料原生等待超时。") }; try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 120_000_000)
    }
    func project(_ selected: Set<String> = ["liu"]) throws -> [String: CompositionProjection] {
        let book = store.book!, snapshot = store.activeComponentView!.snapshot!
        return try CompositionRuntime.project(CompositionRuntime.prepare(ReadingWorkbench.definition(), in: book, sourceSnapshot: snapshot), selections: ["main": selected])
    }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/"), Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("必须隔离测试。") }
        let library = output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1": library.path, "service-profiles": Data("[]".utf8), "query-memory-enabled": false], forName: UserDefaults.argumentDomain)
        var fixture = BookProject(title: "共享资料与工作台 · 隔离合成书", originalName: "book.txt", sourceHash: "fixture", units: [
            .init(id: "u1", order: 0, chapter: "开头", page: 1, text: "刘备与关羽同行，二人相识。"),
            .init(id: "u2", order: 1, chapter: "重逢", page: 2, text: "刘备与关羽重逢，张飞来到这里。"),
            .init(id: "u3", order: 2, chapter: "未读", page: 3, text: "曹操还在后文。")])
        PluginEngine.seed(&fixture); fixture.views = []; fixture.lastUnitID = "u1"
        let proof = [Evidence(unitID: "u1", quote: fixture.units[0].text)]
        fixture.entities = [.init(id: "liu", typeID: "person", name: "刘备", summary: "旧 AI 概述", evidence: proof), .init(id: "guan", typeID: "person", name: "关羽", evidence: proof), .init(id: "cao", typeID: "person", name: "曹操", evidence: [.init(unitID: "u3", quote: fixture.units[2].text)])]
        fixture.events = [.init(id: "meeting", name: "二人相识", summary: "旧事件介绍", participantIDs: ["liu", "guan"], evidence: proof)]
        fixture.relations = [.init(id: "friends", fromID: "liu", toID: "guan", label: "相识", evidence: proof)]
        let source = output.appendingPathComponent("book.txt"), bytes = Data(fixture.units.map(\.text).joined(separator: "\n").utf8)
        fixture.sourceHash = try BookImporter.sha256(bytes); try bytes.write(to: source)
        let repository = LibraryRepository(rootURL: library)
        fixture = try await repository.create(fixture, sourceURL: source)
        let note = DocumentRecord(id: "note", title: "我的刘备笔记", linkedIDs: ["liu"], evidence: proof), noteText = "私有笔记不能默默发送给模型 e\u{301} 🙂。"
        fixture = try await repository.saveDocument(project: fixture, document: note, markdown: noteText)
        let transport = transport
        store = AppStore(sharedAIRequests: AIRequestCoordinator(transport: { try await transport.perform($0) }))
        store.libraryRootURL = library; store.repository = repository; store.books = [fixture]; store.bookID = fixture.id; store.selectedUnitID = "u1"; store.route = "reader"
        store.settings = .init(baseURL: "http://127.0.0.1:1/offline", model: "fixture", maxRequestsPerRun: 24, maxOutputTokens: 3000, contextWindowTokens: 128_000)
        store.apiKey = ""; store.queryMemoryEnabled = false; store.queryScope = .readSoFar
        window = NSWindow(contentRect: .init(x: 90, y: 80, width: 1240, height: 820), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "ReadingBook 共享资料与工作台 · 隔离检查"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings()))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        store.ask("把读到这里的人物关系、相关事件和我的笔记放在一起。")
        try check("initialQueryStarted", store.isQueryBusy)
        try await wait { !self.store.isQueryBusy }
        try check("initialQueryCompleted", store.queryRetryQuestion == nil && store.errorMessage == nil)
        let view = try store.book!.views.first ?? { throw ReadingError.invalid("没有工作台。") }()
        try check("templateAutoSaved", ReadingWorkbench.isWorkbench(view) && store.book!.views.count == 1)
        try check("productionWorkspaceActuallyMounted", store.renderedComponentPresentation?.matches(store, route: view.id) == true)
        try check("initialRangeFrozenAtFirstPage", store.activeComponentView?.snapshot?.unitIDs == ["u1"])
        try check("futureObjectsExcluded", try project()["objects"]?.items.contains { $0.id == "cao" } == false)
        try check("notesLinkedLocally", try project()["notes"]?.items.map(\.id) == ["note"])
        let callsBeforeEdit = await transport.count()
        var entity = store.book!.entities[0]; entity.summary = "我的理解，后续请保留 e\u{301} 🙂。"
        let entitySaved = await store.saveEntity(entity, inBook: fixture.id, basis: .interpretation, expected: store.book!.entities[0])
        try check("manualEntityCorrectionSaved", entitySaved && store.book!.entities[0].summary == entity.summary)
        var event = store.book!.events[0]; event.name = "相识的开端"; event.summary = "我的事件理解"
        store.publish(try await repository.saveKnowledgeEdit(bookID: fixture.id, sourceHash: fixture.sourceHash, expected: .event(store.book!.events[0]), replacement: .event(event), basis: .inference))
        var relation = store.book!.relations[0]; relation.label = "初识的伙伴"
        store.publish(try await repository.saveKnowledgeEdit(bookID: fixture.id, sourceHash: fixture.sourceHash, expected: .relation(store.book!.relations[0]), replacement: .relation(relation), basis: .interpretation))
        try check("eventCorrectionSaved", store.book!.events[0] == event)
        try check("relationCorrectionSaved", store.book!.relations[0] == relation)
        let corrected = try project()
        try check("workbenchUsesSharedEntityCorrection", corrected["details"]?.items.first?.summary == entity.summary)
        try check("workbenchUsesSharedEventCorrection", corrected["events"]?.items.first?.title == event.name)
        try check("workbenchUsesSharedRelationCorrection", corrected["relations"]?.edges.first?.label == relation.label)
        try check("allCorrectionsKeepOriginalEvidence", store.book!.entities[0].evidence == proof && store.book!.events[0].evidence == proof && store.book!.relations[0].evidence == proof)
        let callsAfterEdit = await transport.count(); try check("manualEditsMakeNoModelRequests", callsAfterEdit == callsBeforeEdit)
        store.queryComposerDraft.text = "不能覆盖这个未发出的草稿"
        store.prepareWorkbenchContinuation(view)
        try check("continuationKeepsUnsentDraft", store.queryComposerDraft.text == "不能覆盖这个未发出的草稿")
        store.queryComposerDraft.text = ""; store.selectedUnitID = "u2"
        store.prepareWorkbenchContinuation(view)
        try check("continuationPreparesFunctionalPermission", store.queryInteractionMode == .functional && store.queryAllowsOrganizing)
        try check("continuationUsesReadSoFarAndExistingView", store.queryScope == .readSoFar && store.queryComposerDraft.text.contains(view.id))
        let callsAfterPreparation = await transport.count(); try check("preparationDoesNotSendAutomatically", callsAfterPreparation == callsBeforeEdit)
        await transport.configure(true)
        let question = store.queryComposerDraft.text; store.queryComposerDraft.text = ""
        store.ask(question, allowsOrganizing: true)
        try check("continuationQueryStarted", store.isQueryBusy)
        try await wait { self.store.queryAwaitingReview && !self.store.pendingCurrentBookChanges.isEmpty }
        let pausedRequestCount = await transport.count()
        try check("continuationQueryCompleted", store.queryAwaitingReview && store.isQueryBusy && store.queryRetryQuestion == nil && store.errorMessage == nil && pausedRequestCount == callsBeforeEdit + 6)
        try check("existingRecordSupplementWaitsForReview", store.pendingCurrentBookChanges.count == 1 && !store.book!.entities.contains { $0.name == "张飞" })
        guard let pending = store.pendingCurrentBookChanges.first else { throw ReadingError.invalid("缺少新增证据的审阅提案。") }
        try await Task.sleep(for: .milliseconds(200))
        let stillPaused = await transport.count()
        try check("reviewPauseSendsNoFurtherRequests", stillPaused == pausedRequestCount && store.isQueryBusy)
        let originalRun = store.queryRunID
        let reviewed = await store.applyAIChange(pending)
        try check("reviewedSupplementActuallyCommits", reviewed && store.pendingCurrentBookChanges.isEmpty)
        let afterReview = await transport.count()
        try check("reviewApplyDoesNotAutomaticallySend", afterReview == pausedRequestCount && store.canContinueReviewedQuery)
        store.continueReviewedQuery()
        try check("reviewContinueKeepsOriginalTask", store.queryRunID == originalRun && store.isQueryBusy)
        try await wait { !self.store.isQueryBusy }
        try check("reviewContinueFinishesOriginalTask", store.queryRetryQuestion == nil && !store.queryAwaitingReview && store.errorMessage == nil)
        let continuedRecords = await transport.allRecords()
        let lastMessages = continuedRecords.last?["messages"] as? [[String: Any]] ?? []
        try check("reviewContinueKeepsOriginalQuestion", lastMessages.filter { $0["content"] as? String == question }.count == 1)
        try check("reviewContinueRetainsActualHostReceipt", lastMessages.contains { row in
            guard row["role"] as? String == "tool", let content = row["content"] as? String,
                  let bytes = content.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            return result["applied"] as? Bool == true && result["proposalID"] as? String == pending.id
        })
        let actualReceipt = lastMessages.compactMap { row -> [String: Any]? in
            guard row["role"] as? String == "tool", let content = row["content"] as? String,
                  let result = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                  result["proposalID"] as? String == pending.id, result["applied"] as? Bool == true else { return nil }
            return result
        }.last
        let actualCounts = actualReceipt?["actualChanges"] as? [String: [String: Int]]
        try check("receiptDistinguishesNewAndUpdatedFacts", actualCounts?["entities"] == ["created": 1, "updated": 1] && actualCounts?["events"] == ["created": 1])
        try check("dataReceiptDoesNotClaimComponentOpened", actualReceipt?["scope"] as? String == "data_changes_only" && actualReceipt?["newlyApplied"] as? Bool == true)
        try check("continuationActuallyAddedKnowledge", store.book!.entities.contains { $0.name == "张飞" } && store.book!.events.contains { $0.name == "重逢" })
        try check("continuationKeepsSameWorkbench", store.book!.views.count == 1 && store.route == view.id)
        try check("continuedRangeStopsBeforeFuturePage", store.activeComponentView?.snapshot?.unitIDs == ["u1", "u2"] && store.componentDataBook?.entities.contains { $0.id == "cao" } == false)
        try check("continuedAnalysisKeepsCorrection", store.book!.entities.first { $0.id == "liu" }?.summary == entity.summary)
        try check("continuedAnalysisAddsEvidenceToSameID", store.book!.entities.filter { $0.id == "liu" }.count == 1 && store.book!.entities.first { $0.id == "liu" }?.evidence.count == 2)
        let loaded = try await repository.loadAll().first!
        try check("workbenchAndCorrectionsSurviveReload", loaded.views == store.book!.views && loaded.knowledgeUserEdits == store.book!.knowledgeUserEdits && loaded.entities == store.book!.entities)
        let savedNote = try await repository.readDocument(bookID: fixture.id, document: note)
        try check("originalNoteAndSourceBytesPreserved", savedNote == noteText && (try Data(contentsOf: source)) == bytes && loaded.units == fixture.units)
        let records = await transport.allRecords(), serialized = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        try check("localNoteWasNeverSharedWithModel", !String(decoding: serialized, as: UTF8.self).contains(noteText))
        try check("modelReceivesCorrectionBasis", String(decoding: serialized, as: UTF8.self).contains("readerCorrection") && String(decoding: serialized, as: UTF8.self).contains("我的理解"))
        try serialized.write(to: output.appendingPathComponent("offline-model-requests.json"))
        try JSONEncoder().encode(loaded).write(to: output.appendingPathComponent("final-fixture.json"))
        try await timeWindowBridgeChecks(repository: repository)
        if CommandLine.arguments.contains("--inspect") {
            store.readingCompanionVisible = false
            try Data("ready".utf8).write(to: output.appendingPathComponent("inspection-ready"))
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("end-inspection").path) { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        window.close()
    }
    /// Cross the real AppStore -> mounted composition -> background projection
    /// -> acknowledgement bridge; Core-only date arithmetic cannot prove this.
    func timeWindowBridgeChecks(repository: LibraryRepository) async throws {
        let texts = ["建安十二年十一月二十日，甲军出发。", "建安十二年十一月二十一日，乙军到达。"]
        var book = BookProject(title: "时间窗桥接 · 隔离合成书", originalName: "time.txt", sourceHash: "fixture", units: texts.enumerated().map {
            .init(id: "t\($0.offset)", order: $0.offset, chapter: "合成段落", page: $0.offset + 1, text: $0.element)
        })
        PluginEngine.seed(&book)
        let source = output.appendingPathComponent("time.txt"), bytes = Data(texts.joined(separator: "\n").utf8)
        book.sourceHash = try BookImporter.sha256(bytes); try bytes.write(to: source)
        let anchors = try book.units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.id, quote: $0.text, in: book) }
        book.events = book.units.enumerated().map { index, unit in
            .init(id: "event\(index)", name: index == 0 ? "合成出发" : "合成到达", evidence: [.init(unitID: unit.id, quote: unit.text)])
        }
        let dates = (20...21).map { day in TemporalExtent(sourceText: texts[day - 20], calendar: "建安", start: .init(year: 12, month: 11, day: day), precision: .day, uncertainty: .exact) }
        book.temporalKnowledge = .init(anchors: anchors, eventMetadata: [
            .init(eventID: "event0", extent: dates[0], sourceAnchorIDs: [anchors[0].id], assertion: .explicit),
            .init(eventID: "event1", extent: dates[1], sourceAnchorIDs: [anchors[1].id], assertion: .explicit)])
        let sourceDefinition = CompositionDataSource(id: "events", collection: .events, scope: .book, sort: .time)
        let definition = CompositionDefinition(sources: [sourceDefinition], parts: [.init(id: "map", primitive: .map, sourceID: "events"), .init(id: "axis", primitive: .timeline, sourceID: "events")],
            layout: [.init(id: "m", kind: .part, partID: "map"), .init(id: "t", kind: .part, partID: "axis"), .init(id: "root", kind: .column, children: ["m", "t"])], rootID: "root")
        var view = ViewDefinition(id: "time-bridge", title: "合成时间联动", kind: .knowledge)
        view.rendererID = "reading.composition"; view.composition = definition; book.views = [view]
        book = try await repository.create(book, sourceURL: source)
        store.readingCompanionVisible = false; store.publish(book); store.bookID = book.id; store.selectedUnitID = "t1"; store.route = view.id
        try await wait { self.store.renderedComponentPresentation?.matches(self.store, route: view.id) == true }
        try check("timeBridgeCompositionMounted", store.enabledViews.first(where: { $0.id == store.route })?.composition == definition)
        let requestsBefore = await transport.count()
        let arguments: [String: Any] = ["at": ["calendar": "建安", "year": 12, "month": 11, "day": 20], "fromDate": ["year": 12, "month": 11, "day": 20], "toDate": ["year": 12, "month": 11, "day": 20]]
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let response = try await store.performReadingViewAction("view_set_time_window", data: data, expectedBookID: book.id, sourceHash: book.sourceHash)
        let receipt = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        try check("timeBridgeActualProjectionAcknowledged", receipt?["status"] as? String == "success" && (receipt?["message"] as? String)?.contains("已完成筛选") == true)
        let axis = TemporalAxis("calendar-day:建安"), expected = axis.value(dates[0])!
        try check("timeBridgeDateCoordinatesPublishedAfterAck", store.temporalAxis == "calendar-day:建安" && store.timeFrom == expected && store.timeTo == expected && store.timeCursor == expected)
        let window = axis.window(from: store.timeFrom, to: store.timeTo)!
        let filtered = try CompositionRuntime.project(definition, in: book, windows: [sourceDefinition.timeGroup: window])
        try check("timeBridgeWindowSelectsOneSharedEvent", filtered["events"]?.items.map(\.id) == ["event0"])
        let conflict = try await store.performReadingViewAction("view_set_time_window", data: data, expectedBookID: "other-book", sourceHash: book.sourceHash)
        try check("timeBridgeRejectsStaleBook", (try JSONSerialization.jsonObject(with: conflict) as? [String: Any])?["status"] as? String == "conflict")
        do {
            let bad = try JSONSerialization.data(withJSONObject: ["at": ["narrativeOrder": 0, "narrativeDomain": "chapter"], "from": 0, "to": 1])
            _ = try await store.performReadingViewAction("view_set_time_window", data: bad, expectedBookID: book.id, sourceHash: book.sourceHash)
            try check("timeBridgeRejectsUnavailableDomain", false)
        } catch { try check("timeBridgeRejectsUnavailableDomain", error.localizedDescription.contains("尚无可用数据")) }
        try check("timeBridgeRejectedCommandsKeepClock", store.temporalAxis == axis.id && store.timeFrom == expected && store.timeTo == expected)
        try check("timeBridgeSharedDataAndSourcePreserved", store.book?.events == book.events && store.book?.temporalKnowledge == book.temporalKnowledge && (try Data(contentsOf: source)) == bytes)
        let requestsAfter = await transport.count()
        try check("timeBridgeDoesNotRequestModel", requestsBefore == requestsAfter)
        try JSONSerialization.data(withJSONObject: ["response": receipt ?? [:], "axis": store.temporalAxis, "from": store.timeFrom, "to": store.timeTo, "current": store.timeCursor, "filteredEventIDs": filtered["events"]?.items.map(\.id) ?? []], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("time-bridge.json"))
    }
    func finish(_ error: Error?) async throws {
        let records = await transport.allRecords()
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("model-transport-at-exit.json"))
        let result: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error?.localizedDescription ?? "", "checks": checks, "realNetworkRequests": 0, "originalLibraryUsed": false, "mountedProductionWorkspace": true,
            "storeError": store?.errorMessage ?? "", "retryQuestion": store?.queryRetryQuestion ?? "", "disclosure": store?.queryDisclosure ?? ""]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    }
}
@main private enum Main { static func main() { let app = NSApplication.shared; let delegate = WorkbenchHost(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {} } }
