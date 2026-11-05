import AppKit
import PDFKit
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

actor InlineFindTransport {
    var kinds: [String] = [], offered = Set<String>(), safe = true
    var delayRead = false, delayIntent = false
    func configure(read: Bool = false, intent: Bool = false) { delayRead = read; delayIntent = intent }
    func values() -> (kinds: [String], offered: Set<String>, safe: Bool) { (kinds, offered, safe) }
    func handle(_ request: ProviderClient.Prepared) async throws -> ProviderClient.Result {
        let body = try JSONSerialization.jsonObject(with: request.request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]], raw = messages[1]["content"] as! String
        let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        safe = safe && body["tools"] == nil && !raw.contains("私人笔记") && !raw.contains("私人问题")
        let reply: String
        if let parts = input["parts"] as? [[String: Any]] {
            kinds.append("read"); offered.formUnion(parts.map { $0["id"] as! String })
            if delayRead { delayRead = false; try? await Task.sleep(for: .milliseconds(600)) }
            let matches: [[String: String]] = parts.compactMap {
                ($0["text"] as! String).contains("寒舍商议") ? ["partID": $0["id"] as! String, "quote": "寒舍商议", "reason": "邀请对方回家商议"] : nil
            }
            reply = String(decoding: try JSONSerialization.data(withJSONObject: ["matches": matches]), as: UTF8.self)
        } else {
            kinds.append("intent")
            if delayIntent { delayIntent = false; try? await Task.sleep(for: .milliseconds(600)) }
            reply = "{\"keywords\":[\"寒舍\",\"商议\"]}"
        }
        return .init(message: .init(role: "assistant", content: reply, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 100)
    }
}

@MainActor final class ReaderFindRunner: NSObject, NSApplicationDelegate {
    let output: URL, reader = PDFReaderContainerView(), controller = PDFReaderController()
    var window: NSWindow!, checks: [String: Bool] = [:], observations: [String: Any] = [:]
    var models: [ReaderInlineAISearchModel] = []
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ note: Notification) { Task { await run() } }
    func settle(_ ms: Int = 100) async { reader.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(ms)); reader.layoutSubtreeIfNeeded() }
    func wait(_ predicate: () -> Bool) async -> Bool { for _ in 0..<80 { if predicate() { return true }; await settle(25) }; return predicate() }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func aiButton() -> NSButton? { views(reader).compactMap { $0 as? NSButton }.first { $0.toolTip == "AI阅读全文查找：先理解意图，再阅读全文" } }
    func hosted() -> NSView? { views(reader).first { $0 is NSHostingView<AnyView> } }
    func textAndIDs(_ root: NSView) -> String {
        var strings: [String] = [], seen = Set<ObjectIdentifier>()
        func walk(_ value: Any, depth: Int) {
            guard depth < 25, seen.count < 3000, let node = value as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return }
            func read(_ name: String) -> Any? { let s = NSSelectorFromString(name); return node.responds(to: s) ? node.perform(s)?.takeUnretainedValue() : nil }
            for k in ["accessibilityLabel", "accessibilityValue", "accessibilityIdentifier"] { if let s = read(k) as? String { strings.append(s) } }
            for child in read("accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0); return strings.joined(separator: "\n")
    }
    func raster(_ name: String) {
        guard let host = hosted(), let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
    }
    struct Pixel: Hashable { let x: Int; let y: Int }
    func mask(_ view: NSView, blueOnly: Bool = false, normalizeSecondary: Bool = false) -> Set<Pixel> {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return [] }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeMutableBytes { memory in
            let gc = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            gc.setFillColor(NSColor.white.cgColor); gc.fill(.init(x: 0, y: 0, width: width, height: height)); gc.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
        }
        // A secondary label resolves differently in an active window and an
        // offscreen reference window. Compare glyph coverage at half its own
        // ink contrast; require visible contrast rather than accepting blank.
        let rightStart = width - 300 * max(1, Int((view.window?.backingScaleFactor ?? 1) / 2))
        var secondaryMin = 765
        if normalizeSecondary {
            for y in 0..<height { for x in max(0, rightStart)..<width {
                let i = (y * width + x) * 4
                secondaryMin = min(secondaryMin, Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]))
            } }
        }
        var pixels = Set<Pixel>()
        for index in 0..<(width * height) {
            let i = index * 4, red = Int(bytes[i]), green = Int(bytes[i + 1]), blue = Int(bytes[i + 2])
            let threshold = normalizeSecondary && index % width >= rightStart ? (765 + secondaryMin) / 2 : 450
            let ink = blueOnly ? blue > 100 && blue > red + 50 && blue > green + 20 && red + green + blue < 450
                : red + green + blue < threshold && (!normalizeSecondary || index % width < rightStart || secondaryMin < 665)
            if ink { pixels.insert(.init(x: index % width, y: index / width)) }
        }
        guard let x = pixels.map(\.x).min(), let y = pixels.map(\.y).min() else { return [] }
        return Set(pixels.map { .init(x: $0.x - x, y: $0.y - y) })
    }
    func similarity(_ actual: Set<Pixel>, _ expected: Set<Pixel>) -> Double {
        guard !expected.isEmpty else { return actual.isEmpty ? 1 : 0 }
        var best = 0.0
        for dx in -1...1 { for dy in -1...1 {
            let shifted = Set(actual.map { Pixel(x: $0.x + dx, y: $0.y + dy) })
            best = max(best, Double(shifted.intersection(expected).count) / Double(shifted.union(expected).count))
        } }
        return best
    }
    func reference<V: View>(_ content: V, size: NSSize, blueOnly: Bool = false) -> Set<Pixel> {
        let host = NSHostingView(rootView: content); host.frame = .init(origin: .zero, size: size)
        let reference = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        reference.contentView = host
        defer { reference.contentView = nil; reference.orderOut(nil) }
        return mask(host, blueOnly: blueOnly)
    }
    func controlPixels() -> (actual: Set<Pixel>, expected: Set<Pixel>, absent: Set<Pixel>) {
        let size = NSSize(width: 160, height: 44)
        let expected = reference(Button("开始 AI 查找") {}.buttonStyle(ReadingToolbarButtonStyle(selected: true)), size: size, blueOnly: true)
        let absent = reference(Button(" ") {}.buttonStyle(ReadingToolbarButtonStyle(selected: true)), size: size, blueOnly: true)
        return (hosted().map { mask($0, blueOnly: true) } ?? [], expected, absent)
    }
    func resultPixels() -> (actual: Set<Pixel>, expected: Set<Pixel>, absent: Set<Pixel>) {
        guard let host = hosted(), let scroll = views(host).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView else { return ([], [], []) }
        // Independent literal oracle: no query result, model state or snippet
        // parser supplies the expected quote, surrounding text or page locator.
        var text = AttributedString("最终一页：请到"); text.foregroundColor = Palette.ink.opacity(0.65)
        var quote = AttributedString("寒舍商议"); quote.foregroundColor = Palette.ink; quote.backgroundColor = Color.yellow.opacity(0.24); text.append(quote)
        var end = AttributedString("。"); end.foregroundColor = Palette.ink.opacity(0.65); text.append(end)
        let row = Button {} label: {
            HStack(spacing: 12) {
                Text(text).font(.system(size: 14)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text("第 13 页 · 行 1–1").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 130, alignment: .trailing)
            }.padding(.horizontal, 10).frame(minHeight: 34).contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(ReadingQuietButtonStyle())
        let expectedHost = NSHostingView(rootView: ScrollView { LazyVStack(spacing: 0) { row } })
        expectedHost.frame = .init(origin: .zero, size: scroll.bounds.size)
        let referenceWindow = NSWindow(contentRect: expectedHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        referenceWindow.contentView = expectedHost
        defer { referenceWindow.contentView = nil; referenceWindow.orderOut(nil) }
        expectedHost.layoutSubtreeIfNeeded(); expectedHost.displayIfNeeded()
        let referenceDocument = views(expectedHost).compactMap { $0 as? NSScrollView }.first?.documentView
        if let referenceDocument {
            for (name, view) in [("actual-result-row", document), ("expected-result-row", referenceDocument)] {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
                }
            }
        }
        let expected = referenceDocument.map { mask($0, normalizeSecondary: true) } ?? []
        let absent = reference(Color.clear, size: document.bounds.size)
        observations["resultDocumentBounds"] = NSStringFromRect(document.bounds)
        observations["referenceResultDocumentBounds"] = referenceDocument.map { NSStringFromRect($0.bounds) } ?? "missing"
        observations["resultPixelWidth"] = document.convertToBacking(document.bounds).width
        return (mask(document, normalizeSecondary: true), expected, absent)
    }

    func run() async {
        do {
            UserDefaults.standard.setVolatileDomain(["service-profiles": Data("[]".utf8), "library.root.path.v1": output.appendingPathComponent("library").path,
                "reader.hoverAutoTranslation": false], forName: UserDefaults.argumentDomain)
            let url = output.appendingPathComponent("source.pdf")
            let texts = (0..<12).map { "第\($0 + 1)页：貂蟬。" + String(repeating: "普通原文内容。", count: 30) } + ["最终一页：请到寒舍商议。"]
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let gc = CGContext(url as CFURL, mediaBox: &box, nil)!
            for text in texts {
                gc.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: gc, flipped: false)
                NSString(string: String(text.prefix(32))).draw(at: .init(x: 30, y: 710), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
                NSGraphicsContext.restoreGraphicsState(); gc.endPDFPage()
            }
            gc.closePDF()
            let bytes = try Data(contentsOf: url), hash = try BookImporter.sha256(bytes)
            let transport = InlineFindTransport(), coordinator = AIRequestCoordinator(transport: { try await transport.handle($0) })
            let store = AppStore(sharedAIRequests: coordinator)
            let configuration = ProviderSettings(model: "fixture", maxRequestsPerRun: 100, maxOutputTokens: 512, contextWindowTokens: 16_000)
            store.settings = configuration
            var project = BookProject(id: "inline-book", title: "隔离全文书", originalName: "source.pdf", sourceHash: hash, units: texts.enumerated().map { .init(id: "p\($0.offset)", order: $0.offset, chapter: "一", page: $0.offset + 1, text: $0.element) })
            project.documents = [.init(id: "private", title: "私人笔记")]; project.chats = [.init(id: "private-chat", role: "user", content: "私人问题")]
            store.books = [project]; store.bookID = project.id; store.selectedUnitID = project.units[0].id
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let before = try encoder.encode(store.book)
            let owner = WorkspacePickerOwner(store: store), repository = store.repository.publicationOwner
            var input = PDFReaderView(controller: controller, url: url, sourceHash: hash, makeInlineAISearch: { [weak self] query in
                guard let model = store.makeInlinePDFSearch(query, owner: owner, repositoryOwner: repository) else { return nil }
                self?.models.append(model); return model
            }, inlineSearchOwner: repository, searchAIIdentity: store.readingSearchAIIdentity)
            window = NSWindow(contentRect: .init(x: 90, y: 80, width: 1100, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 阅读页内联查找 · 隔离回归"; window.contentView = reader
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); reader.setReducedMotion(true); reader.update(from: input)
            checks["NativePDFReady"] = await wait { controller.isReady }
            guard let field = views(reader).compactMap({ $0 as? NSSearchField }).first, let pdf = views(reader).compactMap({ $0 as? PDFView }).first,
                  let document = pdf.document, let list = views(reader).compactMap({ $0 as? PDFSearchResultsList }).first else { throw ReadingError.invalid("Missing native find") }
            let identity = ObjectIdentifier(document)
            func query(_ value: String) { field.stringValue = value; field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field)) }
            controller.command(.showSearch); await settle()
            checks["PreviousAndNextResultButtonsAreAbsent"] = !views(reader).compactMap { $0 as? NSButton }.contains { ["上一个搜索结果", "下一个搜索结果"].contains($0.toolTip ?? "") }
            checks["TwoFindButtonsHaveIconsAndHoverTargets"] = views(reader).compactMap { $0 as? NSButton }.filter { ["普通查找", "AI阅读全文查找：先理解意图，再阅读全文"].contains($0.toolTip ?? "") }.allSatisfy { $0 is ReadingNativeHoverButton && $0.image != nil && $0.bounds.height >= 43.5 }
            checks["AIHasExplicitVisibleAIText"] = aiButton()?.title == "AI" && (aiButton()?.bounds.width ?? 0) >= 59
            query("邀请对方回家讨论"); aiButton()?.performClick(nil)
            guard let model = models.last else { throw ReadingError.invalid("No production inline model") }
            checks["InlinePlanIsPrepared"] = await wait { model.session.plan != nil }
            checks["PreparationNeverDispatchesNetwork"] = await transport.values().kinds.isEmpty
            checks["NativeFindStaysVisibleWithoutLibraryModal"] = controller.isSearchVisible && hosted() != nil && !store.showingLibrarySearch && store.baseWorkspaceRoute == "reader" && store.auxiliaryPresentation == nil
            let modelCount = models.count; aiButton()?.performClick(nil); await settle()
            checks["RepeatedAIClickKeepsOneEstimateAndSession"] = models.count == modelCount
            observations["estimateAXText"] = hosted().map(textAndIDs) ?? ""
            var control = controlPixels()
            checks["EstimateControlsAppearInsideNativePanel"] = await wait { control = self.controlPixels(); return self.similarity(control.actual, control.expected) > 0.97 }
            checks["ControlPixelOracleRejectsMissingLabel"] = control.expected.count > 100 && similarity(control.absent, control.expected) < 0.85
            observations["estimateControlGlyphOverlap"] = similarity(control.actual, control.expected)
            let hostFrame = hosted().map { $0.convert($0.bounds, to: reader) } ?? .zero
            checks["InlineBodyHasUsableWidthBelowSearchField"] = hostFrame.width >= 500 && hostFrame.height >= 119 && field.frame.height >= 43.5
            raster("estimate")
            model.start(); checks["TwoStepSearchCompletesInPlace"] = await wait { model.session.complete || !model.session.running }
            let sent = await transport.values()
            checks["IntentRunsOnceBeforeAllOriginalBatches"] = sent.kinds.first == "intent" && sent.kinds.filter { $0 == "intent" }.count == 1 && model.session.complete && model.session.plan.map { sent.offered == Set($0.batches.flatMap(\.parts).map(\.id)) } == true
            checks["PrivateNotesHistoryAndToolsNeverSent"] = sent.safe
            checks["ResultHasExactOriginalQuoteAndPage"] = model.session.matches.count == 1 && model.session.matches.first?.source.page == 13 && model.session.matches.first?.source.quote == "寒舍商议"
            let savedHit = model.session.matches.first
            await settle(250)
            observations["resultAXText"] = hosted().map(textAndIDs) ?? ""
            var result = resultPixels()
            checks["RealResultRowIsRenderedInInlineHost"] = await wait {
                result = self.resultPixels()
                let split = Int((self.observations["resultPixelWidth"] as? Double ?? 0) / 2)
                let quote = self.similarity(Set(result.actual.filter { $0.x < split }), Set(result.expected.filter { $0.x < split }))
                let locator = self.similarity(Set(result.actual.filter { $0.x >= split }), Set(result.expected.filter { $0.x >= split }))
                self.observations["quoteGlyphOverlap"] = quote; self.observations["locatorGlyphOverlap"] = locator
                return !result.expected.filter { $0.x >= split }.isEmpty && quote > 0.97 && locator > 0.97
            }
            checks["ResultPixelOracleRejectsMissingRow"] = result.expected.count > 100 && similarity(result.absent, result.expected) < 0.85
            observations["resultRowGlyphOverlap"] = similarity(result.actual, result.expected)
            if let hit = model.session.matches.first { model.pick(hit) }
            checks["InlineResultNavigatesSamePDFToActualPage"] = await wait { controller.page == 13 }
            checks["ResultNavigationKeepsFindAndUnderlyingReader"] = controller.isSearchVisible && pdf.document.map(ObjectIdentifier.init) == identity && !store.showingLibrarySearch
            controller.command(.setThumbnails(true)); await settle(200)
            checks["ThumbnailsRemainBelowInlineResults"] = controller.thumbnailFrame.minY >= controller.chromeFrame.maxY + 11
            raster("results")
            controller.command(.setThumbnails(false))
            query("貂蝉"); await settle(700)
            checks["EditingQueryReturnsToOrdinaryAutoScriptLookup"] = hosted() == nil && list.entries.count == 12 && controller.isSearchVisible
            checks["OrdinaryLookupKeepsBothControlsAndNativeFocus"] = aiButton()?.isHidden == false && field.bounds.height >= 43.5

            query("慢查找"); aiButton()?.performClick(nil); guard let paused = models.last else { throw ReadingError.invalid("No paused model") }
            _ = await wait { paused.session.plan != nil }; await transport.configure(read: true)
            let prior = await transport.values().kinds.count
            paused.start()
            for _ in 0..<80 { if await transport.values().kinds.dropFirst(prior).contains("read") { break }; await settle(15) }
            paused.session.cancel(); let completed = paused.session.completedBatches, cost = paused.session.tokenCost
            await settle(700)
            checks["StopPreservesOnlyCompletedWorkAndRejectsLateRead"] = !paused.session.running && !paused.session.keywords.isEmpty && paused.session.completedBatches == completed && paused.session.tokenCost == cost && !paused.session.complete
            paused.start(); _ = await wait { paused.session.complete || !paused.session.running }
            let transportAfterPhase1 = await transport.values()
            checks["ExplicitContinueCompletesSamePlanWithoutNewIntent"] = paused.session.complete && transportAfterPhase1.kinds.dropFirst(prior).filter { $0 == "intent" }.count == 1

            query("关闭期间"); aiButton()?.performClick(nil); let closing = models.last!
            _ = await wait { closing.session.plan != nil }; await transport.configure(intent: true); let closeBefore = await transport.values().kinds.count
            closing.start(); for _ in 0..<80 { if await transport.values().kinds.count > closeBefore { break }; await settle(10) }
            controller.command(.hideSearch); await settle(750)
            let transportAfterPhase2 = await transport.values()
            checks["CloseCancelsNoncooperativeIntentAndLateResult"] = closing.session.matches.isEmpty && closing.session.plan == nil && !closing.session.running && transportAfterPhase2.kinds.count == closeBefore + 1
            checks["CloseRestoresPDFResponderAndRemovesInlineHost"] = !controller.isSearchVisible && hosted() == nil && window.firstResponder === pdf

            controller.command(.showSearch); query("更换模型"); aiButton()?.performClick(nil); let settingModel = models.last!
            _ = await wait { settingModel.session.plan != nil }; let settingsBefore = await transport.values().kinds.count
            store.settings.model = "other-fixture"; settingModel.start(); await settle(120)
            let transportAfterPhase3 = await transport.values()
            checks["ProductionFactoryRejectsChangedModelBeforeDispatch"] = !(settingModel.issue.isEmpty) && transportAfterPhase3.kinds.count == settingsBefore
            input.searchAIIdentity = store.readingSearchAIIdentity; reader.update(from: input); await settle()
            checks["ModelIdentityUpdateClosesOldInlineSession"] = hosted() == nil && settingModel.session.plan == nil
            store.settings = configuration; input.searchAIIdentity = store.readingSearchAIIdentity; reader.update(from: input)

            query("原文变化"); aiButton()?.performClick(nil); let changed = models.last!
            _ = await wait { changed.session.plan != nil }; await transport.configure(intent: true); let changedBefore = await transport.values().kinds.count
            changed.start(); for _ in 0..<80 { if await transport.values().kinds.count > changedBefore { break }; await settle(10) }
            var updated = project; updated.units[12].text = "同一个sourceHash下，文字也已经改变。"; store.books = [updated]
            await settle(800)
            let transportAfterPhase4 = await transport.values()
            checks["SameHashOriginalEditRejectsIntentAndUnreadBatches"] = !changed.session.running && !changed.session.errorMessage.isEmpty && changed.session.matches.isEmpty && changed.session.completedBatches == 0 && transportAfterPhase4.kinds.count == changedBefore + 1
            if let hit = savedHit { changed.pick(hit) }
            checks["StaleQuoteCannotNavigateAfterOriginalEdit"] = !changed.issue.isEmpty
            store.books = [project]
            controller.command(.hideSearch); controller.command(.showSearch); query("Unicode原文版本")
            var decomposed = project; decomposed.units[0].text += " Cafe\u{301}"
            store.books = [decomposed]; aiButton()?.performClick(nil); let unicode = models.last!
            _ = await wait { unicode.session.plan != nil }; await transport.configure(intent: true)
            let unicodeBefore = await transport.values().kinds.count
            unicode.start(); for _ in 0..<80 { if await transport.values().kinds.count > unicodeBefore { break }; await settle(10) }
            var composed = decomposed; composed.units[0].text = composed.units[0].text.precomposedStringWithCanonicalMapping
            store.books = [composed]; await settle(800)
            let unicodeAfter = await transport.values()
            checks["CanonicallyEqualButDifferentOriginalBytesCannotReuseValidation"] = decomposed.units[0].text == composed.units[0].text && !decomposed.units[0].text.utf8.elementsEqual(composed.units[0].text.utf8) && !unicode.session.errorMessage.isEmpty && unicode.session.completedBatches == 0 && unicodeAfter.kinds.count == unicodeBefore + 1
            store.books = [project]

            controller.command(.hideSearch); controller.command(.showSearch); query("旧书库"); aiButton()?.performClick(nil); let oldOwner = models.last!
            _ = await wait { oldOwner.session.plan != nil }; let ownerBefore = await transport.values().kinds.count
            store.repository = LibraryRepository(rootURL: output.appendingPathComponent("replacement-library"))
            oldOwner.start(); await settle(100)
            let transportAfterPhase5 = await transport.values()
            checks["SameRootReplacementRepositoryRejectsOldSession"] = !oldOwner.issue.isEmpty && transportAfterPhase5.kinds.count == ownerBefore
            input.inlineSearchOwner = store.repository.publicationOwner; reader.update(from: input); await settle()
            checks["RepositoryIdentityUpdateRemovesOldHost"] = hosted() == nil && oldOwner.session.plan == nil
            checks["OldCapturedFactoryCannotCreateForNewRepository"] = store.makeInlinePDFSearch("问题", owner: owner, repositoryOwner: repository) == nil

            let currentRepo = store.repository.publicationOwner
            input.makeInlineAISearch = { [weak self] query in
                guard let value = store.makeInlinePDFSearch(query, owner: WorkspacePickerOwner(store: store), repositoryOwner: currentRepo) else { return nil }; self?.models.append(value); return value
            }; reader.update(from: input)
            controller.command(.showSearch); query("新书库"); aiButton()?.performClick(nil); let oldRoot = models.last!
            _ = await wait { oldRoot.session.plan != nil }; let rootBefore = await transport.values().kinds.count
            store.libraryRootURL = output.appendingPathComponent("new-root"); oldRoot.start(); await settle(100)
            let transportAfterPhase6 = await transport.values()
            checks["RootChangeRejectsOldSessionBeforeDispatch"] = !oldRoot.issue.isEmpty && transportAfterPhase6.kinds.count == rootBefore
            controller.command(.hideSearch)
            store.libraryRootURL = owner.libraryRoot; store.settings.model = ""; input.searchAIIdentity = store.readingSearchAIIdentity; reader.update(from: input)
            controller.command(.showSearch); query("没有模型"); aiButton()?.performClick(nil); await settle(150)
            let missing = models.last!, noModelCalls = await transport.values().kinds.count
            missing.start(); await settle()
            let transportAfterPhase7 = await transport.values()
            checks["MissingModelExplainsInsteadOfRoutingOrFixedResults"] = !missing.hasModel && missing.issue.contains("模型设置") && missing.session.plan == nil && hosted() != nil && !store.showingLibrarySearch && transportAfterPhase7.kinds.count == noModelCalls
            controller.command(.hideSearch)
            checks["BookNotesAnalysisAndHistoryBytesPreserved"] = try encoder.encode(store.book) == before
            let finalPDFBytes = try Data(contentsOf: url)
            checks["DisplayPDFIdentityAndBytesPreserved"] = pdf.document.map(ObjectIdentifier.init) == identity && finalPDFBytes == bytes
            checks["IndependentAIBusyFlagsNeverTaken"] = !store.isBusy && !store.isQueryBusy
            observations["requests"] = await transport.values().kinds
            observations["checkCount"] = checks.count
            observations["realNetworkRequests"] = 0
            reader.shutdown(); window.orderOut(nil)
        } catch { checks["completed"] = false; observations["error"] = String(describing: error) }
        let result: [String: Any] = ["status": checks.values.allSatisfy { $0 } ? "passed" : "failed", "checks": checks, "observations": observations]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"), options: .atomic)
        NSApp.terminate(nil)
    }
}
@main enum ReaderFindMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let runner = ReaderFindRunner(URL(fileURLWithPath: CommandLine.arguments[1])); app.delegate = runner
        app.run(); withExtendedLifetime(runner) {}
    }
}
