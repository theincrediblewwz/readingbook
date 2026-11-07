import AppKit
import Foundation
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

private actor TraceTransport {
    var requests = 0
    func count() -> Int { requests }
    func perform(_ prepared: ProviderClient.Prepared) throws -> ProviderClient.Result {
        guard prepared.request.url?.host == "127.0.0.1" else { throw ReadingError.invalid("仅允许离线夹具。") }
        requests += 1
        func read(_ id: String) -> ProviderClient.ToolCall {
            .init(id: "call-" + id, type: "function", function: .init(name: "source_read", arguments: "{\"id\":\"" + id + "\"}"))
        }
        if requests <= 2 {
            return .init(message: .init(role: "assistant", content: nil, refusal: nil,
                tool_calls: requests == 1 ? [read("u1"), read("u2")] : [read("outside")],
                reasoning_content: "PRIVATE_REASONING_NOT_FOR_DETAILS"), finishReason: "tool_calls", tokenCost: 100)
        }
        return .init(message: .init(role: "assistant", content: "原文写的是周瑜与黄盖准备火攻。[unit:u1] 后面写曹操向华容道行进。[unit:u2] 未找到的页面没有加入结论。",
            refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
    }
}

@MainActor private final class RequestDetailsHost: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: AppStore!
    var host: NSHostingView<AnyView>!
    var output: URL!
    var checks: [String: Bool] = [:]
    let transport = TraceTransport()
    var inputs: [[String: Any]] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() }
            catch { try? write(status: "failed", error: error.localizedDescription) }
            if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
            NSApp.terminate(nil)
        }
    }
    func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
        checks[name] = try value()
        guard checks[name] == true else { throw ReadingError.invalid("请求详情检查失败：" + name) }
    }
    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 12
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else { throw ReadingError.invalid("请求详情等待超时。") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(80))
    }
    func write(status: String, error: String = "") throws {
        try JSONSerialization.data(withJSONObject: ["status": status, "checks": checks, "error": error,
            "realNetworkRequests": 0, "originalLibraryUsed": false, "inputs": inputs], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"), options: .atomic)
    }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1])
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/"), Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("必须使用隔离环境。") }
        let library = output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1": library.path, "service-profiles": Data("[]".utf8), "query-memory-enabled": false], forName: UserDefaults.argumentDomain)
        var project = BookProject(title: "请求详情 · 离线样例", originalName: "book.txt", sourceHash: "fixture", units: [
            .init(id: "u1", order: 0, chapter: "一", page: 602, text: "周瑜与黄盖准备火攻。"),
            .init(id: "u2", order: 1, chapter: "二", page: 620, text: "曹操向华容道行进。")])
        PluginEngine.seed(&project)
        let source = output.appendingPathComponent("book.txt"), bytes = Data(project.units.map(\.text).joined(separator: "\n").utf8)
        try bytes.write(to: source); project.sourceHash = try BookImporter.sha256(bytes)
        let repository = LibraryRepository(rootURL: library)
        project = try await repository.create(project, sourceURL: source)
        let transport = transport
        store = AppStore(sharedAIRequests: AIRequestCoordinator(transport: { try await transport.perform($0) }))
        store.libraryRootURL = library; store.repository = repository; store.books = [project]; store.bookID = project.id; store.selectedUnitID = "u1"
        store.settings = .init(baseURL: "http://127.0.0.1/offline", model: "offline-fixture", maxRequestsPerRun: 4, maxOutputTokens: 1000, contextWindowTokens: 128_000)
        store.apiKey = "LOCAL_ONLY_HEADER_KEY"; store.queryScope = .book; store.queryMemoryEnabled = false
        window = NSWindow(contentRect: .init(x: 100, y: 80, width: 850, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ReadingBook 请求详情 · 离线检查"; window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(AIRequestHistoryView(state: store.queryProgressState).environmentObject(store)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        store.ask("请解释这段中的行动先后。")
        try await wait { !self.store.isQueryBusy && self.store.pendingAIHistoryWrites == 0 }
        let state = store.queryProgressState.value
        let requestCount = await transport.count()
        try check("threeRequestsWereExecuted", requestCount == 3)
        try check("questionCompletedWithoutRetry", store.queryRetryQuestion == nil && state.status == .completed)
        try check("everyRequestHasActualInput", state.requests.count == 3 && state.requests.allSatisfy { $0.trace != nil })
        try check("requestNumbersRemainIndependent", state.requests.map(\.number) == [1, 2, 3])
        try check("eachToolHasItsOwnTrace", state.toolSteps.count == 3 && state.toolSteps.allSatisfy { $0.trace != nil })
        try check("twoReadsAndOneFailureKeepTheirCounts", state.completedTools == 2 && state.failedTools == 1)
        try check("firstSourceIsExact", state.toolSteps[0].trace?.fragments.first?.text == project.units[0].text)
        try check("secondSourceIsExact", state.toolSteps[1].trace?.fragments.first?.text == project.units[1].text)
        try check("locatorIsVisible", state.toolSteps[0].trace?.fragments.first?.title.contains("602") == true)
        try check("failedReadDoesNotInventSource", state.toolSteps[2].trace?.fragments.isEmpty == true && state.toolSteps[2].trace?.result.text.contains("冻结范围") == true)
        let input = state.requests.compactMap(\.trace).flatMap(\.messages).map { $0.content.text }.joined()
        try check("actualQuestionCanBeInspected", input.contains("请解释这段中的行动先后。"))
        try check("returnedSourceWasSentToNextRequest", input.contains(project.units[1].text))
        try check("headersAreNotExposed", !input.contains("LOCAL_ONLY_HEADER_KEY") && !input.contains("Authorization"))
        try check("privateReasoningIsNotExposed", !input.contains("PRIVATE_REASONING"))
        let stored = try await repository.loadAll().first!
        let encoded = String(decoding: try JSONEncoder().encode(stored.aiRequestHistory), as: UTF8.self)
        try check("durableHistoryStillStoresOnlyMetadata", !encoded.contains("火攻") && !encoded.contains("华容道") && !encoded.contains("trace"))
        try check("sourceAndAnswerArePreserved", stored.units == project.units && stored.chats.filter { $0.role == "assistant" }.count == 1 && (try Data(contentsOf: source)) == bytes)

        var large = AIProgressPresentationState(); large.status = .running; large.startedAt = Date()
        let largePrepared = try ProviderClient.prepare(messages: (0..<4).map { ["role": "user", "content": String(repeating: "字", count: 22_000) + String($0)] }, tools: [],
            settings: .init(model: "offline", maxOutputTokens: 1000, contextWindowTokens: 1_000_000), apiKey: "", remainingTokens: 1_000_000)
        let trace = try require(AIRequestTrace.capture(largePrepared))
        for number in 1...12 { large.apply(.init(.waitingForResponse, requestID: UUID(), requestNumber: number, requestTrace: trace)) }
        try check("requestTextHasBoundedRetention", large.requests.reduce(0) { $0 + ($1.trace?.retainedBytes ?? 0) } <= 2 * 1024 * 1024)
        try check("evictionKeepsRequestNumbers", large.requests.map(\.number) == Array(1...12) && large.requests.contains { $0.traceExpired })
        let tool = AIToolTrace(arguments: "{}", result: "{\"text\":\"" + String(repeating: "原文", count: 4500) + "\",\"locator\":\"测试页\"}")
        for _ in 0..<48 {
            large.apply(.init(.performingTool, toolName: "source_read"))
            large.apply(.init(.toolCompleted, toolName: "source_read", toolSucceeded: true, toolTrace: tool))
        }
        try check("combinedToolAndRequestTextIsBounded", large.requests.reduce(0) { $0 + ($1.trace?.retainedBytes ?? 0) } + large.toolSteps.reduce(0) { $0 + ($1.trace?.retainedBytes ?? 0) } <= 2 * 1024 * 1024)
        try check("toolTextEvictionKeepsEveryOperationStatus", large.toolSteps.count == 48 && large.completedTools == 48 && large.toolSteps.contains { $0.traceExpired })
        try check("readNamesAreSpecific", AIProgressPresentationState.toolTitle("capabilities_list") == "查看可用功能与参数" && AIProgressPresentationState.toolTitle("objects_search") == "查找已保存的要素")
        try await press("展开第 1 次请求")
        try await wait { self.labels().contains("展开发给模型的文字") }
        try check("requestDetailsCanExpandThroughActualInput", labels().contains("展开发给模型的文字"))
        try await press("展开阅读原文片段")
        try await wait { self.labels().contains(where: { $0.contains(project.units[0].text) }) }
        try check("sourceToolCanExpandThroughActualInput", labels().contains("收起阅读原文片段"))
        try check("sourceTextIsRenderedInExpandedRow", labels().contains { $0.contains("第 602 页") } && labels().contains { $0.contains(project.units[0].text) })
        try await press("展开发给模型的文字")
        try await wait { self.labels().filter { $0 == "展开问题与已分享资料" }.count == 2 }
        try check("requestInputCanExpandThroughActualInput", labels().filter { $0 == "展开问题与已分享资料" }.count == 2)
        try await press("展开问题与已分享资料", occurrence: 1)
        try await wait { self.labels().contains("请解释这段中的行动先后。") }
        try check("actualQuestionTextIsRendered", labels().contains("请解释这段中的行动先后。"))
        try await press("收起发给模型的文字")
        try await press("收起阅读原文片段")
        try await wait { !self.labels().contains(where: { $0.contains(project.units[0].text) }) }
        try check("sourceRowCanCollapseAgain", !labels().contains { $0.contains(project.units[0].text) })
        try write(status: "passed")
        if CommandLine.arguments.contains("--inspect") {
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path) { try await Task.sleep(for: .milliseconds(100)) }
        }
        window.close()
    }
    func read(_ value: NSObject, _ key: String) -> Any? {
        let selector = NSSelectorFromString(key)
        guard value.responds(to: selector) else { return nil }
        return value.perform(selector)?.takeUnretainedValue()
    }
    func objects() -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func walk(_ value: NSObject, _ depth: Int) {
            guard depth < 40, seen.insert(ObjectIdentifier(value)).inserted else { return }
            result.append(value)
            for child in self.read(value, "accessibilityChildren") as? [NSObject] ?? [] { walk(child, depth + 1) }
            if let view = value as? NSView { for child in view.subviews { walk(child, depth + 1) } }
        }
        walk(host, 0); return result
    }
    func labels() -> [String] {
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        return objects().flatMap { object in ["accessibilityLabel", "accessibilityValue"].compactMap { read(object, $0) as? String } }
    }
    func press(_ label: String, occurrence: Int = 0) async throws {
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let matches = objects().filter { read($0, "accessibilityLabel") as? String == label }
        guard matches.indices.contains(occurrence), matches[occurrence].responds(to: NSSelectorFromString("accessibilityFrame")),
              let rect = (matches[occurrence].value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
              rect.width > 0, rect.height > 0 else { throw ReadingError.invalid("没有取得真实按钮边界：" + label) }
        let point = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
        let local = host.superview?.convert(point, from: nil) ?? point
        guard let receiver = host.hitTest(local) else { throw ReadingError.invalid("按钮未命中实际窗口：" + label) }
        inputs.append(["label": label, "occurrence": occurrence, "frame": NSStringFromRect(rect), "receiver": String(describing: type(of: receiver)), "input": "Own application event queue, not OS post"])
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { throw ReadingError.invalid("无法建立窗口内事件。") }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(40))
    }
    func require<T>(_ value: T?) throws -> T { guard let value else { throw ReadingError.invalid("离线文字未捕获。") }; return value }
}
@main private enum Main { static func main() { let app = NSApplication.shared, delegate = RequestDetailsHost(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {} } }
