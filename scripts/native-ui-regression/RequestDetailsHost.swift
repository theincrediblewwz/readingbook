import AppKit
import Foundation
import SwiftUI
import Vision
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
    var rasterRows: [(String, CGRect)] = []
    var rasterAt = 0.0
    var rasterImage: CGImage?
    var rasterCaptureCount = 0
    var forceRaster: Bool { CommandLine.arguments.contains("--raster-observation") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() }
            catch { captureState("failed-details-state"); try? write(status: "failed", error: error.localizedDescription) }
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
            "realNetworkRequests": 0, "originalLibraryUsed": false, "inputs": inputs,
            "rasterCaptureCount": rasterCaptureCount, "forcedRasterObservation": forceRaster,
            "observation": "Actual native AX or rendered pixels and button bounds; never invoke product action closures"], options: [.prettyPrinted, .sortedKeys])
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
        try check("everyRequestHasPublicResponse", state.requests.allSatisfy { $0.response != nil })
        try check("responseToolsRemainSeparateFromExecution", state.requests[0].response?.toolCalls.count == 2 && state.toolSteps.filter { $0.requestID == state.requests[0].id }.count == 2)
        try check("actualFinalReplyIsRetained", state.requests.last?.response?.content?.text == store.book?.chats.last?.content)
        try check("responseDoesNotExposePrivateReasoning", !String(reflecting: state.requests.compactMap(\.response)).contains("PRIVATE_REASONING"))
        let stored = try await repository.loadAll().first!
        let encoded = String(decoding: try JSONEncoder().encode(stored.aiRequestHistory), as: UTF8.self)
        try check("durableHistoryStillStoresOnlyMetadata", !encoded.contains("火攻") && !encoded.contains("华容道") && !encoded.contains("trace"))
        try check("sourceAndAnswerArePreserved", stored.units == project.units && stored.chats.filter { $0.role == "assistant" }.count == 1 && (try Data(contentsOf: source)) == bytes)

        var large = AIProgressPresentationState(); large.status = .running; large.startedAt = Date()
        let largePrepared = try ProviderClient.prepare(messages: (0..<4).map { ["role": "user", "content": String(repeating: "字", count: 22_000) + String($0)] }, tools: [],
            settings: .init(model: "offline", maxOutputTokens: 1000, contextWindowTokens: 1_000_000), apiKey: "", remainingTokens: 1_000_000)
        let trace = try require(AIRequestTrace.capture(largePrepared))
        let response = AIResponseTrace.capture(.init(message: .init(role: "assistant", content: String(repeating: "公开返回", count: 20000), refusal: nil, tool_calls: nil, reasoning_content: "PRIVATE_REASONING"), finishReason: "stop", tokenCost: 10))
        for number in 1...12 {
            let id = UUID()
            large.apply(.init(.waitingForResponse, requestID: id, requestNumber: number, requestTrace: trace))
            large.apply(.init(.requestCompleted, requestID: id, requestNumber: number, responseTrace: response))
        }
        try check("requestTextHasBoundedRetention", large.requests.reduce(0) { $0 + ($1.trace?.retainedBytes ?? 0) + ($1.response?.retainedBytes ?? 0) } <= 2 * 1024 * 1024)
        try check("evictionKeepsRequestNumbers", large.requests.map(\.number) == Array(1...12) && large.requests.contains { $0.traceExpired })
        let tool = AIToolTrace(arguments: "{}", result: "{\"text\":\"" + String(repeating: "原文", count: 4500) + "\",\"locator\":\"测试页\"}")
        for _ in 0..<48 {
            large.apply(.init(.performingTool, toolName: "source_read"))
            large.apply(.init(.toolCompleted, toolName: "source_read", toolSucceeded: true, toolTrace: tool))
        }
        try check("combinedToolAndRequestTextIsBounded", large.requests.reduce(0) { $0 + ($1.trace?.retainedBytes ?? 0) + ($1.response?.retainedBytes ?? 0) } + large.toolSteps.reduce(0) { $0 + ($1.trace?.retainedBytes ?? 0) } <= 2 * 1024 * 1024)
        try check("toolTextEvictionKeepsEveryOperationStatus", large.toolSteps.count == 48 && large.completedTools == 48 && large.toolSteps.contains { $0.traceExpired })
        try check("readNamesAreSpecific", AIProgressPresentationState.toolTitle("capabilities_list") == "查看可用功能与参数" && AIProgressPresentationState.toolTitle("objects_search") == "查找已保存的要素")
        try await press("查看第 1 次请求")
        try await wait { self.hasText("2 项操作请求") }
        try check("requestDetailsCanExpandThroughActualInput", hasText("发送给 AI") && hasText("2 项操作请求"))
        try await press("展开阅读原文片段")
        try await wait { self.hasText(project.units[0].text) }
        try check("sourceToolCanExpandThroughActualInput", hasText(project.units[0].text))
        try check("sourceTextIsRenderedInExpandedRow", hasText("第 602 页") && hasText(project.units[0].text))
        try await press("收起阅读原文片段")
        try await wait { !self.hasText(project.units[0].text) }
        try check("sourceRowCanCollapseAgain", !hasText(project.units[0].text))
        try await press("展开发送给 AI")
        try await wait { self.visibleButtons("问题与已分享资料").count == 2 }
        try check("requestInputCanExpandThroughActualInput", visibleButtons("问题与已分享资料").count == 2)
        try await press("展开问题与已分享资料", occurrence: 1)
        try await wait { self.hasText("请解释这段中的行动先后。") }
        try check("actualQuestionTextIsRendered", hasText("请解释这段中的行动先后。"))
        try await press("收起发送给 AI")
        try await press("查看第 3 次请求")
        try await press("展开AI 返回")
        try await wait { self.hasText("未找到的页面没有加入结论") }
        try check("publicReplyCanExpandThroughActualInput", hasText("未找到的页面没有加入结论"))
        let ownerFrame = window.frame
        store.showAIRequestHistory(store.queryProgressState)
        try await wait { NSApp.windows.contains { $0.title == "请求记录与详情" && $0.isVisible && $0 !== self.window } }
        let separate = try require(NSApp.windows.first { $0.title == "请求记录与详情" && $0.isVisible && $0 !== self.window })
        try check("detailsUsesIndependentModelessWindow", separate !== window && window.attachedSheet == nil)
        try check("openingDetailsPreservesOwnerFrame", window.frame == ownerFrame)
        separate.setFrameOrigin(NSPoint(x: separate.frame.minX + 20, y: separate.frame.minY + 10))
        try check("movingDetailsPreservesOwnerFrame", window.frame == ownerFrame)
        store.requestHistoryWindow?.close()
        try await wait { self.store.requestHistoryWindow == nil }
        try check("closingDetailsKeepsTaskAndAnswer", store.queryProgressState.value == state && store.book?.chats.last?.role == "assistant")
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
        return forceRaster ? [] : objects().flatMap { object in ["accessibilityLabel", "accessibilityValue"].compactMap { read(object, $0) as? String } }
    }
    func comparable(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    func recognize(_ image: CGImage) -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { result in
            guard let text = result.topCandidates(1).first?.string else { return nil }
            return (text, result.boundingBox)
        }
    }
    func refreshRaster() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - rasterAt >= 0.12 else { return }
        rasterAt = now; rasterRows = []; rasterImage = nil; rasterCaptureCount += 1
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let original = bitmap.cgImage else { return }
        let image: CGImage
        if CGFloat(original.width) < host.bounds.width * 2,
           let context = CGContext(data: nil, width: Int(host.bounds.width * 2), height: Int(host.bounds.height * 2),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(original, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            image = context.makeImage() ?? original
        } else { image = original }
        rasterImage = image
        rasterRows = recognize(image).map { text, box in
            (text, CGRect(x: box.minX * host.bounds.width, y: (host.isFlipped ? 1 - box.maxY : box.minY) * host.bounds.height,
                width: box.width * host.bounds.width, height: box.height * host.bounds.height))
        }
    }
    func hasText(_ text: String) -> Bool {
        let needle = comparable(text)
        if labels().contains(where: { comparable($0).contains(needle) }) { return true }
        refreshRaster()
        return rasterRows.contains { comparable($0.0).contains(needle) }
    }
    func visibleButtons(_ title: String) -> [CGRect] {
        refreshRaster()
        guard let image = rasterImage else { return [] }
        var frames: [CGRect] = []
        // Use the actual native focus/button view bounds and text from its
        // pixels. This is the same fallback as the existing graph UI probe;
        // no product state or expected body text supplies the hit location.
        for view in objects().compactMap({ $0 as? NSView }) where !view.isHiddenOrHasHiddenAncestor
                && String(describing: type(of: view)).contains("FocusRing")
                && view.bounds.height >= 28 && view.bounds.height <= 80 && view.bounds.width > 100 {
            let frame = view.convert(view.bounds, to: host)
            guard host.bounds.contains(frame), view.visibleRect.height >= view.bounds.height - 1,
                  !frames.contains(frame) else { continue }
            let sx = CGFloat(image.width) / host.bounds.width, sy = CGFloat(image.height) / host.bounds.height
            let crop = CGRect(x: frame.minX * sx, y: (host.isFlipped ? frame.minY : host.bounds.height - frame.maxY) * sy,
                width: frame.width * sx, height: frame.height * sy).integral
            guard let clipped = image.cropping(to: crop) else { continue }
            if recognize(clipped).contains(where: { comparable($0.0).contains(comparable(title)) }) { frames.append(frame) }
        }
        return frames.sorted { host.isFlipped ? $0.minY < $1.minY : $0.maxY > $1.maxY }
    }
    func captureState(_ stage: String) {
        guard let host, let window, let output else { return }
        let rows = objects().map { object -> [String: Any] in
            var row: [String: Any] = ["class": String(describing: type(of: object))]
            for key in ["accessibilityLabel", "accessibilityValue", "accessibilityRole"] {
                if let value = read(object, key) as? String { row[key] = value }
            }
            if object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let frame = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
                row["frame"] = NSStringFromRect(frame)
            }
            if let view = object as? NSView {
                row["bounds"] = NSStringFromRect(view.bounds)
                row["hidden"] = view.isHiddenOrHasHiddenAncestor
            }
            return row
        }
        let state: [String: Any] = ["visible": window.isVisible, "key": window.isKeyWindow,
            "hostBounds": NSStringFromRect(host.bounds), "rows": rows]
        try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(stage + ".json"))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: output.appendingPathComponent(stage + ".png"))
            }
        }
    }
    func press(_ label: String, occurrence: Int = 0) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        var ready: CGRect?
        repeat {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let matches = forceRaster ? [] : objects().filter { read($0, "accessibilityLabel") as? String == label }
            if matches.indices.contains(occurrence), matches[occurrence].responds(to: NSSelectorFromString("accessibilityFrame")),
               let rect = (matches[occurrence].value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
               rect.width > 0, rect.height > 0 { ready = rect; break }
            var title = label.hasPrefix("展开") || label.hasPrefix("收起") ? String(label.dropFirst(2)) : label
            if label.hasPrefix("查看第 "), label.hasSuffix(" 次请求") { title = "请求 " + label.replacingOccurrences(of: "查看第 ", with: "").replacingOccurrences(of: " 次请求", with: "") }
            let frames = visibleButtons(title)
            if frames.indices.contains(occurrence) { ready = window.convertToScreen(host.convert(frames[occurrence], to: nil)); break }
            try await Task.sleep(for: .milliseconds(30))
        } while ProcessInfo.processInfo.systemUptime - started < 1.5
        guard let rect = ready else { throw ReadingError.invalid("没有取得真实按钮边界：" + label) }
        let point = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
        let local = host.superview?.convert(point, from: nil) ?? point
        guard let receiver = host.hitTest(local) else { throw ReadingError.invalid("按钮未命中实际窗口：" + label) }
        inputs.append(["label": label, "occurrence": occurrence, "frame": NSStringFromRect(rect), "readyAfterMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
            "receiver": String(describing: type(of: receiver)), "input": "Own application event queue, not OS post"])
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { throw ReadingError.invalid("无法建立窗口内事件。") }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(40))
        rasterAt = 0
    }
    func require<T>(_ value: T?) throws -> T { guard let value else { throw ReadingError.invalid("离线文字未捕获。") }; return value }
}
@main private enum Main { static func main() { let app = NSApplication.shared, delegate = RequestDetailsHost(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {} } }
