import AppKit
import SwiftUI
import PDFKit
@testable import ReadingCore
@testable import ReadingBook


actor FlowSearchTransport {
    var kinds: [String] = [], offered: Set<String> = [], termsRetained = true
    var rejectedExtraData = true, delayNextRead = false, delayIntent = false, invalidIntent = false
    func configure(delayRead: Bool = false, delayIntent: Bool = false, invalidIntent: Bool = false) {
        delayNextRead = delayRead; self.delayIntent = delayIntent; self.invalidIntent = invalidIntent
    }
    func values() -> (kinds: [String], offered: Set<String>, terms: Bool, data: Bool) { (kinds, offered, termsRetained, rejectedExtraData) }
    func handle(_ request: ProviderClient.Prepared) async throws -> ProviderClient.Result {
        let body = try JSONSerialization.jsonObject(with: request.request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let raw = messages[1]["content"] as! String
        let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        rejectedExtraData = rejectedExtraData && body["tools"] == nil && !raw.contains("私人笔记") && !raw.contains("私人问题")
        let output: String
        if let parts = input["parts"] as? [[String: Any]] {
            kinds.append("read")
            termsRetained = termsRetained && input["possibleKeywords"] as? [String] == ["寒舍", "商议"]
            for part in parts { offered.insert(part["id"] as! String) }
            if delayNextRead { delayNextRead = false; try? await Task.sleep(for: .milliseconds(600)) }
            let rows: [[String: String]] = parts.compactMap { part in
                let text = part["text"] as! String
                guard text.contains("寒舍商议") else { return nil }
                return ["partID": part["id"] as! String, "quote": "寒舍商议", "reason": "这里邀请对方到家中议事"]
            }
            output = String(decoding: try JSONSerialization.data(withJSONObject: ["matches": rows]), as: UTF8.self)
        } else {
            kinds.append("intent")
            if delayIntent { try? await Task.sleep(for: .milliseconds(600)) }
            output = invalidIntent ? "{\"keywords\":[]}" : "{\"keywords\":[\"寒舍\",\"商议\"]}"
        }
        return .init(message: .init(role: "assistant", content: output, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
    }
}

@MainActor private struct ActualRecordCardHost: NSViewRepresentable {
    let record: ReadingRecordDescriptor
    let store: AppStore
    let ready: (NSView) -> Void
    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []
        ready(view)
        return view
    }
    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) { view.rootView = content }
    private var content: AnyView {
        AnyView(ReaderRecordFoldCard(record: record, expanded: .constant(false)) { Text("完整回答") }.environmentObject(store))
    }
}

@MainActor final class AISearchFlowRunner: NSObject, NSApplicationDelegate {
    let output: URL
    let reader = PDFReaderContainerView(), controller = PDFReaderController()
    var window: NSWindow!, checks: [String: Bool] = [:], observations: [String: Any] = [:]
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func settle(_ ms: Int = 150) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }
    func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<60 { if predicate() { return true }; await settle(50) }
        return predicate()
    }
    func visibleText(_ view: NSView) -> String {
        var strings: [String] = [], visited = Set<ObjectIdentifier>()
        func walk(_ value: Any, depth: Int) {
            // SwiftUI's virtual accessibility nodes also expose the informal
            // Cocoa getters without declaring NSAccessibilityProtocol.
            guard depth < 20, visited.count < 1000, let node = value as? NSObject else { return }
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            func read(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
            }
            if let label = read("accessibilityLabel") as? String { strings.append(label) }
            if let text = read("accessibilityValue") as? String { strings.append(text) }
            for child in read("accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return strings.joined(separator: "\n")
    }
    func glyphs(_ view: NSView, capture: String? = nil) -> Set<Int> {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return [] }
        if let capture, let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: output.appendingPathComponent(capture + ".png"))
        }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeMutableBytes { memory in
            let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor); context.fill(.init(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
        }
        var mask = Set<Int>()
        for pixel in 0..<(width * height) {
            let i = pixel * 4
            let sum = Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])
            if sum < 450 && bytes[i + 3] > 200 { mask.insert(pixel) }
        }
        return mask
    }
    func overlap(_ first: Set<Int>, _ second: Set<Int>) -> Double {
        let union = first.union(second).count
        return union == 0 ? 0 : Double(first.intersection(second).count) / Double(union)
    }
    func oracle(_ record: ReadingRecordDescriptor, preview: String, size: NSSize, store: AppStore) -> Set<Int> {
        var expected = record; expected.preview = preview; expected.deferredPreview = nil
        let host = NSHostingView(rootView: ReaderRecordFoldCard(record: expected, expanded: .constant(false)) { Text("完整回答") }.environmentObject(store))
        host.frame = .init(origin: .zero, size: size)
        let reference = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        reference.contentView = host
        defer { reference.contentView = nil; reference.orderOut(nil) }
        return glyphs(host, capture: (preview.isEmpty ? "empty-" : "expected-") + record.id.replacingOccurrences(of: ":", with: "-"))
    }

    func query(_ text: String, field: NSSearchField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func nativeAI(_ source: URL, hash: String, field: NSSearchField, list: PDFSearchResultsList) async throws {
        var calls = 0, forwarded: [String] = [], lateStarted = false
        reader.update(from: PDFReaderView(controller: controller, url: source, sourceHash: hash, onAISearch: { forwarded.append($0) }, onSearchKeywords: { query in
            calls += 1
            if query == "慢请求" { lateStarted = true; try? await Task.sleep(for: .milliseconds(450)); return ["貂蝉"] }
            return query == "English" ? ["English"] : ["貂蝉"]
        }, searchAIIdentity: 1))
        controller.command(.showSearch); query("貂禅", field: field)
        checks["NativeOrdinaryLookupAutomaticallyCorrectsTypo"] = await wait { list.entries.count == 3 && calls == 1 }
        _ = field.sendAction(field.action!, to: field.target); await settle(1100)
        checks["NativeRepeatedLookupReusesSameOwnerKeywordPlan"] = calls == 1 && list.entries.count == 3
        guard let button = descendants(reader, NSButton.self).first(where: { $0.accessibilityLabel() == "AI阅读全文查找：先理解意图，再阅读全文" }) else { throw ReadingError.invalid("Missing AI button") }
        checks["NativeAIButtonHasVisibleIconAndHoverTarget"] = button.image != nil && button.bounds.width >= 40 && button.toolTip?.contains("阅读全文") == true
        button.performClick(nil); await settle()
        checks["NativeAIButtonPassesQueryAndClosesOrdinaryFind"] = forwarded == ["貂禅"] && !controller.isSearchVisible && list.entries.isEmpty
        controller.command(.showSearch); query("慢请求", field: field)
        _ = await wait { lateStarted }; query("English", field: field); await settle(1400)
        checks["NativeLateKeywordsCannotReplaceNewQuery"] = list.entries.count == 1 && list.entries.first?.match == "English"
        lateStarted = false; query("慢请求", field: field); _ = await wait { lateStarted }; controller.command(.hideSearch); await settle(800)
        checks["NativeClosingFindRejectsLateKeywordCompletion"] = !controller.isSearchVisible && list.entries.isEmpty
        var failures = 0
        reader.update(from: PDFReaderView(controller: controller, url: source, sourceHash: hash, onAISearch: { forwarded.append($0) }, onSearchKeywords: { _ in failures += 1; throw ReadingError.invalid("offline fixture") }, searchAIIdentity: 2))
        controller.command(.showSearch); query("貂蝉", field: field); _ = await wait { failures == 1 }; await settle(250)
        checks["NativeAIFailureRetainsOfflineTraditionalMatches"] = list.entries.count == 3 && field.toolTip?.contains("本地结果仍可查看") == true
        reader.update(from: PDFReaderView(controller: controller, url: source, sourceHash: hash, onAISearch: { forwarded.append($0) }, onSearchKeywords: { _ in ["王允"] }, searchAIIdentity: 3))
        query("貂禅", field: field)
        checks["NativeServiceChangeInvalidatesOldGuessedKeywords"] = await wait { list.entries.count == 1 && list.entries.first?.match == "王允" }
        reader.update(from: PDFReaderView(controller: controller, url: source, sourceHash: hash, onAISearch: { forwarded.append($0) }, searchAIIdentity: 4))
        query("貂禅", field: field); await settle(1100)
        checks["NativeNoModelLeavesPlainLookupWithoutFixedFallback"] = list.entries.isEmpty
        controller.command(.hideSearch)
        observations["nativeKeywordCalls"] = calls
    }
    func wholeFlow(store: AppStore) async throws {
        let bookEncoder = JSONEncoder(); bookEncoder.outputFormatting = [.sortedKeys]
        let unchangedBook = try bookEncoder.encode(store.book)
        let config = ProviderSettings(model: "fixture", maxRequestsPerRun: 100, maxOutputTokens: 512, contextWindowTokens: 16_000)
        let texts = (0..<12).map { "第\($0)页：" + String(repeating: "普通原文内容。", count: 30) } + ["最终一页才写：寒舍商议。", " \n"]
        let source = LibrarySourceSnapshot(bookID: "whole-flow", title: "全书隔离书", sourceHash: String(repeating: "b", count: 64), units: texts.enumerated().map { .init(id: "u\($0.offset)", order: $0.offset, chapter: "章", page: $0.offset + 1, text: $0.element) })
        let transport = FlowSearchTransport(), coordinator = AIRequestCoordinator(transport: { try await transport.handle($0) })
        let session = WholeBookSearchSession()
        session.prepare(query: "邀请对方回家讨论", snapshot: source, settings: config)
        checks["WholeBookPreparationDoesNotDispatchAnyModelRequest"] = await wait { session.plan != nil }
        let before = await transport.values()
        checks["WholeBookPreparationActuallyUsesZeroRequests"] = before.kinds.isEmpty && session.completedBatches == 0
        guard let plan = session.plan else { throw ReadingError.invalid("No whole plan: " + session.errorMessage) }
        checks["WholeBookUsesMultipleBatchesAndReportsUnreadEmptyText"] = plan.batches.count > 1 && plan.emptyUnitCount == 1
        session.start(settings: config, apiKey: "", coordinator: coordinator, concurrency: 2)
        checks["ActualWholeBookSessionCompletesReadableOriginal"] = await wait { session.complete || !session.running }
        let final = await transport.values()
        checks["WholeBookIntentIsFirstStepThenEveryBatchReads"] = final.kinds.first == "intent" && final.kinds.filter { $0 == "intent" }.count == 1 && final.kinds.dropFirst().allSatisfy { $0 == "read" } && session.complete
        checks["WholeBookGuessesDoNotFilterOutAnyOriginalPart"] = final.offered == Set(plan.batches.flatMap(\.parts).map(\.id)) && final.terms
        checks["WholeBookFoundLastPageWithExactOriginalLocation"] = session.matches.count == 1 && session.matches.first?.source.page == 13 && session.matches.first?.source.quote == "寒舍商议"
        checks["WholeBookProgressCountsOnlyReadableCompletedUnits"] = session.completedUnits == 13 && session.completedBatches == plan.batches.count && session.complete
        checks["WholeBookUsageIncludesIntentAndReadingSteps"] = session.tokenCost == final.kinds.count * 100
        checks["WholeBookNeverSendsObjectsNotesHistoryOrTools"] = final.data
        checks["WholeBookDoesNotTakeAppStoreBusyFlags"] = !store.isBusy && !store.isQueryBusy
        observations["wholeBookBatchCount"] = plan.batches.count
        observations["wholeBookRequestKinds"] = final.kinds

        let invalid = FlowSearchTransport(); await invalid.configure(invalidIntent: true)
        let failed = WholeBookSearchSession()
        failed.prepare(query: "问", snapshot: source, settings: config); _ = await wait { failed.plan != nil }
        failed.start(settings: config, apiKey: "", coordinator: AIRequestCoordinator(transport: { try await invalid.handle($0) }), concurrency: 2)
        _ = await wait { !failed.running }
        let invalidCalls = await invalid.values()
        checks["InvalidIntentCannotStartFullReadingOrAdvanceProgress"] = invalidCalls.kinds == ["intent"] && failed.completedBatches == 0 && !failed.complete && !failed.errorMessage.isEmpty

        let late = FlowSearchTransport(); await late.configure(delayIntent: true)
        let obsolete = WholeBookSearchSession()
        obsolete.prepare(query: "旧问题", snapshot: source, settings: config); _ = await wait { obsolete.plan != nil }
        obsolete.start(settings: config, apiKey: "", coordinator: AIRequestCoordinator(transport: { try await late.handle($0) }), concurrency: 2)
        for _ in 0..<40 { if !(await late.values()).kinds.isEmpty { break }; await settle(25) }
        obsolete.cancel(clear: true); obsolete.prepare(query: "新问题", snapshot: source, settings: config)
        await settle(850)
        let lateCalls = await late.values()
        checks["NewIntentRejectsOldNoncooperativeCompletion"] = obsolete.plan?.query == "新问题" && obsolete.keywords.isEmpty && obsolete.matches.isEmpty && obsolete.tokenCost == 0 && lateCalls.kinds == ["intent"]

        let paused = FlowSearchTransport(); await paused.configure(delayRead: true)
        let resumable = WholeBookSearchSession(), pausedCoordinator = AIRequestCoordinator(transport: { try await paused.handle($0) })
        resumable.prepare(query: "邀请", snapshot: source, settings: config); _ = await wait { resumable.plan != nil }
        resumable.start(settings: config, apiKey: "", coordinator: pausedCoordinator, concurrency: 2)
        for _ in 0..<80 { if (await paused.values()).kinds.contains("read") { break }; await settle(25) }
        resumable.cancel(); let done = resumable.completedBatches, cost = resumable.tokenCost
        await settle(200)
        checks["StoppingWholeBookRetainsIntentWithoutClaimingUnreadBatches"] = !resumable.running && !resumable.keywords.isEmpty && resumable.completedBatches == done && resumable.tokenCost == cost && !resumable.complete
        resumable.start(settings: config, apiKey: "", coordinator: pausedCoordinator, concurrency: 2)
        _ = await wait { resumable.complete || !resumable.running }
        let resumed = await paused.values()
        checks["ExplicitContinueFinishesWithoutRepeatingIntent"] = resumable.complete && resumed.kinds.filter { $0 == "intent" }.count == 1 && resumable.completedUnits == 13

        var quotaConfig = config; quotaConfig.maxRequestsPerRun = 2
        let quotaTransport = FlowSearchTransport(), quotaCoordinator = AIRequestCoordinator(transport: { try await quotaTransport.handle($0) })
        let quota = WholeBookSearchSession()
        quota.prepare(query: "邀请", snapshot: source, settings: quotaConfig); _ = await wait { quota.plan != nil }
        quota.start(settings: quotaConfig, apiKey: "", coordinator: quotaCoordinator, concurrency: 2)
        _ = await wait { !quota.running }
        let quotaCalls = await quotaTransport.values()
        checks["BudgetStopsAfterIntentAndOneBatchWithoutAutomaticRenewal"] = quotaCalls.kinds == ["intent", "read"] && quota.completedBatches == 1 && !quota.complete && !quota.errorMessage.isEmpty
        quota.start(settings: quotaConfig, apiKey: "", coordinator: quotaCoordinator, concurrency: 2)
        _ = await wait { !quota.running }
        let continuedCalls = await quotaTransport.values()
        checks["ExplicitBudgetContinuationSkipsCompletedBatchAndIntent"] = quota.complete && quota.completedUnits == 13 && continuedCalls.kinds == ["intent", "read", "read"]

        let parallelTransport = FlowSearchTransport(); await parallelTransport.configure(delayRead: true)
        let shared = AIRequestCoordinator(transport: { try await parallelTransport.handle($0) }), parallel = WholeBookSearchSession()
        parallel.prepare(query: "邀请", snapshot: source, settings: config); _ = await wait { parallel.plan != nil }
        parallel.start(settings: config, apiKey: "", coordinator: shared, concurrency: 2)
        for _ in 0..<80 { if (await parallelTransport.values()).kinds.contains("read") { break }; await settle(10) }
        let otherRun = try await shared.beginManagedRun(settings: config, maximumConcurrency: 2)
        let otherReader = AIReader(coordinator: shared, lane: .foreground)
        let independent = try await otherReader.prepareWholeBookSearchIntent(query: "另一问题", languageProfile: plan.languageProfile, settings: config, apiKey: "")
        checks["IndependentAIIntentCompletesWhileWholeBookReadIsInFlight"] = independent.keywords == ["寒舍", "商议"] && parallel.running && parallel.completedBatches == 0
        parallel.cancel(); otherRun.finish(); await shared.endRun(otherRun)
        await settle(650)
        checks["StoppingFullSearchDoesNotInvalidateOtherAIResult"] = independent.tokenCost == 100 && parallel.completedBatches == 0 && !parallel.complete
        checks["FullSearchNeverRewritesBookNotesOrSavedAnalysis"] = try bookEncoder.encode(store.book) == unchangedBook

    }

    func run() async {
        do {
            UserDefaults.standard.setVolatileDomain(["service-profiles": Data("[]".utf8),
                "library.root.path.v1": output.appendingPathComponent("library").path,
                "reader.hoverAutoTranslation": false], forName: UserDefaults.argumentDomain)
            let source = output.appendingPathComponent("scripts.pdf")
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let graphics = CGContext(source as CFURL, mediaBox: &box, nil)!
            let lines = ["貂蟬在此。貂蟬再來。", "貂蝉在此。", "王允問計。 English café."]
            for line in lines {
                graphics.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: false)
                NSString(string: line).draw(at: CGPoint(x: 40, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 22)])
                NSGraphicsContext.restoreGraphicsState(); graphics.endPDFPage()
            }
            graphics.closePDF()
            let original = try Data(contentsOf: source), hash = try BookImporter.sha256(original)
            window = NSWindow(contentRect: .init(x: 120, y: 120, width: 1050, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 简繁查找与记录 · 隔离回归"; window.contentView = reader
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            reader.update(from: PDFReaderView(controller: controller, url: source, sourceHash: hash))
            await settle(500)
            guard let pdf = descendants(reader, PDFView.self).first, let document = pdf.document else { throw ReadingError.invalid("Missing reader") }
            let identity = ObjectIdentifier(document), texts = (0..<document.pageCount).map { document.page(at: $0)?.string }
            controller.command(.showSearch); await settle()
            guard let field = descendants(reader, NSSearchField.self).first, let list = descendants(reader, PDFSearchResultsList.self).first else { throw ReadingError.invalid("Missing find controls") }
            window.makeFirstResponder(field)
            func query(_ text: String) {
                field.stringValue = text
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            query("貂蝉")
            checks["SimplifiedInputFindsBothScriptsWithoutReturn"] = await wait { list.entries.count == 3 && !document.isFinding }
            let simple = list.entries
            checks["RepeatedWordsKeepDistinctOriginalRanges"] = simple.filter { $0.page == 1 }.count == 2 && simple.filter { $0.page == 2 }.count == 1
            checks["SnippetsKeepSourceSpellings"] = simple.filter { $0.page == 1 }.allSatisfy { $0.match == "貂蟬" } && simple.filter { $0.page == 2 }.allSatisfy { $0.match == "貂蝉" }
            checks["EquivalentQueriesDoNotDuplicateNativeHits"] = Set(simple.map { "\($0.page):\($0.range.location):\($0.range.length)" }).count == 3
            query("貂蟬")
            checks["TraditionalInputFindsBothScriptsWithoutReturn"] = await wait { list.entries.count == 3 && !document.isFinding }
            checks["BothScriptQueriesReturnSameSourceLocations"] = Set(list.entries.map { "\($0.page):\($0.range.location):\($0.range.length)" }) == Set(simple.map { "\($0.page):\($0.range.location):\($0.range.length)" })
            query("貂蝉"); query("English")
            checks["LatestQueryRejectsPreviousScriptResults"] = await wait { list.entries.count == 1 && list.entries.first?.match == "English" && !document.isFinding }
            checks["EnglishQueryStillLocatesOriginalPage"] = list.entries.first?.page == 3
            query("貂蟬"); query(""); await settle(800)
            checks["ClearedQueryCannotReceiveLateMatches"] = list.entries.isEmpty && list.isHidden
            query("貂蝉"); controller.command(.hideSearch); await settle(800)
            checks["CloseCancelsPendingMultiStringSearch"] = !controller.isSearchVisible && list.entries.isEmpty && list.isHidden
            checks["SearchKeepsOneDisplayDocument"] = pdf.document.map(ObjectIdentifier.init) == identity
            checks["SearchDoesNotRewriteOriginalTextOrBytes"] = try Data(contentsOf: source) == original && texts == (0..<document.pageCount).map { document.page(at: $0)?.string }
            observations["scriptHits"] = simple.map { ["page": $0.page, "range": NSStringFromRange($0.range), "match": $0.match] as [String: Any] }
            try await nativeAI(source, hash: hash, field: field, list: list)
            reader.shutdown()

            let store = AppStore()
            var book = BookProject(id: "record-projection-native", title: "隔离记录", originalName: "fixture.pdf", sourceHash: hash,
                units: [.init(id: "u1", order: 0, chapter: "一", page: 1, text: lines[0])])
            book.documents = [.init(id: "n1", title: "笔记")]
            for i in 0..<120 {
                book.chats.append(.init(id: "q\(i)", role: "user", content: "问题\(i)"))
                book.chats.append(.init(id: "a\(i)", role: "assistant", content: "**答案\(i)** [unit:u1]，保留原文来源。"))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(book)
            store.books = [book]; store.bookID = book.id
            let state = ReaderRecordBrowserState()
            var prepared = false, shown: [String: ReadingRecordDescriptor] = [:], actualCards: [String: NSView] = [:]
            let offered = ["chat:a119", "chat:a0"]
            let host = NSHostingView(rootView: ScrollView { ReaderRecordSections(state: state, ids: offered, focusedID: offered[0], onFocusReady: { _ in prepared = true }) { record, _ in
                let _ = shown.updateValue(record, forKey: record.id)
                ActualRecordCardHost(record: record, store: store, ready: { actualCards[record.id] = $0 }).frame(width: 1000, height: 130)
            }}.environmentObject(store))
            window.contentView = host; host.frame = .init(x: 0, y: 0, width: 1050, height: 740)
            checks["ActualRecordBrowserCompletesScopedPreparation"] = await wait { prepared }
            host.layoutSubtreeIfNeeded(); await settle()
            checks["ActualRecordBrowserShowsOnlyOfferedRecords"] = Set(shown.keys) == Set(offered)
            checks["ActualRecordBrowserKeepsEarlierQuestionTitle"] = shown["chat:a119"]?.title == "回答：问题119"
            checks["ActualRecordBrowserDefersBodyHintsUntilRowsAppear"] = shown.count == offered.count && shown.values.allSatisfy { $0.preview.isEmpty && $0.deferredPreview != nil }
            var pixelMatches: [String: Double] = [:], emptyMatches: [String: Double] = [:]
            checks["ActualRecordBrowserShowsCleanBodyHint"] = await wait {
                host.layoutSubtreeIfNeeded()
                for (id, answer) in [(offered[0], "119"), (offered[1], "0")] {
                    guard let actual = actualCards[id], let record = shown[id], actual.bounds.width > 0 else { return false }
                    let mask = self.glyphs(actual, capture: "actual-" + answer)
                    // Expected text is an independent literal, never obtained
                    // from the deferred parser or its output under test.
                    let expected = self.oracle(record, preview: "答案\(answer) 原文，保留原文来源。", size: actual.bounds.size, store: store)
                    let empty = self.oracle(record, preview: "", size: actual.bounds.size, store: store)
                    pixelMatches[id] = self.overlap(mask, expected)
                    emptyMatches[id] = self.overlap(expected, empty)
                }
                return pixelMatches.count == 2 && pixelMatches.values.allSatisfy { $0 > 0.97 }
            }
            checks["IndependentPixelOracleRejectsMissingBodyHint"] = emptyMatches.count == 2 && emptyMatches.values.allSatisfy { $0 < 0.85 }
            checks["BothActualNativeCardRastersMatchLiteralPreview"] = pixelMatches.count == 2 && pixelMatches.values.allSatisfy { $0 > 0.97 }
            observations["actualCardGlyphOverlap"] = pixelMatches
            observations["emptyHintNegativeControlOverlap"] = emptyMatches
            observations["displayedRecordText"] = visibleText(host)
            checks["ActualRecordBrowserDoesNotArchiveOrRewriteMessages"] = try encoder.encode(store.books[0]) == before
            try await wholeFlow(store: store)
            observations["realNetworkRequests"] = 0
        } catch { observations["error"] = String(describing: error); checks["completed"] = false }
        let result: [String: Any] = ["status": checks.values.allSatisfy { $0 } ? "passed" : "failed", "checks": checks, "observations": observations]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        NSApp.terminate(nil)
    }
}
@main enum AISearchFlowMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ProcessInfo.processInfo.environment["AI_SEARCH_FLOW_OUTPUT"]!)
        let runner = AISearchFlowRunner(output); app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
