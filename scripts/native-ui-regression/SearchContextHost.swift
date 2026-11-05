import AppKit
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

private actor SearchContextTransport {
    var kinds: [String] = [], streamed = true, privateDataAbsent = true
    var hold = true, failure = false, chat = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var pageProvided = true, adjacentAbsent = true
    func configure(failure: Bool = false, chat: Bool = false) { self.failure = failure; self.chat = chat }
    func release() { hold = false; let values = waiters; waiters = []; values.forEach { $0.resume() } }
    func state() -> (kinds: [String], streamed: Bool, safe: Bool, page: Bool, adjacent: Bool) {
        (kinds, streamed, privateDataAbsent, pageProvided, adjacentAbsent)
    }
    func handle(_ request: ProviderClient.Prepared) async throws -> ProviderClient.Result {
        let body = try JSONSerialization.jsonObject(with: request.request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        streamed = streamed && body["stream"] as? Bool == true
        let raw = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        privateDataAbsent = privateDataAbsent && !raw.contains("绝不能发送的私人笔记") && !raw.contains("绝不能发送的旧问题")
        let content: String
        if chat {
            kinds.append("chat")
            pageProvided = pageProvided && raw.contains("王允歸到府中，尋思今日席間之事")
            adjacentAbsent = adjacentAbsent && !raw.contains("下一页没有分享") && !raw.contains("上一页没有分享")
            if hold { await withCheckedContinuation { waiters.append($0) } }
            content = kinds.count == 1 ? "王允回府后，回想席间的事而坐立不安。" : "王允回府后，回想席间的事而坐立不安。[unit:p92]"
        } else if let input = messages.compactMap({ ($0["content"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }).first(where: { $0["parts"] != nil }),
                  let parts = input["parts"] as? [[String: Any]] {
            kinds.append("read")
            if hold { await withCheckedContinuation { waiters.append($0) } }
            if failure { throw URLError(.networkConnectionLost) }
            let matches = parts.compactMap { part -> [String: String]? in
                guard (part["text"] as? String)?.contains("王允歸到府中") == true else { return nil }
                return ["partID": part["id"] as! String, "quote": "王允歸到府中", "reason": "王允回府"]
            }
            content = String(decoding: try JSONSerialization.data(withJSONObject: ["matches": matches]), as: UTF8.self)
        } else { kinds.append("intent"); content = "{\"keywords\":[\"王允\"]}" }
        return .init(message: .init(role: "assistant", content: content, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
    }
}

@MainActor private final class SearchContextRunner: NSObject, NSApplicationDelegate {
    let output: URL
    var window: NSWindow!, checks: [String: Bool] = [:]
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func settle(_ ms: Int = 15) async { try? await Task.sleep(for: .milliseconds(ms)); window?.contentView?.layoutSubtreeIfNeeded() }
    func wait(_ condition: () -> Bool) async -> Bool { for _ in 0..<300 { if condition() { return true }; await settle() }; return condition() }
    func started(_ transport: SearchContextTransport, kind: String) async -> Bool {
        for _ in 0..<300 { if await transport.state().kinds.contains(kind) { return true }; await settle() }; return false
    }
    func run() async {
        do {
            let library = output.appendingPathComponent("library")
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1": library.path, "service-profiles": Data("[]".utf8), "query-memory-enabled": false], forName: UserDefaults.argumentDomain)
            let settings = ProviderSettings(model: "offline-fixture", maxRequestsPerRun: 8, maxOutputTokens: 1000, contextWindowTokens: 128_000)
            let units: [SourceUnit] = [
                .init(id: "p91", order: 0, chapter: "章", page: 91, text: "上一页没有分享。"),
                .init(id: "p92", order: 1, chapter: "章", page: 92, text: "王允歸到府中，尋思今日席間之事，坐不安席。"),
                .init(id: "p93", order: 2, chapter: "章", page: 93, text: "下一页没有分享。")]
            let source = output.appendingPathComponent("book.txt"), bytes = Data(units.map(\.text).joined(separator: "\n").utf8)
            try bytes.write(to: source)
            var project = BookProject(title: "请求现场隔离书", originalName: "book.txt", sourceHash: try BookImporter.sha256(bytes), units: units)
            PluginEngine.seed(&project)
            let repository = LibraryRepository(rootURL: library)
            project = try await repository.create(project, sourceURL: source)
            let note = DocumentRecord(id: "private-note", title: "私人笔记")
            project = try await repository.saveDocument(project: project, document: note, markdown: "绝不能发送的私人笔记")
            project.chats = [.init(id: "old-question", role: "user", content: "绝不能发送的旧问题")]
            project = try await repository.save(project)
            let frozen = project, transport = SearchContextTransport()
            let coordinator = AIRequestCoordinator(transport: { try await transport.handle($0) })
            let model = ReaderInlineAISearchModel(query: "王允回府", snapshot: .init(project: project), settings: settings, start: { session in
                session.start(settings: settings, apiKey: "", coordinator: coordinator, concurrency: 2)
            }, validateResult: { try $0.validate(in: frozen) })
            window = NSWindow(contentRect: .init(x: 90, y: 90, width: 1000, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 搜索进度与当前页 · 隔离回归"
            window.contentView = NSHostingView(rootView: ReaderInlineAISearchView(model: model).padding(20))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            checks["ActualInlineModelPreparesWithoutNetwork"] = await wait { model.session.plan != nil }
            checks["PreparingUsesNoRequests"] = await transport.state().kinds.isEmpty
            model.start()
            checks["FirstReadTransportActuallyStarts"] = await started(transport, kind: "read")
            checks["FirstBatchPublishesWaitingProgressBeforeCompletion"] = await wait { model.session.requestProgress?.phase == .waitingForResponse && !model.session.understanding }
            checks["ActiveBatchIsOneWhileCompletedCountRemainsZero"] = model.session.activeBatchNumber == 1 && model.session.completedBatches == 0 && !model.session.complete
            checks["WaitingLabelDescribesActiveRequestInsteadOfZeroRead"] = model.session.statusDescription.contains("第1/") && model.session.statusDescription.contains("等待模型响应")
            checks["RealInlineHostRemainsVisibleDuringWait"] = window.isVisible && (window.contentView?.bounds.width ?? 0) > 900
            await transport.release()
            checks["VerifiedBatchFinishesNormally"] = await wait { !model.session.running }
            let sent = await transport.state()
            checks["IntentAndReadingBothUseStreamingRequests"] = sent.kinds == ["intent", "read"] && sent.streamed
            checks["SearchNeverSendsPrivateNotesOrHistory"] = sent.safe
            checks["CompletionUsesExactOriginalQuoteAndPage"] = model.session.complete && model.session.matches.first?.source.page == 92 && model.session.matches.first?.source.quote == "王允歸到府中"
            checks["CompletionCountsUsageFromBothStages"] = model.session.tokenCost == 200 && model.session.completedUnits == 3

            let paused = SearchContextTransport(), pauseSession = WholeBookSearchSession()
            pauseSession.prepare(query: "停止旧请求", snapshot: .init(project: project), settings: settings)
            _ = await wait { pauseSession.plan != nil }
            pauseSession.start(settings: settings, apiKey: "", coordinator: AIRequestCoordinator(transport: { try await paused.handle($0) }), concurrency: 2)
            _ = await started(paused, kind: "read")
            pauseSession.cancel()
            checks["StopPreservesIntentButNoUnreadProgress"] = !pauseSession.running && pauseSession.completedBatches == 0 && pauseSession.keywords == ["王允"] && pauseSession.tokenCost == 100
            checks["PausedZeroBatchLabelIsNotUnderstandingAgain"] = pauseSession.statusDescription == "已暂停 · 完成0/1批" && pauseSession.requestProgress == nil
            await paused.release(); await settle(120)
            checks["LateCompletionCannotPublishAfterStop"] = pauseSession.completedBatches == 0 && pauseSession.matches.isEmpty && pauseSession.requestProgress == nil
            pauseSession.start(settings: settings, apiKey: "", coordinator: AIRequestCoordinator(transport: { try await paused.handle($0) }), concurrency: 2)
            _ = await wait { !pauseSession.running }
            let continued = await paused.state()
            checks["ExplicitContinueDoesNotRepeatIntent"] = pauseSession.complete && continued.kinds == ["intent", "read", "read"]

            let failed = SearchContextTransport(), failedSession = WholeBookSearchSession()
            await failed.configure(failure: true)
            failedSession.prepare(query: "断开", snapshot: .init(project: project), settings: settings); _ = await wait { failedSession.plan != nil }
            failedSession.start(settings: settings, apiKey: "", coordinator: AIRequestCoordinator(transport: { try await failed.handle($0) }), concurrency: 2)
            _ = await started(failed, kind: "read"); await failed.release(); _ = await wait { !failedSession.running }
            checks["DisconnectedFirstBatchIsPausedWithoutBeingRead"] = failedSession.completedBatches == 0 && !failedSession.errorMessage.isEmpty && failedSession.statusDescription.contains("已暂停")

            let obsolete = SearchContextTransport(), oldSession = WholeBookSearchSession()
            oldSession.prepare(query: "旧查询", snapshot: .init(project: project), settings: settings); _ = await wait { oldSession.plan != nil }
            oldSession.start(settings: settings, apiKey: "", coordinator: AIRequestCoordinator(transport: { try await obsolete.handle($0) }), concurrency: 2)
            _ = await started(obsolete, kind: "read"); oldSession.prepare(query: "新查询", snapshot: .init(project: project), settings: settings)
            await obsolete.release(); _ = await wait { oldSession.plan != nil }; await settle(100)
            checks["NewQueryRejectsOldProgressResultAndCost"] = oldSession.plan?.query == "新查询" && oldSession.tokenCost == 0 && oldSession.requestProgress == nil && oldSession.matches.isEmpty && oldSession.activeBatchNumber == 0

            let chat = SearchContextTransport(); await chat.configure(chat: true)
            let store = AppStore(sharedAIRequests: AIRequestCoordinator(transport: { try await chat.handle($0) }))
            store.libraryRootURL = library; store.repository = repository; store.books = [project]; store.bookID = project.id
            store.selectedUnitID = "p92"; store.queryScope = .page; store.queryMemoryEnabled = false
            store.queryInteractionMode = .reading; store.settings = settings
            store.ask("这页讲啥")
            checks["ActualAppStoreQuestionReachesTransport"] = await started(chat, kind: "chat")
            store.selectedUnitID = "p93"
            await chat.release(); _ = await wait { !store.isQueryBusy }
            let chatState = await chat.state(), answer = store.book?.chats.last
            checks["PageQuestionAndCorrectionBothContainFrozenPageOnly"] = chatState.kinds == ["chat", "chat"] && chatState.page && chatState.adjacent && chatState.streamed
            checks["PageCitationCorrectionSucceedsWithoutRetryError"] = store.errorMessage == nil && store.queryRetryQuestion == nil && store.queryDisclosure.contains("补核")
            checks["NavigationDuringRequestCannotChangeAnswerPage"] = answer?.role == "assistant" && answer?.evidence.map(\.unitID) == ["p92"] && answer?.readingContext?.unitIDs == ["p92"]
            checks["PageQuestionKeepsPrivateNotesAndHistoryOutOfPrompt"] = chatState.safe
            let savedNote = try await repository.readDocument(bookID: project.id, document: note)
            checks["OriginalUnitsAndSavedNotesRemainUnchanged"] = store.book?.units == units && savedNote == "绝不能发送的私人笔记"
            checks["SourceFileBytesRemainUnchanged"] = try Data(contentsOf: source) == bytes
            model.cancel(); pauseSession.cancel(); failedSession.cancel(); oldSession.cancel()
            let passed = checks.values.allSatisfy { $0 }
            try JSONSerialization.data(withJSONObject: ["status": passed ? "passed" : "failed", "checks": checks, "realNetworkRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
            NSApp.terminate(nil)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["status": "failed", "checks": checks, "error": error.localizedDescription], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json")); NSApp.terminate(nil)
        }
    }
}

@main struct SearchContextMain {
    static func main() { let app = NSApplication.shared, runner = SearchContextRunner(URL(fileURLWithPath: CommandLine.arguments[1])); app.delegate = runner; app.setActivationPolicy(.regular); app.run() }
}
