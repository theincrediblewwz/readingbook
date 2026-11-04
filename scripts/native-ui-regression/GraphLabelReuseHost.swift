import AppKit
import Combine
import Foundation
import QuartzCore
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

@MainActor private final class LabelFixture: ObservableObject {
    @Published var lines = [GraphLine(id:"edge",from:"left",to:"right",label:"初始关系 café")]
    @Published var owner = 0
    @Published var enabled = true
    @Published var blocked = false
    @Published var canRename = true
    @Published var canRemove = true
    @Published var dark = false
    var failNext = false
    var saves: [[String:Any]] = []
    var removals: [[String:Any]] = []
    var completedSaves = 0
    var failedSaves = 0
    let items = [GraphItem(id:"left",targetID:"person",title:"甲",subtitle:"原文一",x:0,y:0),
                 GraphItem(id:"right",targetID:"person",title:"乙",subtitle:"原文二",x:600,y:0)]
    func rename(_ id:String,_ text:String,owner:Int) async -> Bool {
        saves.append(["id":id,"text":text,"owner":owner])
        try? await Task.sleep(for:.milliseconds(50))
        if failNext { failNext=false;completedSaves += 1;failedSaves += 1;return false }
        if let index=lines.firstIndex(where:{$0.id==id}) {lines[index].label=text}
        completedSaves += 1
        return true
    }
    func remove(_ id:String,owner:Int) async -> Bool {
        removals.append(["id":id,"owner":owner]);lines.removeAll{$0.id==id};return true
    }
}
private struct LabelFixtureView: View {
    @ObservedObject var model:LabelFixture
    let store:AppStore
    var body:some View {
        let owner=model.owner
        let rename:((String,String) async -> Bool)? = model.canRename ? {id,text in await model.rename(id,text,owner:owner)} : nil
        let remove:((String) async -> Bool)? = model.canRemove ? {id in await model.remove(id,owner:owner)} : nil
        GraphSurface(items:model.items,lines:model.lines,select:{_ in},renameLine:rename,removeLine:remove,
                     title:"Label regression",isEnabled:model.enabled,errorText:{"合成保存失败"})
            .environmentObject(store).environment(\.workspaceCanvasBlocked,model.blocked)
            .environment(\.colorScheme,model.dark ? .dark:.light).environment(\.readingReduceMotion,true)
    }
}
@MainActor private final class LabelRunner:NSObject,NSApplicationDelegate {
    var output:URL!
    var window:NSWindow!
    var host:NSHostingView<LabelFixtureView>!
    var store:AppStore!
    let model=LabelFixture()
    var checks:[String:Bool]=[:]
    var observations:[[String:Any]]=[]
    var lastKeyStartedAt = 0.0
    var saveReadiness:[[String:Any]]=[]
    func applicationDidFinishLaunching(_ notification:Notification) {
        Task { @MainActor in
            do {try await run();try finish(nil)}catch{
                captureFailureState("original-failed-assertion")
                for delay in [50,100,250,500] {try? await settle(delay);captureFailureState("after-failure-\(delay)ms")}
                try? finish(String(describing:error))
            }
            window?.orderOut(nil);NSApp.terminate(nil)
        }
    }
    func require(_ name:String,_ value:Bool) throws {
        checks[name]=value;guard value else{throw ReadingError.invalid(name)}
    }
    func captureFailureState(_ stage:String) {
        guard let host,let window else{return}
        let fields=descendants(host,NSTextField.self).map {field -> [String:Any] in
            ["value":field.stringValue,"editable":field.isEditable,"enabled":field.isEnabled,"hidden":field.isHiddenOrHasHiddenAncestor,
             "alpha":field.alphaValue,"hasWindow":field.window != nil,"hasEditor":field.currentEditor() != nil,
             "editorIsFirstResponder":field.currentEditor() === window.firstResponder,"frame":[field.frame.minX,field.frame.minY,field.frame.width,field.frame.height]]
        }
        observations.append(["stage":stage,"at":ProcessInfo.processInfo.systemUptime,"labels":model.lines.map(\.label),"fields":fields,
            "firstResponder":window.firstResponder.map{String(describing:Swift.type(of:$0))} ?? "nil"])
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:bitmap)
            if let png=bitmap.representation(using:.png,properties:[:]) {try? png.write(to:output.appendingPathComponent(stage+".png"))}
        }
    }
    func descendants<T:NSView>(_ root:NSView,_ type:T.Type)->[T] {
        (root as? T).map{[$0]} ?? root.subviews.flatMap{descendants($0,type)}
    }
    func settle(_ ms:Int=100)async throws {
        try await Task.sleep(for:.milliseconds(ms));host.layoutSubtreeIfNeeded();CATransaction.flush();window.displayIfNeeded()
        guard window.isKeyWindow,NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() else{throw ReadingError.invalid("Foreground lost")}
    }
    func label()throws->GraphPointerBridge.PointerView {
        let matches=descendants(host,GraphPointerBridge.PointerView.self).filter{!$0.movable && !$0.reservePorts && $0.bounds.width>25 && $0.bounds.height<45 && !$0.isHiddenOrHasHiddenAncestor}
        guard matches.count==1,let view=matches.first else{throw ReadingError.invalid("Expected exactly one real label receiver: \(matches.count)")}
        return view
    }
    func editor()->NSTextField? {descendants(host,NSTextField.self).first{$0.isEditable && !$0.isHiddenOrHasHiddenAncestor}}
    func click(_ view:NSView,count:Int=2)async throws {
        let point=view.convert(CGPoint(x:view.bounds.midX,y:view.bounds.midY),to:nil)
        let rootPoint=host.superview?.convert(point,from:nil) ?? point
        let hit=host.hitTest(rootPoint)
        try require("actualLabelHit-\(checks.count)",hit === view || hit?.isDescendant(of:view)==true)
        for (kind,pressure) in [(NSEvent.EventType.leftMouseDown,Float(1)),(.leftMouseUp,Float(0))] {
            guard let event=NSEvent.mouseEvent(with:kind,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:count,pressure:pressure) else{throw ReadingError.invalid("Event")}
            NSApp.postEvent(event,atStart:false)
        }
        try await settle()
    }
    func key(_ code:UInt16,_ text:String,settleAfter:Bool=true)async throws {
        guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
            windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code) else{throw ReadingError.invalid("Key")}
        lastKeyStartedAt=ProcessInfo.processInfo.systemUptime
        NSApp.postEvent(event,atStart:false)
        if settleAfter { try await settle(180) }
    }
    func awaitSave(_ stage:String,ready:()->Bool)async throws {
        let started=lastKeyStartedAt,deadline=started+1.5
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime<deadline else {throw ReadingError.invalid("Save readiness exceeded1500ms: "+stage)}
            guard window.isKeyWindow,NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() else {throw ReadingError.invalid("Foreground lost")}
            // Yield to actual event handling and async completion; forcing a
            // full layout each poll can itself delay the completion being observed.
            try await Task.sleep(for:.milliseconds(10))
        }
        let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
        guard elapsed<=1500 else {throw ReadingError.invalid("Save readiness exceeded1500ms: "+stage)}
        saveReadiness.append(["stage":stage,"elapsedMS":elapsed,"completedSaves":model.completedSaves,"failedSaves":model.failedSaves])
    }
    func type(_ text:String)throws {
        guard let field=editor(),let textView=field.currentEditor() as? NSTextView else{throw ReadingError.invalid("Focused editor")}
        textView.setSelectedRange(NSRange(location:0,length:(textView.string as NSString).length));textView.insertText(text,replacementRange:textView.selectedRange())
    }
    func resetCamera(_ scale:Double)async throws {
        store.workspaceMemory.graphs["Label regression"]=WorkspaceGraphCamera(center:WorkspacePoint(x:400,y:50),scale:scale)
        store.workspaceMemoryRevision += 1
        try await settle(200)
    }
    func run()async throws {
        output=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath+"/logs/"),Bundle.main.bundleIdentifier != "org.readingbook.app" else{throw ReadingError.invalid("Isolation")}
        let root=output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1":root.path,"service-profiles":Data("[]".utf8),"appearance.reduceMotion":true],forName:UserDefaults.argumentDomain)
        store=AppStore();store.settings = .init(baseURL:"http://127.0.0.1:1/disabled",model:"");store.apiKey=""
        let book=BookProject(id:"51000000-0000-4000-8000-000000000051",title:"合成标签交互书",originalName:"synthetic.txt",sourceHash:String(repeating:"b",count:64),units:[SourceUnit(id:"u",order:0,chapter:"合成",page:1,text:"保留的原文。")])
        store.books=[book];store.bookID=book.id;store.baseWorkspaceRoute="mindmap";store.workspaceMemory=BookWorkspaceMemory(bookID:book.id,sourceHash:book.sourceHash)
        store.workspaceMemory.graphs["Label regression"]=WorkspaceGraphCamera(center:WorkspacePoint(x:400,y:50),scale:1)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let before=try encoder.encode(book)
        window=NSWindow(contentRect:.init(x:100,y:80,width:1120,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="ReadingBook 标签复用 · 隔离交互回归";window.isReleasedWhenClosed=false
        host=NSHostingView(rootView:LabelFixtureView(model:model,store:store));window.contentView=host;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        try await settle(500)
        try require("isolatedLibrary",store.libraryRootURL.standardizedFileURL.path==root.standardizedFileURL.path)
        try require("initialLabelReceiver",try label().enabled)
        try await click(try label(),count:1);try require("singleClickDoesNotEdit",editor()==nil)
        model.owner=1;try await settle()
        try await click(try label());try require("doubleClickOpensCurrentLabel",editor()?.stringValue=="初始关系 café")
        try type("保留的失败草稿");model.failNext=true;try await key(36,"\r",settleAfter:false)
        try await awaitSave("failed-save-ready") {
            guard let field=editor() else{return false}
            return model.completedSaves==1 && model.failedSaves==1 && field.isEnabled && field.currentEditor() != nil && field.currentEditor() === window.firstResponder
        }
        try require("failedSaveKeepsDraft",model.completedSaves==1 && model.failedSaves==1 && editor()?.stringValue=="保留的失败草稿")
        try require("cachedCallbackUsesLatestOwner",model.saves.last?["owner"] as? Int==1)
        try await key(36,"\r",settleAfter:false)
        try await awaitSave("retry-save-ready") {model.completedSaves==2 && editor()==nil && model.lines[0].label=="保留的失败草稿"}
        try require("retrySavesDraftAndClosesEditor",model.completedSaves==2 && editor()==nil && model.lines[0].label=="保留的失败草稿")
        model.lines[0].label="外部更新后的关系";try await settle()
        try await click(try label());try require("sameIDExternalLabelChangeRefreshes",editor()?.stringValue=="外部更新后的关系")
        try type("取消的草稿");try await key(53,"\u{1b}");try require("escapeCancelsRename",editor()==nil && model.lines[0].label=="外部更新后的关系")
        model.canRename=false;try await settle();try await click(try label());try require("removedRenameCapabilityIsRespected",editor()==nil)
        model.canRename=true;model.enabled=false;try await settle();try require("disabledLabelDoesNotReceiveInput",try label().enabled==false)
        model.enabled=true;model.blocked=true;try await settle();try require("coveredCanvasDoesNotReceiveInput",try label().enabled==false)
        model.blocked=false;try await settle();try require("uncoveredCanvasRecoversInput",try label().enabled)
        for scale in [0.2,1.0] {
            try await resetCamera(scale);let view=try label()
            let point=view.convert(CGPoint(x:view.bounds.midX,y:view.bounds.midY),to:host)
            observations.append(["scale":scale,"center":[point.x,point.y],"bounds":[view.bounds.width,view.bounds.height]])
            try await click(view);try require("distantAndNearLabelsRemainEditable-\(scale)",editor()?.stringValue==model.lines[0].label)
            try await key(53,"\u{1b}")
        }
        model.dark=true;try await settle();try await click(try label());try require("themeChangePreservesInteraction",editor() != nil);try await key(53,"\u{1b}")
        let differentRoot=output.appendingPathComponent("same-ids-new-library")
        store.libraryRootURL=differentRoot;store.repository=LibraryRepository(rootURL:differentRoot);model.owner=2;try await settle()
        try await click(try label());try type("新库的关系");try await key(36,"\r",settleAfter:false)
        try await awaitSave("new-library-save-ready") {model.completedSaves==3 && model.lines[0].label=="新库的关系" && editor()==nil}
        try require("newLibraryUsesCurrentActionOwner",model.saves.last?["owner"] as? Int==2 && model.lines[0].label=="新库的关系")
        model.owner=3;try await settle()
        let receiver=try label(), point=receiver.convert(CGPoint(x:receiver.bounds.midX,y:receiver.bounds.midY),to:nil)
        guard let event=NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
            windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) else {throw ReadingError.invalid("Context event")}
        guard let menu=receiver.menu(for:event) else {throw ReadingError.invalid("Native label menu missing")}
        observations.append(["contextMenuTitles":menu.items.map(\.title)])
        try require("contextMenuHasRename",menu.items.contains{$0.title=="修改关系名称"})
        guard let removeIndex=menu.items.firstIndex(where:{$0.title=="连线移入回收站"}) else {throw ReadingError.invalid("Remove item missing")}
        lastKeyStartedAt=ProcessInfo.processInfo.systemUptime;menu.performActionForItem(at:removeIndex)
        try await awaitSave("context-removal-ready") {model.removals.count==1 && model.lines.isEmpty && editor()==nil}
        try require("contextRemovalUsesLatestOwner",model.removals.last?["owner"] as? Int==3 && model.removals.last?["id"] as? String=="edge")
        try require("contextRemovalUpdatesVisibleLabels",model.lines.isEmpty && editor()==nil)
        try require("sourceProjectBytesUnchanged",try encoder.encode(store.book!)==before)
        try require("noModelRequests",store.requestsUsed==0 && store.apiKey.isEmpty && store.savedServices.isEmpty)
        try require("nodeWorldCoordinatesUnchanged",model.items.map{$0.x}==[0,600] && model.items.allSatisfy{$0.y==0})
    }
    func finish(_ error:String?)throws {
        let result:[String:Any]=["status":error==nil && !checks.isEmpty && checks.values.allSatisfy{$0} ? "passed":"failed","error":error ?? NSNull(),"checks":checks,"checkCount":checks.count,"observations":observations,"saveReadiness":saveReadiness,"saveReadinessDeadlineMS":1500,"saves":model.saves,"removals":model.removals,"realNetworkRequests":0,"originalLibraryUsed":false,"scope":"Uninstrumented product GraphSurface, fixture-local AppKit hit-tested events and real rename fields. Camera restore uses public workspace memory." ]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"))
    }
}
@main private enum LabelMain {
    @MainActor static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);app.appearance=NSAppearance(named:.aqua);let runner=LabelRunner();app.delegate=runner;app.run();withExtendedLifetime(runner){}}
}
