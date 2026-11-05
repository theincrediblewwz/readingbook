import AppKit
import PDFKit
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

@MainActor final class FindPanelRunner: NSObject, NSApplicationDelegate {
    let output: URL
    let reader = PDFReaderContainerView(), controller = PDFReaderController()
    var window: NSWindow!
    var checks: [String: Bool] = [:], observations: [[String: Any]] = []
    var aiQueries: [String] = []
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func settle(_ ms: Int = 120) async {
        reader.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(ms))
        reader.layoutSubtreeIfNeeded(); reader.layoutSubtreeIfNeeded()
    }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func panel(for field: NSSearchField) -> NSView? {
        var current: NSView? = field
        while let item = current {
            if String(describing: type(of: item)).contains("PDFReaderFloatingPanel") { return item }
            current = item.superview
        }
        return nil
    }
    func observe(_ name: String, field: NSSearchField, list: PDFSearchResultsList) {
        let parent = panel(for: field)
        observations.append(["phase": name, "panelHeight": parent?.frame.height ?? -1,
            "readerWidth": reader.bounds.width, "windowWidth": window.contentView?.frame.width ?? -1, "foreground": NSApp.isActive, "fieldHeight": field.frame.height, "fieldWidth": field.frame.width,
            "panelHidden": parent?.isHidden ?? true, "searchVisible": controller.isSearchVisible,
            "resultCount": list.entries.count, "chromeFrame": NSStringFromRect(controller.chromeFrame), "thumbnailFrame": NSStringFromRect(controller.thumbnailFrame)])
    }
    func run() async {
        do {
            let source = output.appendingPathComponent("synthetic.pdf")
            var box = CGRect(x: 0,y: 0,width: 600,height: 800)
            let gc = CGContext(source as CFURL, mediaBox: &box, nil)!
            for page in 1...3 {
                gc.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: gc, flipped: false)
                for line in 0..<12 {
                    NSString(string: "第\(page)頁\(line) 貂蟬 Same sentence. Original text.").draw(at: .init(x: 30,y: 730-line*48), withAttributes: [.font: NSFont.systemFont(ofSize: 17)])
                }
                NSGraphicsContext.restoreGraphicsState();gc.endPDFPage()
            }
            gc.closePDF();let bytes = try Data(contentsOf: source), hash = try BookImporter.sha256(bytes)
            window = NSWindow(contentRect: .init(x: 100,y: 100,width: 1100,height: 780),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
            window.title = "ReadingBook 查找过渡 · 隔离回归";window.contentView = reader
            // The owned fixture presents real window layout; it sends no global input.
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            var input = PDFReaderView(controller: controller,url: source,sourceHash: hash)
            input.onAISearch = { [weak self] in self?.aiQueries.append($0) }
            reader.update(from: input)
            for _ in 0..<100 { if controller.isReady { break };await settle(50) }
            guard let pdf = views(reader).compactMap({$0 as? PDFView}).first,
                  let field = views(reader).compactMap({$0 as? NSSearchField}).first,
                  let list = views(reader).compactMap({$0 as? PDFSearchResultsList}).first,
                  let document = pdf.document else { throw ReadingError.invalid("Missing actual native find hierarchy") }
            let identity = ObjectIdentifier(document)
            checks["originalDocumentReady"] = controller.isReady && document.pageCount == 3
            checks["startsWithoutVisibleFind"] = !controller.isSearchVisible
            for (name,width,reduced) in [("glass-wide",1100.0,false),("glass-narrow",716.0,false),("opaque-wide",1100.0,true),("opaque-narrow",716.0,true)] {
                reader.setReducedTransparency(reduced);reader.setReducedMotion(name.contains("narrow"))
                window.setContentSize(.init(width: width,height: 780));reader.setFrameSize(.init(width: width,height: 780));reader.needsLayout = true;reader.layoutSubtreeIfNeeded();await settle()
                var fits = true, closed = true
                for cycle in 0..<3 {
                    controller.command(.showSearch);reader.layoutSubtreeIfNeeded();observe(name+"-show-immediate-\(cycle)",field: field,list: list)
                    await settle(220)
                    fits = fits && controller.isSearchVisible && field.bounds.height >= 43.5 && field.bounds.width >= 150 && abs(reader.bounds.width - width) < 1 && (panel(for: field)?.bounds.width ?? 0) <= width - 35
                    let close = views(reader).compactMap({$0 as? NSButton}).first { $0.toolTip == "关闭查找（Esc）" }
                    close?.performClick(nil);reader.layoutSubtreeIfNeeded();observe(name+"-close-immediate-\(cycle)",field: field,list: list)
                    await settle()
                    closed = closed && !controller.isSearchVisible && list.entries.isEmpty && list.isHidden && window.firstResponder === pdf
                }
                checks[name+"-emptyControlsFit"] = fits
                checks[name+"-emptyCloseAndFocus"] = closed
                controller.command(.showSearch);await settle(220)
                field.stringValue = "貂蝉";field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification,object: field))
                for _ in 0..<60 { if list.entries.count == 36 { break };await settle(40) }
                checks[name+"-simplifiedFindsTraditionalWithoutReturn"] = list.entries.count == 36 && list.entries.allSatisfy { $0.match == "貂蟬" }
                observe(name+"-results",field: field,list: list)
                checks[name+"-resultsBoundedAndFieldNotSquashed"] = field.bounds.height >= 43.5 && controller.chromeFrame.height >= 64 && controller.chromeFrame.height < 500
                controller.command(.setThumbnails(true));await settle(220)
                checks[name+"-thumbnailsBelowFind"] = controller.thumbnailFrame.minY >= controller.chromeFrame.maxY+11
                field.stringValue = "No exact result";field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification,object: field))
                await settle(650);checks[name+"-emptyResultMessageKeepsControls"] = list.entries.isEmpty && controller.isSearchVisible && field.bounds.height >= 43.5
                field.stringValue = "draft for AI"
                let ai = views(reader).compactMap({$0 as? NSButton}).first { $0.toolTip == "AI阅读全文查找：先理解意图，再阅读全文" }
                ai?.performClick(nil);await settle()
                checks[name+"-aiReceivesExactDraftAndClosesFind"] = aiQueries.last == "draft for AI" && !controller.isSearchVisible
                observe(name+"-AI-return",field: field,list: list)
                checks[name+"-thumbnailsReturnToTop"] = abs(controller.thumbnailFrame.minY-76)<1
                controller.command(.setThumbnails(false));await settle()
            }
            checks["sourceDocumentReused"] = pdf.document.map(ObjectIdentifier.init) == identity
            checks["originalPDFBytesUnchanged"] = try Data(contentsOf: source) == bytes
            checks["noOriginalLibraryOrModelUse"] = aiQueries.count == 4
            reader.shutdown();window.orderOut(nil)
            let result: [String: Any] = ["status": checks.values.allSatisfy{$0} ? "passed":"failed","checks":checks,
                "observations":observations,"realNetworkRequests":0,"originalLibraryUsed":false,"globalInputSent":false,"foregroundRequired":true]
            try JSONSerialization.data(withJSONObject: result,options:[.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"),options:.atomic)
            NSApp.terminate(nil)
        } catch {
            try? JSONSerialization.data(withJSONObject:["status":"failed","error":String(describing:error),"checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"),options:.atomic)
            NSApp.terminate(nil)
        }
    }
}
@main struct FindPanelLayoutMain {
    static func main() {
        let app = NSApplication.shared;app.setActivationPolicy(.accessory)
        let runner = FindPanelRunner(URL(fileURLWithPath: CommandLine.arguments[1],isDirectory:true))
        app.delegate=runner;app.run();withExtendedLifetime(runner){}
    }
}
