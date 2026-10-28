import AppKit
import SwiftUI
import Foundation
import CryptoKit
import Darwin
@testable import ReadingBook
@testable import ReadingCore

private func fixtureSHA256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// A normal native window containing the real workspace. All model replies are
/// in-memory fixtures; the installed app, its preferences and its library stay out.
private actor OfflineUITransport {
    struct Snapshot: Sendable {
        let companionRequests: Int; let chatRequests: Int; let connectionTests: Int
        let held: Bool; let waiting: Int
        let longNextCompanion: Bool; let longCompanionReplies: Int
        let longReplySHA256: String; let longReplyMarkdown: String; let longReplyLayerID: String
    }
    private var held = true
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var companionRequests = 0, chatRequests = 0, connectionTests = 0
    private var longNextCompanion = false, longCompanionReplies = 0
    private var longReplySHA256 = "", longReplyMarkdown = "", longReplyLayerID = ""
    func snapshot() -> Snapshot { .init(companionRequests: companionRequests, chatRequests: chatRequests,
        connectionTests: connectionTests, held: held, waiting: waiters.count,
        longNextCompanion: longNextCompanion, longCompanionReplies: longCompanionReplies,
        longReplySHA256: longReplySHA256, longReplyMarkdown: longReplyMarkdown, longReplyLayerID: longReplyLayerID) }
    func useLongNextCompanion() { longNextCompanion = true }
    func hold() { held = true }
    func release() {
        held = false
        let pending = Array(waiters.values); waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func wait() async throws {
        guard held else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in waiters[id] = continuation }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    func connection(_ settings: ProviderSettings, _ key: String) throws -> String {
        try validate(URL(string: settings.baseURL), key: key)
        connectionTests += 1
        return "离线连接正常；没有网络请求。"
    }
    private func validate(_ url: URL?, key: String = "") throws {
        guard url?.scheme == "http", url?.host == "127.0.0.1", url?.port == 1, key.isEmpty else {
            throw ReadingError.invalid("离线 UI 仅接受无密钥的 127.0.0.1:1 测试配置；未发送网络请求。")
        }
    }
    func perform(_ request: ProviderClient.Prepared) async throws -> ProviderClient.Result {
        try validate(request.request.url)
        guard request.request.value(forHTTPHeaderField: "Authorization") == nil,
              let body = request.request.httpBody,
              let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ReadingError.invalid("离线 UI 请求不符合隔离配置。")
        }
        let tools = payload["tools"] as? [[String: Any]] ?? []
        if tools.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == "reading_enrich" }) {
            companionRequests += 1
            let number = companionRequests
            // Freeze/consume before waiting. Arming the control while an older
            // response is suspended affects the next generation, never that one.
            let long = longNextCompanion; longNextCompanion = false
            let markdown = long ? Self.longCompanionMarkdown : "这句话说刘备就在这里。此回答来自内存 fixture，没有调用模型。"
            if long {
                longReplySHA256 = fixtureSHA256(markdown); longReplyMarkdown = markdown
                longReplyLayerID = "offline-generated-\(number)"
            }
            try await wait(); try Task.checkCancellation()
            if long { longCompanionReplies += 1 }
            let anchors: [[String: Any]] = long ? [
                ["id": "reply-liu", "unitID": "u1", "quote": "刘备在此。"],
                ["id": "reply-guan", "unitID": "u1", "quote": "关羽随后而来。"]
            ] : [["id": "reply-focus", "unitID": "u1", "quote": "刘备在此。"]]
            return try tool("reading_enrich", arguments: [
                "anchors": anchors,
                "layers": [["id": "offline-generated-\(number)", "kind": "explanation", "title": "最新离线回答 \(number)",
                    "markdown": markdown, "sourceAnchorIDs": long ? ["reply-liu", "reply-guan"] : ["reply-focus"], "sourceLabel": "离线 AI fixture"]]
            ], id: "companion-\(number)")
        }
        guard !tools.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == "reading_plan" }) else {
            throw ReadingError.invalid("本 UI fixture 只覆盖伴读与对话；未发送预读请求。")
        }
        chatRequests += 1
        // Inspect only the current request chain, after its latest user message.
        // Historical source_read calls must not skip this question's real tool path.
        let messages = payload["messages"] as? [[String: Any]] ?? []
        let latestUser = messages.lastIndex { $0["role"] as? String == "user" } ?? -1
        let hasRead = messages.dropFirst(latestUser + 1).contains { $0["role"] as? String == "tool" }
        if hasRead {
            return .init(message: .init(role: "assistant", content: "原文说“刘备在此”，因此在这里的人是刘备。[unit:u1]\n\n这条对话已完成，伴读仍可独立等待。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 12)
        }
        return try tool("source_read", arguments: ["id": "u1"], id: "chat-read-\(chatRequests)")
    }
    private func tool(_ name: String, arguments: [String: Any], id: String) throws -> ProviderClient.Result {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return .init(message: .init(role: "assistant", content: nil, refusal: nil,
            tool_calls: [.init(id: id, type: "function", function: .init(name: name, arguments: json))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 12)
    }
    private static let longCompanionMarkdown: String = #"""
    # 两句原文，一条完整说明

    原文分别是「刘备在此。」与「关羽随后而来。」。这是一条离线长回答，用来核对伴读的短预览、展开全文、完整复制和记入笔记；不补充真实书外史实。

    ## 两个来源各自说明什么

    | 来源 | 直接读到的内容 | 不应额外推断的内容 |
    | --- | --- | --- |
    | 刘备在此。 | 刘备在这里。 | 具体地点、日期、原因。 |
    | 关羽随后而来。 | 关羽随后到来。 | 路线、时长、此前经历。 |

    「随后」表达两件事的相对先后。若将这个关系抽象为排版演示，可以写作 $t_{\text{刘备}} < t_{\text{关羽}}$。这个式子只是显示测试，不是原书提供的数值信息。

    $$
    \begin{aligned}
    \Delta t &= t_{\text{关羽}} - t_{\text{刘备}} \\
    \Delta t &> 0
    \end{aligned}
    $$

    原文只支持先后关系，不支持算出具体的 $\Delta t$。复制或存为草稿时，应保留这些数学定界符、反斜线和表格，而不只保留屏幕上被截短的预览。

    原文定位：[返回本段原文](readingbook://book/11111111-2222-4333-8444-555555555555/unit/u1)。这条链接只指向本地离线 fixture。
    """# + (1...8).map { number in
        """


        ## 核对段落 \(number)

        这一段继续围绕同样的两句原文展开。刘备这一句确认了人物与当前场景的关系，关羽这一句增加了后来到达的动作。两条来源需要分别保留，点击来源时应能明确选择其中一条，而不是把两个不同的句子合成一个不可核对的出处。长回答的正文也不应因为预览收起而改变。

        阅读时可以先看简短结论，再按需要展开完整说明。展开和收起只是显示方式，不应触发再次请求，也不应删除已经保存的文字。复制全文应包含后面的段落，记入笔记则应把完整 Markdown 放进真实编辑草稿，在主动保存以前不覆盖已经保存的用户笔记。这里特意保留了编号 \(number)、标点、换行与中文，引导检查首尾是否完整。
        """
    }.joined() + #"""


    ## 全文末尾核验

    末尾标记：**OFFLINE-LONG-COMPANION-END**。如果复制内容或笔记草稿中能找到这个标记，并且公式、表格和两个来源都仍然完整，就能排除只复制/保存短预览的回归。
    """#
}

@MainActor private final class OfflineUIRunner: NSObject, NSApplicationDelegate {
    let output: URL, width: CGFloat, height: CGFloat
    let transport = OfflineUITransport()
    let bookID = "11111111-2222-4333-8444-555555555555"
    let note = DocumentRecord(id: "offline-user-note", title: "离线保留笔记")
    let sourceBytes = Data("刘备在此。\n\n关羽随后而来。".utf8)
    let noteBody = "# 离线保留笔记\n\n此笔记必须保留。e\u{301}、🙂、$x^2$。\n"
    var store: AppStore!, window: NSWindow!, timer: Timer?
    var polling = false, chatFinishedDuringCompanion = false
    private var writtenLongReplySHA256 = ""
    private var draftCheckpointStatus = "not-requested"
    private var terminationDraftCaptured = false
    private var keyboardSaveCount = 0
    init(output: URL, width: CGFloat, height: CGFloat) { self.output = output; self.width = width; self.height = height }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await start() } }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if !terminationDraftCaptured, store != nil { terminationDraftCaptured = checkpointDraft(reason: "application-termination") }
        UserDefaults.standard.removePersistentDomain(forName: "org.readingbook.ui-concurrency-test")
    }
    private func installMenus() {
        let menu = NSMenu()
        let application = NSMenuItem(); let applicationMenu = NSMenu(title: "ReadingBook 离线测试")
        applicationMenu.addItem(withTitle: "退出离线测试", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = applicationMenu; menu.addItem(application)
        let file = NSMenuItem(); let fileMenu = NSMenu(title: "文件")
        let save = fileMenu.addItem(withTitle: "保存文档", action: #selector(saveFromKeyboard(_:)), keyEquivalent: "s")
        save.target = self; file.submenu = fileMenu; menu.addItem(file)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let item = editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
            if selector == "redo:" { item.keyEquivalentModifierMask = [.command, .shift] }
        }
        edit.submenu = editMenu; menu.addItem(edit)
        NSApp.mainMenu = menu
    }
    @objc private func saveFromKeyboard(_ sender: Any?) {
        keyboardSaveCount += 1
        Task { @MainActor in await store.saveCurrentDocument(); await snapshot() }
    }
    private func write(_ name: String, _ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent(name), options: .atomic)
        }
    }
    private func start() async {
        do {
            let library = output.appendingPathComponent("library", isDirectory: true)
            let source = output.appendingPathComponent("fixture.txt")
            try sourceBytes.write(to: source)
            var project = BookProject(id: bookID, title: "离线测试：伴读与对话并发", originalName: "fixture.txt", sourceHash: try BookImporter.sha256(sourceBytes), units: [
                SourceUnit(id: "u1", order: 0, chapter: "离线第一章", page: 1, text: String(decoding: sourceBytes, as: UTF8.self))
            ])
            PluginEngine.seed(&project)
            project.plan = ReadingPlan(methodIDs: ["genre.history"])
            project.plan?.recommendedParallelism = 1
            // Seed valid receipts for these two synthetic paragraphs. The UI
            // exercise starts at enrichment rather than the separate read step.
            let paragraphs = try ReadingLedger.paragraphs(for: project.units[0], in: project)
            project.receiptBatch = try ReadingLedger.makeBatch(unit: project.units[0], paragraphs: paragraphs)
            let receipts: [String: Any] = ["batchID": project.receiptBatch!.id, "receipts": paragraphs.map { paragraph in
                ["paragraphID": paragraph.id, "textHash": paragraph.textHash, "summary": "离线段落已核对。",
                 "startQuote": paragraph.startQuote, "endQuote": paragraph.endQuote, "issues": []] as [String: Any]
            }]
            _ = try PluginEngine.apply(name: "read_receipt", arguments: JSONSerialization.data(withJSONObject: receipts), to: &project, allowedUnitIDs: ["u1"])
            project.receiptBatch = nil
            let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: "刘备在此。", in: project)
            project.readingExperience = ReadingExperienceState(anchors: [anchor], layers: [
                ReadingLayer(id: "saved-oldest", kind: "explanation", title: "旧回答一", markdown: "最早的保存记录。默认应折叠在历史中。", sourceAnchorIDs: [anchor.id], sourceLabel: "离线 fixture"),
                ReadingLayer(id: "saved-second", kind: "explanation", title: "旧回答二", markdown: "第二条保存记录。应排在旧回答一前面。", sourceAnchorIDs: [anchor.id], sourceLabel: "离线 fixture"),
                ReadingLayer(id: "saved-latest", kind: "explanation", title: "当前最新回答", markdown: "刘备就在这里。当前核心应直接可见，先前记录默认折叠。", sourceAnchorIDs: [anchor.id], sourceLabel: "离线 fixture")
            ])
            let owner = LibraryRepository(rootURL: library)
            project = try await owner.create(project, sourceURL: source)
            project = try await owner.saveDocument(project: project, document: note, markdown: noteBody)
            let model = transport
            let coordinator = AIRequestCoordinator(transport: { try await model.perform($0) })
            store = AppStore(sharedAIRequests: coordinator, connectionProbe: { try await model.connection($0, $1) })
            guard store.apiKey.isEmpty, store.savedServices.isEmpty else { throw ReadingError.invalid("离线服务配置隔离失败。") }
            store.repository = owner; store.libraryRootURL = library
            store.books = [project]
            await store.selectBook(project.id)
            store.settings = ProviderSettings(baseURL: "http://127.0.0.1:1/offline", model: "offline-ui-fixture", maxRequestsPerRun: 20, maxOutputTokens: 1_000, contextWindowTokens: 128_000)
            store.queryMemoryEnabled = false; store.queryScope = .page
            store.readingCompanionVisible = true; store.readingCompanionTab = "companion"
            store.queryComposerDraft.text = "原文说谁在这里？"
            installMenus()
            let root = WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings())
                .modifier(ReadingPreferencesEnvironment()).background(FrostWindowAppearance())
            window = NSWindow(contentRect: NSRect(x: 100, y: 60, width: width, height: height), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ReadingBook 离线测试：伴读等待时仍可对话"
            window.minSize = NSSize(width: 800, height: 632)
            window.contentView = NSHostingView(rootView: root)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            write("ready.json", ["status": "ready", "pid": getpid(), "bookID": project.id, "library": library.path, "realNetworkRequests": 0,
                "sourceUnits": ["u1"], "paragraphCount": paragraphs.count, "controlDirectory": output.appendingPathComponent("control").path,
                "instructions": "通过真实按钮生成（确认后保持等待），切到对话并发送草稿；control/release-companion 完成伴读，control/hold-companion 再次挂起，control/long-next-companion 让下一次生成使用长正文和双来源，control/checkpoint-draft 仅保存当前草稿检查点，control/quit 保存草稿检查点并安全退出。"])
            await snapshot()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.poll() }
            }
        } catch {
            write("result.json", ["status": "failed", "error": error.localizedDescription, "realNetworkRequests": 0])
            NSApp.terminate(nil)
        }
    }
    private func consume(_ name: String) -> Bool {
        let file = output.appendingPathComponent("control/" + name)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        do { try FileManager.default.removeItem(at: file); return true } catch { return false }
    }
    private func poll() async {
        guard !polling, store != nil else { return }; polling = true
        defer { polling = false }
        if consume("long-next-companion") { await transport.useLongNextCompanion() }
        if consume("hold-companion") { await transport.hold() }
        if consume("release-companion") { await transport.release() }
        if consume("checkpoint-draft") { _ = checkpointDraft(reason: "control/checkpoint-draft") }
        await snapshot()
        if consume("quit") {
            terminationDraftCaptured = checkpointDraft(reason: "control/quit")
            store.cancelCompanion(); store.cancelAIActivity(store.queryProgressState.value.runID)
            let sourcePreserved = (try? Data(contentsOf: output.appendingPathComponent("fixture.txt"))) == sourceBytes
            let markdownPreserved = (try? await store.repository.readDocument(bookID: bookID, document: note)) == noteBody
            let saved = try? await store.repository.loadReport().projects.first { $0.id == bookID }
            let savedIDs = Set(saved?.readingExperience?.layers.map(\.id) ?? [])
            let recordsPreserved = Set(["saved-oldest", "saved-second", "saved-latest"]).isSubset(of: savedIDs)
            write("result.json", ["status": chatFinishedDuringCompanion && sourcePreserved && markdownPreserved && recordsPreserved ? "passed" : "incomplete",
                "chatCompletedWhileCompanionHeld": chatFinishedDuringCompanion, "originalSourceBytesPreserved": sourcePreserved,
                "userMarkdownBytesPreserved": markdownPreserved, "existingAnalysisPreserved": recordsPreserved, "realNetworkRequests": 0,
                "draftCheckpointSaved": terminationDraftCaptured, "draftTitle": store.editorTitle,
                "draftMarkdownUTF8Bytes": store.editorMarkdown.utf8.count, "draftMarkdownSHA256": fixtureSHA256(store.editorMarkdown),
                "editorDirty": store.editorDirty, "selectedDocumentID": store.selectedDocumentID ?? "", "route": store.route])
            await snapshot()
            NSApp.terminate(nil)
        }
    }
    @discardableResult private func checkpointDraft(reason: String) -> Bool {
        guard let store else { return false }
        let checkpoint: [String: Any] = ["reason": reason, "capturedAt": Date().formatted(.iso8601),
            "bookID": store.bookID ?? "", "title": store.editorTitle, "markdown": store.editorMarkdown,
            "markdownUTF8Bytes": store.editorMarkdown.utf8.count, "markdownSHA256": fixtureSHA256(store.editorMarkdown),
            "editorDirty": store.editorDirty, "selectedDocumentID": store.selectedDocumentID ?? "", "route": store.route,
            "checkpointWritesLibrary": false]
        do {
            let data = try JSONSerialization.data(withJSONObject: checkpoint, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("draft-checkpoint.json"), options: .atomic)
            draftCheckpointStatus = "saved"; return true
        } catch { draftCheckpointStatus = "failed"; return false }
    }
    private func snapshot() async {
        let model = await transport.snapshot()
        let answers = store.book?.chats.filter { $0.role == "assistant" }.count ?? 0
        if store.isCompanionGenerating && model.held && model.waiting > 0 && answers > 0 && !store.isQueryBusy { chatFinishedDuringCompanion = true }
        let companion = store.companionProgressState.value, query = store.queryProgressState.value
        if !model.longReplySHA256.isEmpty, model.longReplySHA256 != writtenLongReplySHA256 {
            if (try? model.longReplyMarkdown.write(to: output.appendingPathComponent("long-companion-original.md"), atomically: true, encoding: .utf8)) != nil {
                writtenLongReplySHA256 = model.longReplySHA256
            }
        }
        let canSendCurrentQuestion = store.canStartQuery && !store.queryComposerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.canUseQueryScope(store.queryScope)
        write("state.json", ["status": "ready", "pid": getpid(), "realNetworkRequests": 0,
            "companionHeld": model.held, "waitingCompanionRequests": model.waiting, "companionRequests": model.companionRequests,
            "chatRequests": model.chatRequests, "connectionTests": model.connectionTests, "assistantAnswers": answers,
            "isCompanionGenerating": store.isCompanionGenerating, "isQueryBusy": store.isQueryBusy,
            "canStartQuery": store.canStartQuery, "canStartCompanion": store.canStartCompanion, "canEditAISettings": store.canEditAISettings,
            "companionRunID": companion.runID?.uuidString ?? "", "queryRunID": query.runID?.uuidString ?? "",
            "companionPhase": companion.phase.rawValue, "companionPhaseTitle": companion.phaseTitle, "companionStatus": String(describing: companion.status),
            "queryStatus": String(describing: query.status), "chatCompletedWhileCompanionHeld": chatFinishedDuringCompanion,
            "layerIDs": store.book?.readingExperience?.layers.map(\.id) ?? [], "error": store.errorMessage ?? "",
            "longNextCompanionArmed": model.longNextCompanion, "longCompanionReplies": model.longCompanionReplies,
            "longReplySHA256": model.longReplySHA256, "longReplyUTF8Bytes": model.longReplyMarkdown.utf8.count,
            "longReplyLayerID": model.longReplyLayerID, "draftCheckpointStatus": draftCheckpointStatus,
            "draftTitle": store.editorTitle, "draftMarkdownUTF8Bytes": store.editorMarkdown.utf8.count,
            "draftMarkdownSHA256": fixtureSHA256(store.editorMarkdown), "editorDirty": store.editorDirty,
            "selectedDocumentID": store.selectedDocumentID ?? "", "route": store.route, "canSendCurrentQuestion": canSendCurrentQuestion,
            "keyboardSaveCount": keyboardSaveCount,
            "windowWidth": window?.contentView?.bounds.width ?? 0, "windowHeight": window?.contentView?.bounds.height ?? 0])
    }
}

@main private enum AIConcurrencyUIHost {
    @MainActor static func main() {
        do {
            var arguments: [String: String] = [:]
            var cursor = 1
            while cursor < CommandLine.arguments.count {
                guard cursor + 1 < CommandLine.arguments.count, ["--workspace", "--output", "--width", "--height"].contains(CommandLine.arguments[cursor]), arguments[CommandLine.arguments[cursor]] == nil else { throw ReadingError.invalid("用法：--workspace ABSOLUTE_WORKSPACE --output NEW_WORKSPACE_DIRECTORY [--width 1100 --height 800]") }
                arguments[CommandLine.arguments[cursor]] = CommandLine.arguments[cursor + 1]; cursor += 2
            }
            guard let workspacePath = arguments["--workspace"], let outputPath = arguments["--output"], workspacePath.hasPrefix("/"), outputPath.hasPrefix("/") else { throw ReadingError.invalid("必须提供绝对 workspace/output 路径。") }
            let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath()
            let output = URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
            let app = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Package.swift").path),
                  output != workspace, output.pathComponents.starts(with: workspace.pathComponents),
                  !FileManager.default.fileExists(atPath: output.path),
                  Bundle.main.bundleIdentifier == "org.readingbook.ui-concurrency-test",
                  app.pathComponents.starts(with: workspace.appendingPathComponent(".build").pathComponents) else { throw ReadingError.invalid("只能运行工作目录 .build 内的独立测试 app，并使用全新的工作目录内输出。") }
            let width = Double(arguments["--width"] ?? "1100") ?? 1100, height = Double(arguments["--height"] ?? "800") ?? 800
            guard width.isFinite, height.isFinite, (800...2000).contains(width), (632...1400).contains(height) else { throw ReadingError.invalid("测试窗口尺寸范围为 800–2000 × 632–1400。") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for child in ["library", "control", "tmp", "home"] { try FileManager.default.createDirectory(at: output.appendingPathComponent(child), withIntermediateDirectories: false) }
            setenv("TMPDIR", output.appendingPathComponent("tmp").path, 1)
            setenv("CFFIXED_USER_HOME", output.appendingPathComponent("home").path, 1)
            let settings = ProviderSettings(baseURL: "http://127.0.0.1:1/offline", model: "offline-ui-fixture")
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1": output.appendingPathComponent("library").path,
                "service-profiles": Data("[]".utf8), "provider": try JSONEncoder().encode(settings), "query-memory-enabled": false,
                "reader.hoverAutoTranslation": false, "reading.hoverTranslation": false, "appearance.reduceMotion": false,
                "NSQuitAlwaysKeepsWindows": false, "ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
            let application = NSApplication.shared; application.setActivationPolicy(.regular)
            let runner = OfflineUIRunner(output: output, width: width, height: height)
            application.delegate = runner
            withExtendedLifetime(runner) { application.run() }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data(("Offline UI host: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
