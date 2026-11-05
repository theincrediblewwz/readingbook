import AppKit
import PDFKit
import SwiftUI
@testable import ReadingCore
@testable import ReadingBook

@MainActor final class SearchPrecisionRunner: NSObject, NSApplicationDelegate {
    let output: URL, reader = PDFReaderContainerView(), controller = PDFReaderController()
    var window: NSWindow!, checks: [String: Bool] = [:]
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func settle(_ ms: Int = 40) async { reader.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(ms)); reader.layoutSubtreeIfNeeded() }
    func wait(_ condition: () -> Bool) async -> Bool { for _ in 0..<100 { if condition() { return true }; await settle() }; return condition() }
    func run() async {
        do {
            UserDefaults.standard.setVolatileDomain(["service-profiles": Data("[]".utf8), "library.root.path.v1": output.appendingPathComponent("library").path,
                "reader.hoverAutoTranslation": false], forName: UserDefaults.argumentDomain)
            let source = output.appendingPathComponent("source.pdf")
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let gc = CGContext(source as CFURL, mediaBox: &box, nil)!
            for page in 1...14 {
                gc.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: gc, flipped: false)
                for (index, text) in ["三國演義", page == 14 ? "貂蟬在此。貂蟬。" : "連環計"].enumerated() {
                    NSString(string: text).draw(at: .init(x: 30, y: 720-index*60), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
                }
                NSGraphicsContext.restoreGraphicsState(); gc.endPDFPage()
            }
            gc.closePDF(); let bytes = try Data(contentsOf: source), hash = try BookImporter.sha256(bytes)
            var calls = 0, lateStarted = false
            var input = PDFReaderView(controller: controller, url: source, sourceHash: hash, onAISearch: { _ in }, searchAIIdentity: 1,
                onSearchAssistance: { query in
                    calls += 1
                    if query == "late" { lateStarted = true; try? await Task.sleep(for: .milliseconds(500)) }
                    return try .init(variants: ["貂蝉", "貂蟬"], related: ["三國演義", "連環計"])
                })
            window = NSWindow(contentRect: .init(x: 70, y: 70, width: 1100, height: 800), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 精确查找 · 隔离回归"; window.contentView = reader; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            reader.update(from: input); checks["ActualPDFReady"] = await wait { controller.isReady }
            guard let field = views(reader).compactMap({ $0 as? NSSearchField }).first,
                  let list = views(reader).compactMap({ $0 as? PDFSearchResultsList }).first,
                  let pdf = views(reader).compactMap({ $0 as? PDFView }).first else { throw ReadingError.invalid("No native find") }
            let identity = pdf.document.map(ObjectIdentifier.init)
            func query(_ value: String) { field.stringValue = value; field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field)) }
            func toggle() -> NSButton? { views(list).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("更多相关结果") || $0.title.hasPrefix("收起相关结果") } }
            controller.command(.showSearch); query("貂禅")
            checks["TypoAndTraditionalVariantsFindOnlyTwoRealNames"] = await wait { calls == 1 && list.entries.count == 2 && list.visibleRowCount == 3 }
            checks["HeadersNeverPollutePrimaryResults"] = list.entries.allSatisfy { $0.match == "貂蟬" && $0.page == 14 }
            checks["RelatedSectionIsLastCollapsedRow"] = list.table.numberOfRows == 3 && list.entries.count == 2 && toggle()?.title == "更多相关结果 · 点击查找"
            checks["FooterHasNativeHoverAndAccessibleClickTarget"] = toggle() is ReadingNativeHoverButton && (toggle()?.bounds.height ?? 0) >= 33
            checks["RelatedTextsAreNotHighlightedBeforeExpansion"] = pdf.highlightedSelections?.count == 2
            let primary = list.entries.map { $0.match + String($0.page) }
            toggle()?.performClick(nil)
            checks["ExplicitExpansionFindsRelatedWithoutAnotherAIRequest"] = await wait { list.entries.count == 29 && calls == 1 }
            checks["PrimaryResultsRemainFirstAfterExpansion"] = Array(list.entries.prefix(2)).map { $0.match + String($0.page) } == primary
            checks["RelatedRowsKeepActualOriginalLocations"] = list.entries.dropFirst(2).contains { $0.match == "三國演義" && $0.page == 1 } && list.entries.dropFirst(2).contains { $0.match == "連環計" && $0.page == 13 }
            list.showSelection(15); await settle(); list.scroll.contentView.scroll(to: .zero); list.scroll.reflectScrolledClipView(list.scroll.contentView); await settle()
            toggle()?.performClick(nil); await settle()
            checks["CollapseRestoresTwoPrimaryRowsAndHighlights"] = list.entries.count == 2 && list.visibleRowCount == 3 && pdf.highlightedSelections?.count == 2
            toggle()?.performClick(nil); checks["ReopenUsesVerifiedRelatedCache"] = await wait { list.entries.count == 29 && calls == 1 }
            query("late"); _ = await wait { lateStarted }; query("不存在")
            input.onSearchAssistance = nil; input.searchAIIdentity = 2; reader.update(from: input); await settle(900)
            checks["ChangedQueryAndModelRejectLateGroupedAssistance"] = list.entries.isEmpty && list.visibleRowCount == 0
            checks["SearchKeepsOriginalDisplayDocument"] = pdf.document.map(ObjectIdentifier.init) == identity
            checks["OriginalPDFBytesUnchanged"] = try Data(contentsOf: source) == bytes
            let session = LibrarySearchSession(), units = (0..<14).map { SourceUnit(id: "p\($0)", order: $0, chapter: "一", page: $0+1, text: "三國演義 " + ($0 == 13 ? "貂蟬" : "連環計")) }
            let snapshots = [LibrarySourceSnapshot(bookID: "b", title: "书", sourceHash: hash, units: units)]
            session.schedule(query: "貂禅", snapshots: snapshots, bookID: "b", root: output.path, debounce: false)
            _ = await wait { session.response != nil }
            session.expand { _, _ in try .init(variants: ["貂蝉"], related: ["三国演义", "连环计"]) }
            _ = await wait { session.assistanceReady }
            checks["LibraryPrimaryResultsExcludeAllHeaderTopics"] = session.response?.matches.count == 1 && session.response?.matches.first?.page == 14
            checks["LibraryRelatedSearchIsLazyAndCollapsed"] = session.relatedResponse == nil && !session.relatedExpanded && !session.searchingRelated
            session.toggleRelated(); _ = await wait { session.relatedResponse != nil }
            checks["LibraryRelatedSearchOpensIndependently"] = session.relatedExpanded && (session.relatedResponse?.matches.count ?? 0) > 10 && session.response?.matches.count == 1
            session.toggleRelated(); checks["LibraryCollapseKeepsVerifiedResultsAndPrimaryCount"] = !session.relatedExpanded && session.relatedResponse != nil && session.response?.matches.count == 1
            session.schedule(query: "next", snapshots: snapshots, bookID: "b", root: output.path, debounce: false)
            checks["LibraryNewInputDropsAllPreviousRelatedState"] = session.relatedResponse == nil && session.relatedKeywords.isEmpty && !session.relatedExpanded && !session.assistanceReady
            session.cancel(); controller.command(.hideSearch); reader.shutdown()
            let passed = checks.values.allSatisfy { $0 }
            try JSONSerialization.data(withJSONObject: ["status": passed ? "passed" : "failed", "checks": checks, "realNetworkRequests": 0], options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"))
            NSApp.terminate(nil)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["status": "failed", "checks": checks, "error": error.localizedDescription], options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json")); NSApp.terminate(nil)
        }
    }
}
@main struct SearchPrecisionMain { static func main() { let app = NSApplication.shared, runner = SearchPrecisionRunner(URL(fileURLWithPath: CommandLine.arguments[1])); app.delegate = runner; app.setActivationPolicy(.regular); app.run() } }
