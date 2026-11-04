import AppKit
import Foundation
import SwiftUI
import WebKit
@testable import ReadingBook
@testable import ReadingCore

/// Real product presentation, repository and WebKit. All inputs are synthetic;
/// the runner denies network, the user's original library and bundle fallback.
@MainActor private final class HistoryRunner: NSObject, NSApplicationDelegate {
    var output: URL!
    var store: AppStore!
    var host: NSHostingView<AnyView>!
    var window: NSWindow!
    var checks: [String: Bool] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try finish(nil) } catch { try? finish(error.localizedDescription) }
            NSApp.terminate(nil)
        }
    }
    func encoded<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    func check(_ name: String, _ value: Bool) throws { checks[name] = value; guard value else { throw ReadingError.invalid(name) } }
    func settle() async throws { try await Task.sleep(for: .milliseconds(180)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews($0) } }
    func compare(_ name: String) throws {
        let before = try encoded(store.book)
        let actual = ChatHistoryPresentation(store: store)
        // Retain the existing independently evaluated collection and mode
        // helpers as the compatibility oracle; compare every message field.
        let equal = try encoded(actual.all) == encoded(store.currentQueryHistory)
            && encoded(actual.folded) == encoded(store.foldedQueryAnswers)
            && encoded(actual.visible) == encoded(store.visibleQueryHistory)
            && actual.hasVisibleAnswers == store.visibleQueryHistory.contains { $0.role == "assistant" }
            && before == encoded(store.book)
        try check(name, equal)
    }
    func displayed(_ text: String) async throws -> Bool {
        for _ in 0..<40 {
            for web in webViews(host) {
                if let rendered = try? await web.evaluateJavaScript("document.body.innerText") as? String, rendered.contains(text) { return true }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard Bundle.main.bundleIdentifier != "org.readingbook.app", output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/ai-history-preparation-20261104/") else { throw ReadingError.invalid("Isolation path rejected") }
        let root = output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1": root.path, "service-profiles": Data("[]".utf8), "reading.hoverTranslation": false, "query-memory-enabled": false], forName: UserDefaults.argumentDomain)
        let units = (0..<32).map { SourceUnit(id: "u\($0)", order: $0, chapter: "合成章", page: $0+1, text: "合成原文第\($0)段。") }
        let bytes = Data(units.map(\.text).joined(separator: "\n").utf8), source = output.appendingPathComponent("synthetic.txt")
        try bytes.write(to: source)
        var project = BookProject(title: "长历史兼容回归合成书", originalName: "synthetic.txt", sourceHash: try BookImporter.sha256(bytes), units: units)
        PluginEngine.seed(&project)
        project.chats = [ChatMessage(id: "legacy-q", role: "user", content: "旧版问题"), ChatMessage(id: "legacy-a", role: "assistant", content: "旧版回答", evidence: [Evidence(unitID: "u0", quote: units[0].text)])]
        for mode in ReadingConversationMode.allCases {
            for style in ReadingAnswerStyle.allCases {
                let prefix = mode.rawValue + "-" + style.rawValue
                for (suffix, role) in [("q", "user"), ("a", "assistant"), ("b", "assistant")] {
                    var message = ChatMessage(id: prefix + suffix, role: role, content: "合成问答" + prefix + suffix, evidence: [Evidence(unitID: "u1", quote: units[1].text)])
                    message.conversationMode = mode; message.answerStyle = style; project.chats.append(message)
                }
            }
        }
        let repository = LibraryRepository(rootURL: root)
        project = try await repository.create(project, sourceURL: source)
        let note = DocumentRecord(id: "protected-note", title: "回归保留笔记")
        project = try await repository.saveDocument(project: project, document: note, markdown: "不因整理对话修改这篇合成笔记。")
        let canonicalHistory = try encoded(project.chats), canonicalUnits = try encoded(project.units), canonicalDocuments = try encoded(project.documents)
        store = AppStore(); store.libraryRootURL = root; store.repository = repository; store.books = [project]; store.bookID = project.id
        store.selectedUnitID = "u0"; store.route = "query"; store.queryMemoryEnabled = false
        store.settings = .init(baseURL: "http://127.0.0.1:1/disabled", model: ""); store.apiKey = ""
        try check("noNetworkService", store.savedServices.isEmpty)
        for mode in ReadingConversationMode.allCases {
            for style in ReadingAnswerStyle.allCases {
                store.queryInteractionMode = mode; store.queryAnswerStyle = style
                try compare("mode-" + mode.rawValue + "-" + style.rawValue)
            }
        }
        try check("legacyDefault", ChatHistoryPresentation(store: store).all.contains { $0.id == "legacy-a" })
        store.queryInteractionMode = .reading; store.queryAnswerStyle = .mentor
        host = NSHostingView(rootView: AnyView(EnhancedBookChatView().environmentObject(store).environmentObject(ReadingTypographySettings()).environment(\.readingReduceMotion, true)))
        window = NSWindow(contentRect: .init(x: 120, y: 100, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ReadingBook 对话历史 · 隔离回归"; window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await settle()
        try check("realWebKitLoaded", await displayed("合成问答reading-mentor"))
        await store.organizeReaderCollections(.collapse(["chat:reading-mentora"], true))
        try compare("oneAnswerCollapse")
        try check("entireTurnHidden", ChatHistoryPresentation(store: store).visible.isEmpty && Set(ChatHistoryPresentation(store: store).folded.map(\.id)) == ["reading-mentora", "reading-mentorb"])
        await store.collapseCurrentQueryAnswers(); try compare("allAnswersCollapsed")
        await store.archiveFoldedQueryAnswers(); try compare("archiveFolded")
        try check("archiveNotAutomaticContext", ChatHistoryPresentation(store: store).all.isEmpty)
        await store.organizeReaderCollections(.restore(["chat:reading-mentora"]))
        try compare("restoreOneTurn")
        try check("restoredTurnVisible", ChatHistoryPresentation(store: store).all.count == 3)
        let loaded = try await repository.loadAll()
        guard let saved = loaded.first(where: { $0.id == project.id }) else { throw ReadingError.invalid("Saved project missing") }
        try check("archivedOriginalHistoryBytes", try encoded(saved.chats) == canonicalHistory)
        try check("sourceUnitsUnchanged", try encoded(saved.units) == canonicalUnits)
        try check("originalNotesUnchanged", try encoded(saved.documents) == canonicalDocuments)
        var changed = saved
        changed.readerCollections = .init()
        changed.chats = changed.chats.filter { $0.id == "reading-mentorq" || $0.id == "reading-mentora" }
        changed.chats[1].content = "原句改为新内容 cafe\u{301}，保留精确字节。"
        store.publish(changed); try compare("sameIDEditedBytes"); try await settle()
        try check("editedMarkdownVisible", await displayed("原句改为新内容"))
        var added = ChatMessage(id: "added", role: "assistant", content: "新收到的回答")
        added.conversationMode = .reading; added.answerStyle = .mentor
        changed.chats.append(added); store.publish(changed); try compare("newMessage")
        try check("newMessageVisible", ChatHistoryPresentation(store: store).visible.last?.id == "added")
        changed.chats = []; store.publish(changed); try compare("emptyChats")
        var other = BookProject(title: "另一本合成书", originalName: "synthetic.txt", sourceHash: project.sourceHash, units: units)
        other.chats = [added]; store.books.append(other); store.bookID = other.id; try compare("bookSwitch")
        try check("otherBookVisible", ChatHistoryPresentation(store: store).all.map(\.id) == ["added"])
        store.libraryRootURL = output.appendingPathComponent("other-library"); store.books = [other]; try compare("sameBookNewRoot")
        other.sourceHash = String(repeating: "f", count: 64); store.books = [other]; try compare("sourceChanged")
        store.bookID = nil; try compare("missingBook")
        try check("noNewModelCalls", store.requestsUsed == 0)
    }
    func finish(_ error: String?) throws {
        let result: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error as Any? ?? NSNull(), "checks": checks, "realNetworkRequests": 0, "originalLibraryUsed": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
}
@main struct Main { static func main() { let app = NSApplication.shared; let runner = HistoryRunner(); app.delegate = runner; app.setActivationPolicy(.regular); app.run(); _ = runner } }
