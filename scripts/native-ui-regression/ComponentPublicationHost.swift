import AppKit
import SwiftUI
import Darwin
@testable import ReadingCore
@testable import ReadingBook

enum PublicationMetrics {
    static let lock=NSLock()
    static var counts:[String:Int]=[:], durations:[String:[Double]]=[:]
    static var graphs:[String:([GraphItem],[GraphLine])]=[:]
    static var composition:[String:CompositionProjection]=[:]
    static var workers=0
    static func event(_ name:String) { lock.lock();defer{lock.unlock()};counts[name,default:0]+=1 }
    static func graph(_ kind:String,elapsed:Double,items:[GraphItem],lines:[GraphLine]) { lock.lock();defer{lock.unlock()};counts[kind,default:0]+=1;durations[kind,default:[]].append(elapsed);graphs[kind]=(items,lines) }
    static func beginWorker(){lock.lock();workers+=1;lock.unlock()}
    static func endWorker(){lock.lock();workers-=1;lock.unlock()}
    static func prepared(reused:Bool,elapsed:Double){lock.lock();defer{lock.unlock()};let k=reused ? "composition.reuse":"composition.prepare";counts[k,default:0]+=1;durations[k,default:[]].append(elapsed)}
    static func published(_ value:[String:CompositionProjection]){lock.lock();defer{lock.unlock()};composition=value;counts["composition.published",default:0]+=1}
    static func ready()->Bool{lock.lock();defer{lock.unlock()};return workers==0}
    static func clear(){lock.lock();defer{lock.unlock()};counts=[:];durations=[:]}
    static func report()->[String:Any]{lock.lock();defer{lock.unlock()};return ["counts":counts,"elapsedMS":durations]}
    static func snapshotGraph(_ k:String)->([GraphItem],[GraphLine])?{lock.lock();defer{lock.unlock()};return graphs[k]}
    static func snapshotComposition()->[String:CompositionProjection]{lock.lock();defer{lock.unlock()};return composition}
}

@MainActor final class PublicationRunner:NSObject,NSApplicationDelegate {
    let output:URL, count:Int
    var store:AppStore!, window:NSWindow!, host:NSHostingView<AnyView>!
    var primary:BookProject!, other:BookProject!, spec:CompositionDefinition!
    var records:[[String:Any]]=[],checks:[String:Bool]=[:]
    init(output:URL,count:Int){self.output=output;self.count=count}
    func applicationDidFinishLaunching(_ notification:Notification){Task{await run()}}
    func cpu()->Double{var usage=rusage();getrusage(RUSAGE_SELF,&usage);return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)*1000+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1000}
    func settle()async{var quiet=0;for i in 0..<150{try? await Task.sleep(for:.milliseconds(30));host.layoutSubtreeIfNeeded();host.displayIfNeeded();quiet=PublicationMetrics.ready() ? quiet+1:0;if i>=4 && quiet>=3{return}}}
    func encode(_ book:BookProject)throws->Data{let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(book)}
    func createBook(_ id:String,size:Int)throws->(BookProject,URL){
        let renameEvidence="Entity 0. Changed active documents. Same stamp documents. Changed active relations. Same stamp relations. Changed active composition. Same stamp composition."
        var units=(0..<1484).map{SourceUnit(id:"u\($0)",order:$0,chapter:"Section \($0/20)",page:$0+1,text:"Synthetic segment \($0). Entity evidence is here.")}
        units[0].text += " " + renameEvidence
        for i in 1..<size { units[i].text += " Entity \(i)." }
        let bytes=Data(units.map(\.text).joined(separator:"\n").utf8),source=output.appendingPathComponent(id+".txt");try bytes.write(to:source)
        var project=BookProject(id:id,title:"Publication scope \(size)",originalName:source.lastPathComponent,sourceHash:try BookImporter.sha256(bytes),units:units)
        project.types=[EntityType(id:"person",name:"人物")]
        let evidence=[Evidence(unitID:"u0",quote:"Entity evidence is here.")]
        project.entities=(0..<size).map{KnowledgeEntity(id:"entity\($0)",typeID:"person",name:"Entity \($0)",summary:"Independent synthetic object \($0)",evidence:[Evidence(unitID:"u\($0)",quote:$0==0 ? renameEvidence : "Entity \($0).")])}
        project.nodes=(0..<size).map{CanvasNode(id:"node\($0)",targetID:"entity\($0)",x:Double($0%30)*270,y:Double($0/30)*150)}
        project.edges=(1..<max(1,size)).map{CanvasEdge(id:"edge\($0)",fromID:"node\($0-1)",toID:"node\($0)")}
        project.relations=(1..<max(1,size)).map{KnowledgeRelation(id:"relation\($0)",fromID:"entity\($0-1)",toID:"entity\($0)",label:"next",evidence:evidence)}
        return(project,source)
    }
    func mount(_ mode:String)async{
        PublicationMetrics.clear()
        let view:AnyView
        if mode=="documents"{view=AnyView(DocumentGraphView())}
        else if mode=="relations"{view=AnyView(RelationGraphView())}
        else{view=AnyView(CompositionWorkspaceView(definition:ViewDefinition(id:"probe",title:"Independent components",kind:.knowledge,composition:spec)))}
        host=NSHostingView(rootView:AnyView(view.environmentObject(store).environmentObject(ReadingTypographySettings()).environment(\.readingReduceMotion,true)))
        window.contentView=host;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        await settle()
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds){host.cacheDisplay(in:host.bounds,to:bitmap);if let data=bitmap.representation(using:.png,properties:[:]){try? data.write(to:output.appendingPathComponent(mode+"-mounted.png"))}}
    }
    func same(_ a:[String:CompositionProjection],_ b:[String:CompositionProjection])->Bool{
        guard Set(a.keys)==Set(b.keys)else{return false}
        return a.allSatisfy{k,x in guard let y=b[k]else{return false};return x.items==y.items && x.edges==y.edges && x.mapPoints==y.mapPoints && x.total==y.total && x.partial==y.partial && x.diagnostics==y.diagnostics}
    }
    func run()async{
        do{
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1":output.appendingPathComponent("library").path,"service-profiles":Data("[]".utf8),"appearance.reduceMotion":true,"NSQuitAlwaysKeepsWindows":false],forName:UserDefaults.argumentDomain)
            store=AppStore();guard store.libraryRootURL.standardizedFileURL.path == output.appendingPathComponent("library").standardizedFileURL.path && store.apiKey.isEmpty && store.savedServices.isEmpty else{throw ReadingError.invalid("Service isolation failed")}
            store.settings=ProviderSettings(baseURL:"http://127.0.0.1:1/disabled",model:"")
            let a=try createBook("11111111-1111-4111-8111-111111111146",size:count),b=try createBook("22222222-2222-4222-8222-222222222246",size:2)
            primary=try await store.repository.create(a.0,sourceURL:a.1);other=try await store.repository.create(b.0,sourceURL:b.1)
            store.books=[primary,other];store.bookID=primary.id;store.selectedUnitID="u1483"
            let source=CompositionDataSource(id:"objects",collection:.objects,scope:.book,limit:200)
            spec=CompositionDefinition(sources:[source],parts:[CompositionPart(id:"list",primitive:.objectList,sourceID:"objects")],layout:[CompositionLayoutNode(id:"root",kind:.part,partID:"list")],rootID:"root")
            try CompositionRuntime.validate(spec,in:primary)
            window=NSWindow(contentRect:.init(x:150,y:100,width:1100,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title="ReadingBook 跨书更新对照 · 合成数据"
            for mode in ["documents","relations","composition"]{
                await mount(mode)
                let initialGraph=PublicationMetrics.snapshotGraph(mode), initialComposition=PublicationMetrics.snapshotComposition(), original=try encode(store.book!)
                checks[mode+"Mounted"]=mode=="composition" ? !initialComposition.isEmpty : !(initialGraph?.0.isEmpty ?? true)
                checks[mode+"WindowVisible"]=window.isVisible
                var foregroundSamples:[Bool]=[]
                PublicationMetrics.clear();let startCPU=cpu(),start=ProcessInfo.processInfo.systemUptime
                for index in 0..<8{other.title="Other book edit \(index)";other=try await store.repository.save(other);guard store.publish(other)else{throw ReadingError.invalid("Other book publication rejected")};await settle();foregroundSamples.append(window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid())}
                let cpuMS=cpu()-startCPU,wallMS=(ProcessInfo.processInfo.systemUptime-start)*1000
                checks[mode+"CurrentBookBytesUnchanged"]=try encode(store.book!)==original
                if mode=="composition"{checks[mode+"ExactOutputRetained"]=same(initialComposition,PublicationMetrics.snapshotComposition())}
                else{let final=PublicationMetrics.snapshotGraph(mode);checks[mode+"ExactOutputRetained"]=initialGraph?.0==final?.0 && initialGraph?.1==final?.1}
                records.append(["mode":mode,"phase":"other-book-8","processCPUMS":cpuMS,"wallMS":wallMS,"metrics":PublicationMetrics.report(),"foregroundSamples":foregroundSamples])
                var changed=store.book!;changed.entities[0].name="Changed active \(mode)";changed.nodes[0].title="Changed active \(mode)";primary=try await store.repository.save(changed)
                PublicationMetrics.clear();guard store.publish(primary)else{throw ReadingError.invalid("Current publication rejected")};await settle()
                checks[mode+"CurrentEditRendered"]=mode=="composition" ? PublicationMetrics.snapshotComposition()["objects"]?.items.contains(where:{$0.title=="Changed active \(mode)"})==true : PublicationMetrics.snapshotGraph(mode)?.0.contains(where:{$0.title=="Changed active \(mode)"})==true
                records.append(["mode":mode,"phase":"current-book","metrics":PublicationMetrics.report()])
                var alias=store.book!;alias.entities[0].name="Same stamp \(mode)";alias.nodes[0].title="Same stamp \(mode)"
                PublicationMetrics.clear();guard store.publish(alias)else{throw ReadingError.invalid("Equal stamp publication unexpectedly rejected")};await settle()
                checks[mode+"EqualStampAcceptedEditRendered"]=mode=="composition" ? PublicationMetrics.snapshotComposition()["objects"]?.items.contains(where:{$0.title=="Same stamp \(mode)"})==true : PublicationMetrics.snapshotGraph(mode)?.0.contains(where:{$0.title=="Same stamp \(mode)"})==true
                // Save the accepted UI change before the next mode. This uses only synthetic data.
                primary=try await store.repository.save(alias);_ = store.publish(primary);await settle()
            }
            for mode in ["documents","relations","composition"] { await mount(mode);try await checkSafety(mode) }
            let result:[String:Any]=["status":checks.values.allSatisfy{$0} ? "passed":"failed","count":count,"syntheticUnits":1484,"realNetworkRequests":0,"originalLibraryUsed":false,"libraryRootMatchesRequested":store.libraryRootURL.standardizedFileURL.path == output.appendingPathComponent("library").standardizedFileURL.path,"checks":checks,"records":records,"instrumentation":"Actual source views copied with counters/timers only; unmodified product AppStore and Core objects; normal native hosting and rasterization; reduced-motion fixture"]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"));window.close();NSApp.terminate(nil)
        }catch{try? JSONSerialization.data(withJSONObject:["status":"failed","error":String(describing:error)]).write(to:output.appendingPathComponent("result.json"));fputs("\(error)\n",stderr);NSApp.terminate(nil)}
    }
}
@main enum PublicationMain{
    @MainActor static func main(){let output=URL(fileURLWithPath:CommandLine.arguments[1]);let app=NSApplication.shared;app.setActivationPolicy(.regular);let runner=PublicationRunner(output:output,count:Int(CommandLine.arguments[2])!);app.delegate=runner;app.run();_ = runner}
}

import AppKit
import Foundation
@testable import ReadingBook
@testable import ReadingCore

@MainActor extension PublicationRunner {
    func sees(_ mode:String,_ name:String)->Bool {
        if mode=="composition"{return PublicationMetrics.snapshotComposition()["objects"]?.items.contains{$0.title==name}==true}
        return PublicationMetrics.snapshotGraph(mode)?.0.contains{$0.title==name}==true
    }
    func checkSafety(_ mode:String)async throws {
        let originalRoot=store.libraryRootURL, originalRepository=store.repository
        let primaryID=primary.id,otherID=other.id
        let before=try encode(store.book!),global=store.projectRevision,local=store.currentBookRevision
        var stale=store.book!
        stale.publicationStamp=LibraryPublicationStamp(owner:originalRepository.publicationOwner,ordinal:0)
        PublicationMetrics.clear()
        checks[mode+"StaleStampRejected"] = !store.publish(stale)
        var foreign=store.book!;foreign.publicationStamp=LibraryPublicationStamp(owner:UUID(),ordinal:UInt64.max)
        checks[mode+"ForeignStampRejected"] = !store.publish(foreign)
        var absent=store.book!;absent.publicationStamp=nil
        checks[mode+"AbsentStampRejected"] = !store.publish(absent)
        await settle()
        let rejectedBytes=try encode(store.book!)
        checks[mode+"RejectedWritesKeepEpochsAndOutput"] = store.projectRevision==global && store.currentBookRevision==local && rejectedBytes==before && ((PublicationMetrics.report()["counts"] as? [String:Int]) ?? [:]).isEmpty

        var plain=store.book!,otherPlain=other!;plain.publicationStamp=nil;otherPlain.publicationStamp=nil
        store.bookID=nil;store.books=[plain,otherPlain];store.bookID=primaryID;await settle()
        plain.entities[0].name="Changed active \(mode)";plain.nodes[0].title="Changed active \(mode)"
        let accepted=store.publish(plain);await settle()
        checks[mode+"UnstampedCurrentEditRendered"]=accepted && sees(mode,"Changed active \(mode)")

        let localBeforeOther=store.currentBookRevision,globalBeforeOther=store.projectRevision,currentBytes=try encode(store.book!)
        PublicationMetrics.clear();otherPlain.title="Unstamped other change"
        let otherAccepted=store.publish(otherPlain);await settle()
        let afterOtherBytes=try encode(store.book!)
        checks[mode+"UnstampedOtherPublicationKeepsEpochAndOutput"]=otherAccepted && store.currentBookRevision==localBeforeOther && store.projectRevision==globalBeforeOther+1 && afterOtherBytes==currentBytes && ((PublicationMetrics.report()["counts"] as? [String:Int]) ?? [:]).isEmpty

        store.bookID=otherID;await settle()
        var inactive=plain;inactive.entities[0].name="Same stamp \(mode)";inactive.nodes[0].title="Same stamp \(mode)"
        let inactiveAccepted=store.publish(inactive);await settle();store.bookID=primaryID;await settle()
        checks[mode+"SelectOtherAndBackShowsUpdatedCurrentBook"]=inactiveAccepted && sees(mode,"Same stamp \(mode)")

        let secondRoot=output.appendingPathComponent("same-ids-different-owner-"+mode)
        store.libraryRootURL=secondRoot;store.repository=LibraryRepository(rootURL:secondRoot)
        var replacement=inactive;replacement.entities[0].name="Changed active \(mode)";replacement.nodes[0].title="Changed active \(mode)"
        store.books=[replacement,otherPlain];await settle()
        checks[mode+"SameIdentifiersAcrossRootsInvalidate"]=sees(mode,"Changed active \(mode)")
        store.libraryRootURL=originalRoot;store.repository=originalRepository;store.books=[primary,other];store.bookID=primaryID;await settle()
    }
}
