import AppKit
import Foundation
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

private actor Transport {
    var requests = 0
    func count() -> Int { requests }
    func perform(_ request: ProviderClient.Prepared) throws -> ProviderClient.Result {
        guard request.request.url?.host == "127.0.0.1", request.request.value(forHTTPHeaderField: "Authorization") == nil else { throw ReadingError.invalid("只能使用离线传输。") }
        requests += 1
        return .init(message: .init(role: "assistant", content: "刘备与关羽同行。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 50)
    }
}
@MainActor private final class Host: NSObject, NSApplicationDelegate {
    let transport = Transport()
    var output: URL!
    var store: AppStore!
    var window: NSWindow!
    var checks: [String: Bool] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try finish(nil) } catch { try? finish(error) }
            NSApp.terminate(nil)
        }
    }
    func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
        checks[name] = try value()
        if checks[name] != true { throw ReadingError.invalid("任务额度检查失败：" + name) }
    }
    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else { throw ReadingError.invalid("原生任务等待超时。") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
    }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/"), Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("需要隔离环境。") }
        let library = output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1": library.path, "service-profiles": Data("[]".utf8), "query-memory-enabled": false], forName: UserDefaults.argumentDomain)
        var project = BookProject(title: "任务额度 · 合成书", originalName: "book.txt", sourceHash: "fixture", units: [.init(id: "u1", order: 0, chapter: "一", page: 1, text: "刘备与关羽同行。"), .init(id: "u2", order: 1, chapter: "后文", page: 2, text: "未读页秘密。")])
        PluginEngine.seed(&project)
        let source = output.appendingPathComponent("book.txt"), bytes = Data(project.units.map(\.text).joined(separator: "\n").utf8)
        try bytes.write(to: source); project.sourceHash = try BookImporter.sha256(bytes)
        let repository = LibraryRepository(rootURL: library)
        project = try await repository.create(project, sourceURL: source)
        let transport = transport
        store = AppStore(sharedAIRequests: AIRequestCoordinator(transport: { try await transport.perform($0) }))
        store.libraryRootURL = library; store.repository = repository; store.books = [project]; store.bookID = project.id; store.selectedUnitID = "u1"; store.route = "reader"
        store.settings = .init(baseURL: "http://127.0.0.1:1/offline", model: "fixture", maxRequestsPerRun: 2, maxOutputTokens: 512, contextWindowTokens: 128_000)
        store.apiKey = ""; store.queryMemoryEnabled = false; store.queryScope = .page
        window = NSWindow(contentRect: .init(x: 80, y: 70, width: 1100, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ReadingBook 独立任务额度 · 隔离回归"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings()))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let background = await store.beginAIProgress(title: "后台阅读额度", backgroundReading: true, settings: store.settings)
        await store.readingReader.resetBudget()
        for _ in 0..<2 {
            _ = try await store.readingReader.answer(question: "后台核对", project: project, settings: store.settings, apiKey: "", readingContext: .init(unitID: "u1", page: 1), queryScope: .page, memoryEnabled: false)
        }
        let initial = await transport.count()
        try check("backgroundReachedOwnTwoRequestLimit", initial == 2)
        try check("backgroundRunStillActive", store.aiProgress.isRunning)
        for index in 1...3 {
            store.ask("第\(index)次独立提问：这页讲什么？")
            try check("question\(index)Started", store.isQueryBusy)
            try await wait { !self.store.isQueryBusy }
            try check("question\(index)CompletedWithoutRetry", store.errorMessage == nil && store.queryRetryQuestion == nil)
            try check("question\(index)HasVerifiedSource", store.book?.chats.last?.evidence.first?.unitID == "u1")
            try check("question\(index)RequestNumberStartsAtOne", store.queryProgressState.value.requests.map(\.number) == [1])
        }
        let beforeExtra = await transport.count()
        try check("allFiveRequestsActuallyReachedTransport", beforeExtra == 5)
        try check("bookKeepsAllThreeQuestionsAndAnswers", store.book?.chats.count == 6)
        let backgroundCount = await store.readingReader.requestCount
        try check("backgroundRequestCountStillTwo", backgroundCount == 2)
        do {
            _ = try await store.readingReader.answer(question: "后台超额", project: project, settings: store.settings, apiKey: "", readingContext: .init(unitID: "u1", page: 1), queryScope: .page, memoryEnabled: false)
            try check("questionsDidNotResetBackgroundBudget", false)
        } catch { try check("questionsDidNotResetBackgroundBudget", error is ReadingWorkflowBudgetPause || error.localizedDescription == "本轮问答请求预算已用完。") }
        let afterExtra = await transport.count()
        try check("overBudgetBackgroundDidNotSendAgain", afterExtra == beforeExtra)
        store.finishAIProgress(background)
        try check("backgroundCanFinishNormally", !store.aiProgress.isRunning)
        let loaded = try await repository.loadAll().first!
        try check("answersSurviveRepositoryReload", loaded.chats.count == 6 && loaded.chats.filter { $0.role == "assistant" }.allSatisfy { $0.evidence.first?.unitID == "u1" })
        try check("sourceAndUnreadPagePreserved", loaded.units == project.units && (try Data(contentsOf: source)) == bytes)
        window.close()
    }
    func finish(_ error: Error?) throws {
        let result: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error?.localizedDescription ?? "", "checks": checks, "realNetworkRequests": 0, "originalLibraryUsed": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    }
}
@main private struct Main: App {
    @NSApplicationDelegateAdaptor(Host.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}
