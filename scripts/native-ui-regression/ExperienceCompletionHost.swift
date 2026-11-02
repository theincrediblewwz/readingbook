import AppKit
import SwiftUI
import PDFKit
@testable import ReadingCore
@testable import ReadingBook

@MainActor final class ExperienceCompletionRunner: NSObject, NSApplicationDelegate {
    let directory: URL
    var window: NSWindow!
    var store: AppStore!
    var controller = PDFReaderController()
    init(directory: URL) { self.directory = directory }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await start() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func start() async {
        do {
            let library = directory.appendingPathComponent("library")
            UserDefaults.standard.setVolatileDomain(["service-profiles": Data("[]".utf8), "library.root.path.v1": library.path,
                "NSQuitAlwaysKeepsWindows": false, "appearance.reduceMotion": true, "reader.hoverAutoTranslation": false], forName: UserDefaults.argumentDomain)
            let coordinator = AIRequestCoordinator(transport: { prepared in
                let body = String(decoding: prepared.request.httpBody ?? Data(), as: UTF8.self)
                if (body.contains("围绕这篇附加笔记") || body.contains("对这篇附加笔记")),
                   let object = try? JSONSerialization.jsonObject(with: prepared.request.httpBody ?? Data()) as? [String: Any],
                   let rows = object["messages"] as? [[String: Any]], !rows.contains(where: { $0["role"] as? String == "tool" }) {
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil,
                        tool_calls: [.init(id: "read-source", type: "function", function: .init(name: "source_read", arguments: #"{"id":"p1","length":2000}"#)),
                                     .init(id: "read-note", type: "function", function: .init(name: "document_read", arguments: #"{"id":"n1","length":2000}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 50)
                }
                let text: String
                if body.contains("想出1至3个") { text = #"{"questions":["王允为什么接连故作惊讶？","吕布的话如何透露他的动机？"]}"# }
                else if body.contains("requirements") && body.contains("新消息片段") || body.contains("这次消息片段") {
                    try await Task.sleep(nanoseconds: 700_000_000)
                    text = #"{"requirements":[{"text":"想弄清王允与吕布的动机","sources":["q0"]}],"conclusions":[{"text":"这段试探仍要对照原文，不能当作史实","sources":["a0"]}],"unresolved":[{"text":"王允的反问怎样推动吕布继续说下去？","sources":["q0","a0"]}]}"#
                } else if body.contains("为读者未分类的笔记") {
                    text = #"{"groups":[{"title":"人物与动机","noteIDs":["n1","n2"]},{"title":"表达与语气","noteIDs":["n3","n4"]}]}"#
                } else if body.contains("围绕这篇附加笔记") || body.contains("对这篇附加笔记") {
                    text = (body.contains("逐项区别") ? "原文明载的是反问。笔记中的动机解释属于推断，所给片段不足以确定全部背景。" : "这几句反问像是在引着对方把话说下去。先抓住说话的语气，就容易理解这一段的推进。") + "[unit:p1][doc:n1]"
                } else { text = "这几句反问像是在引着对方把话说下去。先抓住说话的语气，就容易理解这一段的推进。" }
                return .init(message: .init(role: "assistant", content: text, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 50)
            })
            store = AppStore(sharedAIRequests: coordinator)
            store.settings = .init(baseURL: "https://offline.invalid", model: "isolated-fixture", maxRequestsPerRun: 12, maxOutputTokens: 1600, contextWindowTokens: 32768)
            store.apiKey = ""
            if let saved = try await store.repository.loadAll().first {
                let source = await store.repository.sourceURL(for: saved)
                show(project: saved, source: source); return
            }
            let source = directory.appendingPathComponent("fixture.pdf")
            var media = CGRect(x: 0, y: 0, width: 600, height: 800)
            let graphics = CGContext(source as CFURL, mediaBox: &media, nil)!
            let lines = ["三国演义 · 隔离测试原文", "王允连连反问，吕布接着说出自己的疑虑。", "这是一份合成测试书，原书、笔记与分析不会改动。", "纸条只在右侧留白中显示。", "同一位置的便签可以叠放，展开后逐张查看。"]
            for page in 1...3 {
                graphics.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: false)
                for (index, line) in lines.enumerated() { NSString(string: line).draw(at: .init(x: 38, y: 710 - index * 95), withAttributes: [.font: NSFont(name: "Songti SC", size: 22)!, .foregroundColor: NSColor.black]) }
                NSString(string: "第 \(page) 页").draw(at: .init(x: 38, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
                NSGraphicsContext.restoreGraphicsState(); graphics.endPDFPage()
            }
            graphics.closePDF()
            if let fixture = PDFDocument(url: source) {
                fixture.page(at: 1)?.setBounds(.init(x: 20, y: 35, width: 550, height: 710), for: .cropBox)
                fixture.page(at: 1)?.rotation = 90; fixture.page(at: 2)?.rotation = 270
                guard fixture.write(to: source) else { throw ReadingError.invalid("Unable to save rotated fixture") }
            }
            var project = BookProject(id: "00000000-0000-4000-8000-000000000231", title: "便签与十项体验 · 隔离合成测试书，检查很长的完整书名", originalName: "fixture.pdf", sourceHash: try BookImporter.sha256(Data(contentsOf: source)), units: (1...3).map { .init(id: "p\($0)", order: $0-1, chapter: "第一回", page: $0, text: lines.joined(separator: "\n")) })
            PluginEngine.seed(&project)
            let snap = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: ReadingContext(unitID: "p1", page: 1))
            let context = try ReadingChatContext(snapshot: snap, avoidsSpoilers: true)
            for i in 0..<6 { for role in ["user", "assistant"] {
                var chat = ChatMessage(id: (role == "user" ? "q" : "a") + "\(i)", role: role, content: role == "user" ? "第\(i+1)个问题：王允在试探吗？" : "第\(i+1)条回答：要对照反问的原话，也要保留不知道的部分。")
                chat.conversationMode = .reading; chat.answerStyle = .mentor; chat.readingContext = context; project.chats.append(chat)
            } }
            project = try await store.repository.create(project, sourceURL: source)
            for i in 1...4 {
                let document = DocumentRecord(id: "n\(i)", title: i <= 2 ? "人物动机 \(i)" : "语气与反问 \(i)", evidence: [Evidence(unitID: "p1", quote: lines[1])])
                let placement = ReadingNotePlacement(sourceHash: project.sourceHash, unitID: "p1", page: 1, x: 0.7, y: i < 4 ? 0.73 - Double(i) * 0.01 : 0.27)
                project = try await store.repository.saveDocument(project: project, document: document,
                    markdown: i == 1 ? "这里的反问并非直接给答案，而是让对方把心里的话说出来。" : "我想再读一遍这句话，留意人物的语气。第\(i)张便签。", notePlacement: placement)
            }
            for page in 2...3 {
                let note = DocumentRecord(id: "rotation-\(page)", title: "旋转位置 \(page)")
                project = try await store.repository.saveDocument(project: project, document: note, markdown: "旋转与裁剪后的坐标仍锚定原书。",
                    notePlacement: .init(sourceHash: project.sourceHash, unitID: "p\(page)", page: page, x: 0.5, y: 0.55))
            }
            show(project: project, source: source)
        } catch { try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt")); NSApp.terminate(nil) }
    }
    private func show(project: BookProject, source: URL) {
            store.books = [project]; store.bookID = project.id; store.selectedUnitID = "p1"; store.sourceFileURL = source
            store.workspaceMemory = BookWorkspaceMemory(bookID: project.id, sourceHash: project.sourceHash)
            let content = ExperienceCompletionHost(store: store, controller: controller)
                .environmentObject(ReadingTypographySettings()).modifier(ReadingPreferencesEnvironment())
            window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1320, height: 820), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 便签与十点体验 · 隔离测试"
            window.contentView = NSHostingView(rootView: content); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try? JSONSerialization.data(withJSONObject: ["ready":true,"pid":ProcessInfo.processInfo.processIdentifier,"bookID":project.id,"root":store.libraryRootURL.path], options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("ready.json"))
            Task {
                await checkGeometry(); await checkMemoryConcurrency()
                if ProcessInfo.processInfo.environment["UX_EXIT_AFTER_CHECKS"] == "1" {
                    let passed = ["geometry.json", "memory-concurrency.json"].allSatisfy { name in
                        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)), let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                        return record["passed"] as? Bool == true
                    }
                    exit(passed ? 0 : 1)
                }
            }
    }

    private func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? [] + root.subviews.flatMap { views($0, type) }
    }
    private func checkGeometry() async {
        var checks: [String: Bool] = [:], samples: [[String: Any]] = []
        let sourceBefore = try? Data(contentsOf: store.sourceFileURL!)
        // The UI sheet may include a temporary note gutter. Derive the oracle
        // from the unchanged file, independently of the UI's box bookkeeping.
        guard let sourceBefore, let originalDocument = PDFDocument(data: sourceBefore) else { return }
        for _ in 0..<100 { if controller.isReady { break }; try? await Task.sleep(nanoseconds: 30_000_000) }
        guard let content = window.contentView, let pdf = views(content, PDFView.self).first, let container = views(content, PDFReaderContainerView.self).first, let document = pdf.document else { return }
        for number in 1...3 {
            controller.command(.jump(number)); controller.command(.fitPage)
            try? await Task.sleep(nanoseconds: 200_000_000)
            for scale in [1.0, 1.2] {
                if scale != 1 { pdf.scaleFactor *= scale; pdf.layoutDocumentView() }
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let page = document.page(at: number-1) else { continue }
                for (id, placement) in store.activeNotePlacements where placement.page == number {
                    guard let sourcePage = originalDocument.page(at: number-1) else { continue }
                    let crop = sourcePage.bounds(for: .cropBox)
                    let original = CGPoint(x: crop.minX + crop.width * placement.x, y: crop.minY + crop.height * placement.y)
                    let point = container.convert(pdf.convert(original, from: page), from: pdf)
                    if !container.bounds.contains(point) { continue }
                    let expected = CGPoint(x: point.x, y: container.isFlipped ? point.y : container.bounds.height - point.y)
                    let received = controller.noteAnchorPoints[id]
                    let valid = received.map { abs($0.x - expected.x) < 0.5 && abs($0.y - expected.y) < 0.5 } ?? false
                    checks["\(id)-scale\(scale)"] = valid
                    samples.append(["id":id,"page":number,"rotation":page.rotation,"crop":NSStringFromRect(crop),"nativeSheet":NSStringFromRect(page.bounds(for: .cropBox)),"expected":NSStringFromPoint(expected),"received":received.map(NSStringFromPoint) ?? "missing"])
                }
                checks["owner-page\(number)-scale\(scale)"] = controller.notePositions.owner == store.collectionOwnerKey
            }
        }
        controller.command(.jump(1)); controller.command(.fitPage)
        checks["originalPDFBytesPreserved"] = (try? Data(contentsOf: store.sourceFileURL!)) == sourceBefore
        checks["allThreePagesExercised"] = Set(samples.compactMap { $0["page"] as? Int }) == [1,2,3]
        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
        let result: [String: Any] = ["passed":passed,"checks":checks,"samples":samples]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("geometry.json"))
    }
    private func checkMemoryConcurrency() async {
        var checks: [String: Bool] = [:]
        var observations: [String: Any] = [:]
        do {
            var stable = 0
            for _ in 0..<100 {
                if controller.page == 1 && store.selectedUnitID == "p1" && controller.notePositions.owner == store.collectionOwnerKey { stable += 1 } else { stable = 0 }
                if stable >= 5 { break }; try await Task.sleep(nanoseconds: 50_000_000)
            }
            observations["stablePageSamples"] = stable
            let project = store.book!, root = store.libraryRootURL, preferences = store.currentQueryPreferences
            let paperPreview = PositionNotePreview.make("原话。[unit:p1][doc:n1]", project: project)
            checks["paperPreviewUsesReadableReferences"] = !paperPreview.contains("[unit:") && !paperPreview.contains("[doc:") && paperPreview.contains("第 1 页") && paperPreview.contains("人物动机 1")
            checks["paperPreviewKeepsLiteralCodeAndUnicode"] = PositionNotePreview.make("`[unit:p1]` e\u{301} 👩🏽‍💻", project: project) == "[unit:p1] e\u{301} 👩🏽‍💻"
            let installed = NSFontManager.shared.availableFontFamilies.sorted().compactMap { family -> (String, NSFont)? in
                guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 21) else { return nil }; return (family, font)
            }
            guard let chosen = installed.first(where: { NSFont(name: $0.0, size: 21) == nil }) ?? installed.first else { throw ReadingError.invalid("No installed font family available") }
            var fontPlacement = ReadingNotePlacement(sourceHash: project.sourceHash, unitID: "p1", page: 1, x: 0.5, y: 0.5, fontFamily: chosen.0, fontSize: 21)
            let custom = PositionNoteTypography.native(fontPlacement)
            checks["paperAndEditorResolveInstalledFontFamily"] = custom.fontName == chosen.1.fontName && custom.pointSize == 21
            fontPlacement.fontFamily = "monospaced"
            checks["paperAndEditorShareMonospacedFont"] = PositionNoteTypography.native(fontPlacement).fontName == NSFont.monospacedSystemFont(ofSize: 21, weight: .regular).fontName
            let prepared = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: store.queryReadingContext, preferences: preferences)
            let history = prepared.history
            func memory(_ messages: [ChatMessage], count: Int) throws -> ConversationMemory {
                let cursor = ConversationMemoryCursor(index: count)
                return ConversationMemory(id: project.id + ":" + prepared.snapshot.scopeFingerprint, bookID: project.id,
                    scopeFingerprint: prepared.snapshot.scopeFingerprint, fingerprint: try ConversationMemoryRuntime.prefixFingerprint(messages, cursor: cursor), cursor: cursor,
                    requirements: [], conclusions: [.init(text: "派生要点保留原消息出处", sources: [messages[1].id])], unresolved: [], updatedAt: .now, model: "offline")
            }
            let newer = try memory(history, count: history.count), older = try memory(history, count: 2)
            try await QueryMemoryFiles.shared.write(newer, snapshot: prepared.snapshot, history: history, root: root)
            let retained = try await QueryMemoryFiles.shared.write(older, snapshot: prepared.snapshot, history: history, root: root)
            checks["lateOlderSummaryCannotRegressCursor"] = retained.cursor == newer.cursor
            let afterArchive = Array(history.dropFirst(4)), rebuilt = try memory(afterArchive, count: 2)
            let replacement = try await QueryMemoryFiles.shared.write(rebuilt, snapshot: prepared.snapshot, history: afterArchive, root: root)
            checks["invalidPriorPrefixCanBeRebuilt"] = replacement.fingerprint == rebuilt.fingerprint
            try await QueryMemoryFiles.shared.remove(snapshot: prepared.snapshot, root: root)
            let initialMessages = project.chats.count
            observations["beforeUnit"] = store.selectedUnitID ?? "nil"
            observations["providerReady"] = store.providerReady
            store.summarizeCurrentConversation()
            for _ in 0..<100 { if store.isSummaryRequestRunning { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            checks["summaryDoesNotDisableQuestion"] = store.isManagingQueryMemory && store.canStartQuery
            observations["summaryStatusBeforeQuestion"] = store.queryMemoryStatus
            observations["summaryProgressTitle"] = store.summaryProgressState.value.title
            observations["beforeQuestionUnit"] = store.selectedUnitID ?? "nil"
            store.ask("摘要正在整理时，对话也能继续吗？")
            checks["independentTasksOverlap"] = store.isQueryBusy && store.isSummaryRequestRunning
            let summary = store.queryMemoryTask, query = store.queryTask
            await query?.value; await summary?.value
            checks["questionAndAnswerBothPreserved"] = (store.book?.chats.count ?? 0) == initialMessages + 2
            let current = try ReadingPreparedAnswer.freeze(project: store.book!, scope: .page, context: store.queryReadingContext, preferences: preferences)
            let saved = await QueryMemoryFiles.shared.read(snapshot: current.snapshot, history: current.history, root: root)
            checks["summaryStillValidAfterConcurrentQuestion"] = saved != nil
            checks["summaryActuallyVisibleInProgressLane"] = store.summaryProgressState.value.requests.count == 1
            observations["summaryStatusAfterQuestion"] = store.queryMemoryStatus
            observations["summaryRequests"] = store.summaryProgressState.value.requests.count
            observations["summaryKeyUnit"] = store.queryMemoryStatusKey?.context.unitID ?? "nil"
            checks["noteMetadataPreserved"] = store.book?.readerCollections?.notePlacements == project.readerCollections?.notePlacements
            store.summarizeCurrentConversation()
            for _ in 0..<100 { if store.isSummaryRequestRunning { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            controller.command(.jump(2)); store.selectedUnitID = "p2"
            await store.queryMemoryTask?.value
            let oldScopeHistory = ReadingChatHistory.automaticHistory(in: store.book!, preferences: preferences, snapshot: prepared.snapshot)
            let continued = await QueryMemoryFiles.shared.read(snapshot: prepared.snapshot, history: oldScopeHistory, root: root)
            checks["turningPageKeepsFrozenSummaryRunning"] = continued?.cursor.index == oldScopeHistory.count
            checks["completionStatusBelongsToOriginalScope"] = store.queryMemoryStatusKey?.context.unitID == "p1"
            controller.command(.jump(1)); store.selectedUnitID = "p1"
            for _ in 0..<100 { if store.pendingAIHistoryWrites == 0 { break }; try? await Task.sleep(nanoseconds: 20_000_000) }
            await store.editPositionNote("n3")
            guard let noteRequest = store.positionNoteRequest else { throw ReadingError.invalid("Missing note editor request") }
            store.persistPositionNoteDraft(noteRequest, text: "", placement: noteRequest.placement)
            store.positionNoteRequest = nil
            await store.editPositionNote("n3")
            checks["clearedTextRemainsInDraft"] = store.positionNoteRequest?.recovered == true && store.positionNoteRequest?.text == ""
            if let draft = store.positionNoteRequest { store.discardPositionNoteDraft(draft) }
            store.positionNoteRequest = nil
            await store.editPositionNote("n3")
            checks["discardingDraftRestoresSavedBody"] = store.positionNoteRequest?.text == noteRequest.text && store.positionNoteRequest?.recovered == false
            store.positionNoteRequest = nil
            for _ in 0..<100 { if controller.page == 1 && store.selectedUnitID == "p1" { break }; try? await Task.sleep(nanoseconds: 20_000_000) }
            try await QueryMemoryFiles.shared.remove(snapshot: prepared.snapshot, root: root)
            let beforeCancel = store.book!.chats.count
            store.summarizeCurrentConversation()
            for _ in 0..<100 { if store.isSummaryRequestRunning { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            store.ask("停止摘要也应该保留这个独立问答。")
            let stopped = store.queryMemoryTask, surviving = store.queryTask
            store.cancelAIActivity(store.summaryProgressState.value.runID)
            checks["stoppingSummaryDoesNotCancelQuestion"] = store.isQueryBusy
            await stopped?.value; await surviving?.value
            let afterCancel = try ReadingPreparedAnswer.freeze(project: store.book!, scope: .page, context: store.queryReadingContext, preferences: preferences)
            let cancelled = await QueryMemoryFiles.shared.read(snapshot: afterCancel.snapshot, history: afterCancel.history, root: root)
            checks["cancelledSummaryNeverPublishesAndQuestionSurvives"] = cancelled == nil && store.book!.chats.count == beforeCancel + 2 && store.queryMemoryStatus.hasPrefix("已停止")
            let result: [String: Any] = ["passed":checks.values.allSatisfy { $0 },"checks":checks,"observations":observations,"messageCount":store.book?.chats.count ?? 0]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("memory-concurrency.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject: ["passed":false,"checks":checks,"error":error.localizedDescription], options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("memory-concurrency.json"))
        }
    }

}

struct ExperienceCompletionHost: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: PDFReaderController
    @State private var summary = false
    @State private var topics = false
    @State private var perspective = false
    @State private var settings = false
    @State private var fullWorkspace = false
    @State private var narrow = false
    @State private var dark = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 14) {
                Text("隔离合成书 · 生产视图").foregroundStyle(.secondary)
                Button("贴便签") { controller.command(.placeNote) }
                Button("摘要") { summary = true }
                Button("按内容整理") { topics = true }
                Button("两种讲解") { perspective = true }
                Button("伴读与对话") { store.readingCompanionVisible.toggle() }
                Button("翻页") { controller.command(.next) }
                Button("返回第一页") { controller.command(.jump(1)) }
                Button("书库") { fullWorkspace = true; store.route = "library" }
                Button("设置") { settings = true }
                Button(narrow ? "宽窗" : "窄窗") { narrow.toggle(); NSApp.windows.first(where: { $0.title == "ReadingBook 便签与十点体验 · 隔离测试" })?.setContentSize(.init(width: narrow ? 620 : 1320, height: 820)) }
                Button(dark ? "浅色" : "深色") { dark.toggle(); NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
                Spacer()
            }.padding(12).buttonStyle(ReadingToolbarButtonStyle()) }
            if fullWorkspace { WorkspaceView().environmentObject(store) }
            else { ReaderWorkspaceView(showPDF: .constant(true), showOutline: .constant(false), bookmarksOnly: .constant(false)).environmentObject(controller) }
        }.environmentObject(store)
            .sheet(isPresented: $summary) { QueryMemoryInspector(onClose: { summary = false }, onSource: { id in summary = false; store.queryHistoryMessageID = id; store.readingCompanionVisible = true; store.readingCompanionTab = "chat" }).environmentObject(store) }
            .sheet(isPresented: $topics) { NoteTopicOrganizer(close: { topics = false }).environmentObject(store) }
            .sheet(isPresented: $settings) { AppSettingsView().environmentObject(store).frame(width: 960, height: 720) }
            .sheet(isPresented: $perspective) {
                VStack(alignment: .leading, spacing: 14) {
                    Button("关闭") { perspective = false }.buttonStyle(ReadingToolbarButtonStyle())
                    if let note = store.book?.activeDocuments.first { DocumentPerspectiveView(document: note).environmentObject(store) }
                }.padding(20).frame(width: 720, height: 600)
            }
    }
}

@main struct ExperienceCompletionMain {
    @MainActor static func main() {
        let path = CommandLine.arguments.dropFirst().first ?? ProcessInfo.processInfo.environment["UX_COMPLETION_DIR"]!
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let workspace = ProcessInfo.processInfo.environment["UX_WORKSPACE_ROOT"] ?? FileManager.default.currentDirectoryPath
        guard root.path.hasPrefix(URL(fileURLWithPath: workspace).standardizedFileURL.path + "/") else { fatalError("Workspace-local test directory required") }
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let runner = ExperienceCompletionRunner(directory: root); app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
