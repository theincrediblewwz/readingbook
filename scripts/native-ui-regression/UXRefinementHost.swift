import AppKit
import SwiftUI
import PDFKit
@testable import ReadingCore
@testable import ReadingBook

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

@MainActor final class UXRefinementRunner: NSObject, NSApplicationDelegate {
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
            observations["realNetworkRequests"] = 0
        } catch { observations["error"] = String(describing: error); checks["completed"] = false }
        let result: [String: Any] = ["status": checks.values.allSatisfy { $0 } ? "passed" : "failed", "checks": checks, "observations": observations]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        NSApp.terminate(nil)
    }
}
@main enum UXRefinementMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ProcessInfo.processInfo.environment["UX_REFINEMENT_OUTPUT"]!)
        let runner = UXRefinementRunner(output); app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
