import AppKit
import SwiftUI
import PDFKit
@testable import ReadingCore
@testable import ReadingBook

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
            var prepared = false, shown: [String: ReadingRecordDescriptor] = [:]
            let offered = ["chat:a119", "chat:a0"]
            let host = NSHostingView(rootView: ReaderRecordSections(state: state, ids: offered, focusedID: offered[0], onFocusReady: { _ in prepared = true }) { record, _ in
                let _ = shown.updateValue(record, forKey: record.id)
                ReaderRecordFoldCard(record: record, expanded: .constant(false)) { Text("完整回答") }
            }.environmentObject(store))
            window.contentView = host; host.frame = .init(x: 0, y: 0, width: 1050, height: 740)
            checks["ActualRecordBrowserCompletesScopedPreparation"] = await wait { prepared }
            host.layoutSubtreeIfNeeded(); await settle()
            checks["ActualRecordBrowserShowsOnlyOfferedRecords"] = Set(shown.keys) == Set(offered)
            checks["ActualRecordBrowserKeepsEarlierQuestionTitle"] = shown["chat:a119"]?.title == "回答：问题119"
            checks["ActualRecordBrowserDefersBodyHintsUntilRowsAppear"] = shown.count == offered.count && shown.values.allSatisfy { $0.preview.isEmpty && $0.deferredPreview != nil }
            checks["ActualRecordBrowserShowsCleanBodyHint"] = await wait {
                let text = self.visibleText(host)
                return text.contains("答案119 原文") && text.contains("答案0 原文") && !text.contains("unit:") && !text.contains("**")
            }
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
