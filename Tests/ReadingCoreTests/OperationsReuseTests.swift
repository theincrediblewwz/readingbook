import Foundation
import XCTest
import CryptoKit
import ReadingCore

final class OperationsReuseTests:XCTestCase {
    private var temporaryRoot:URL{ProcessInfo.processInfo.environment["READINGBOOK_TEST_ROOT"].map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.temporaryDirectory}
    private func canonical(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed])}
    private func tool(_ schema:[String:Any],plugin:String="test")throws->RegisteredReadingTool{try RegisteredReadingTool(pluginID:plugin,schema:schema,phases:[.reading],readOnly:true){_,_,_ in "{}"}}
    private func schema(_ description:String="original")->[String:Any]{["type":"function","function":["name":"test_same_name","description":description,"parameters":["type":"object","properties":["values":["enum":[NSNumber(value:true),NSNumber(value:UInt64.max),NSNumber(value:Int64.min),NSNumber(value:1.5),NSNull(),"e\u{301}","é"]]],"required":["values"],"additionalProperties":false]]]}
    func testSchemaSnapshotPreservesNestedJSONAndExactUnicodeBytes()throws {
        let input=schema(),registered=try tool(input)
        // The public contract normalizes with Foundation JSON exactly once;
        // nested existential containers still serialize as ordinary JSON.
        let normalized=try JSONSerialization.jsonObject(with:canonical(input))
        XCTAssertEqual(try canonical(registered.schema),try canonical(normalized))
        let function=try XCTUnwrap(registered.schema["function"] as? [String:Any]),parameters=try XCTUnwrap(function["parameters"] as? [String:Any]),properties=try XCTUnwrap(parameters["properties"] as? [String:Any]),values=try XCTUnwrap(properties["values"] as? [String:Any]),array=try XCTUnwrap(values["enum"] as? [Any])
        XCTAssertEqual((array[5] as? String).map{Array($0.utf8)},Array("e\u{301}".utf8));XCTAssertEqual((array[6] as? String).map{Array($0.utf8)},Array("é".utf8))
    }
    func testSchemaSnapshotOwnsInputAndReturnedMutableContainers()throws {
        let mutable=NSMutableDictionary(dictionary:schema()),function=NSMutableDictionary(dictionary:mutable["function"] as! [String:Any]);mutable["function"]=function
        let registered=try tool(mutable as! [String:Any]),before=try canonical(registered.schema)
        function["description"]="input changed";mutable["type"]="changed"
        let returned=NSMutableDictionary(dictionary:registered.schema),returnedFunction=NSMutableDictionary(dictionary:returned["function"] as! [String:Any]);returned["function"]=returnedFunction;returnedFunction["description"]="output changed"
        XCTAssertEqual(try canonical(registered.schema),before)
        // Foundation immutable objects can report a mutable subclass while
        // rejecting mutation. Clients edit explicit mutable copies or Swift
        // values; neither may share a writable reference with the snapshot.
        func mutateCopies(_ value:Any){if let dictionary=value as? [String:Any]{for value in dictionary.values{mutateCopies(value)}}else if let array=value as? [Any]{for value in array{mutateCopies(value)}};if let dictionary=value as? NSDictionary{let copy=dictionary.mutableCopy() as! NSMutableDictionary;copy["caller-edit"]="changed"};if let array=value as? NSArray{let copy=array.mutableCopy() as! NSMutableArray;copy.add("changed")};if let string=value as? NSString{let copy=string.mutableCopy() as! NSMutableString;copy.append("changed")}}
        mutateCopies(registered.schema);XCTAssertEqual(try canonical(registered.schema),before)
    }
    func testSchemaSnapshotConcurrentReadsAndSameNameRegistryCopiesStayIndependent()async throws {
        let registered=try tool(schema()),expected=try canonical(registered.schema)
        try await withThrowingTaskGroup(of:Data.self){group in for i in 0..<64 {group.addTask{if i%2==0{var own=registered.schema;var function=own["function"] as! [String:Any];var parameters=function["parameters"] as! [String:Any];parameters["caller"]=i;function["parameters"]=parameters;own["function"]=function;if try JSONSerialization.data(withJSONObject:own,options:[.sortedKeys])==expected{throw ReadingError.invalid("caller edit was not exercised")}};return try JSONSerialization.data(withJSONObject:registered.schema,options:[.sortedKeys])}};for try await value in group{XCTAssertEqual(value,expected)}}
        var a=PluginToolRegistry();try a.register(registered);var b=a;b.remove(pluginID:"test");try b.register(tool(schema("replacement"),plugin:"replacement"))
        XCTAssertEqual(try canonical(a.schemas()),try canonical([registered.schema]));XCTAssertNotEqual(try canonical(a.schemas()),try canonical(b.schemas()))
        XCTAssertEqual(a.schemas(for:.planning).count,0);XCTAssertEqual(a.schemas(for:.reading).count,1)
        XCTAssertThrowsError(try a.register(registered));XCTAssertEqual(try canonical(a.schemas()),try canonical([registered.schema]))
    }
    private func fixture()async throws->(URL,LibraryRepository,[BookProject]) {
        let root=temporaryRoot.appendingPathComponent("operations-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        let source=root.appendingPathComponent("原书.txt"),text="曹操在江陵。";try Data(text.utf8).write(to:source)
        let repository=LibraryRepository(rootURL:root.appendingPathComponent("library"));var books:[BookProject]=[]
        for i in 0..<3 {var book=BookProject(title:"书 \(i)",originalName:source.lastPathComponent,sourceHash:SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined(),units:[SourceUnit(id:"u",order:0,chapter:"章",text:text)]);PluginEngine.seed(&book);book=try await repository.create(book,sourceURL:source);let doc=DocumentRecord(id:"note",title:"已有笔记",evidence:[Evidence(unitID:"u",quote:text)]);book=try await repository.saveDocument(project:book,document:doc,markdown:"# 原笔记 e\u{301}\n已有分析与引用。\n");books.append(book)}
        return(root,repository,books)
    }
    private func actualBytes(_ root:URL)throws->Int64{var total:Int64=0;let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey])!;for case let u as URL in e{let v=try u.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]);if v.isRegularFile==true{total += Int64(v.fileSize!)}};return total}
    func testStorageOverviewSingleTraversalRetainsTotalsMembershipTrashAndHiddenFiles()async throws {
        let (temp,repo,books)=try await fixture();defer{try? FileManager.default.removeItem(at:temp)}
        let root=temp.appendingPathComponent("library"),extra=root.appendingPathComponent("Workspace/.hidden");try FileManager.default.createDirectory(at:extra,withIntermediateDirectories:true);try Data([1,2,3,4]).write(to:extra.appendingPathComponent("state"));try Data([1,2,3]).write(to:root.appendingPathComponent(".DS_Store"));try Data([4,5]).write(to:root.appendingPathComponent("books/.DS_Store"))
        try await repo.removeBookFromLibrary(project:books[1]);try await repo.archiveBook(project:books[2])
        let first=try await repo.storageOverview();XCTAssertEqual(first.totalBytes,try actualBytes(root));XCTAssertEqual(first.books.count,3)
        for b in first.books {XCTAssertEqual(b.bytes,try actualBytes(b.directoryURL));let standalone=try await repo.storageBook(id:b.id,archived:b.isArchived);XCTAssertEqual(standalone.bytes,b.bytes);XCTAssertEqual(standalone.isRemoved,b.isRemoved)}
        XCTAssertTrue(try XCTUnwrap(first.books.first{$0.id==books[1].id}).isRemoved);XCTAssertTrue(try XCTUnwrap(first.books.first{$0.id==books[2].id}).isArchived)
    }
    func testStorageOverviewRefreshesAfterFileAndMembershipChanges()async throws {
        let (temp,repo,books)=try await fixture();defer{try? FileManager.default.removeItem(at:temp)}
        let first=try await repo.storageOverview(),root=temp.appendingPathComponent("library"),sidecar=root.appendingPathComponent("books/"+books[0].id+"/.new-sidecar")
        try Data(repeating:7,count:713).write(to:sidecar);let second=try await repo.storageOverview();XCTAssertEqual(second.totalBytes,first.totalBytes+713);XCTAssertEqual(second.books.first{$0.id==books[0].id}!.bytes,first.books.first{$0.id==books[0].id}!.bytes+713)
        try await repo.removeBookFromLibrary(project:books[0]);let removed=try await repo.storageOverview();XCTAssertTrue(removed.books.first{$0.id==books[0].id}!.isRemoved)
        _=try await repo.rejoinBook(id:books[0].id);try FileManager.default.removeItem(at:sidecar);let final=try await repo.storageOverview();XCTAssertFalse(final.books.first{$0.id==books[0].id}!.isRemoved);XCTAssertEqual(final.totalBytes,try actualBytes(root))
    }
    func testStorageOverviewAndStandaloneRejectLinksAndMalformedMetadata()async throws {
        let (temp,repo,books)=try await fixture();defer{try? FileManager.default.removeItem(at:temp)}
        let directory=temp.appendingPathComponent("library/books/"+books[0].id),link=directory.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:temp.appendingPathComponent("原书.txt"))
        do{_=try await repo.storageOverview();XCTFail("overview accepted symlink")}catch{}
        do{_=try await repo.storageBook(id:books[0].id);XCTFail("standalone accepted symlink")}catch{}
        try FileManager.default.removeItem(at:link);let metadata=directory.appendingPathComponent("project.json"),before=try Data(contentsOf:metadata);try Data("{}".utf8).write(to:metadata)
        do{_=try await repo.storageOverview();XCTFail("overview accepted malformed identity")}catch{}
        XCTAssertEqual(try Data(contentsOf:metadata),Data("{}".utf8));try before.write(to:metadata)
    }
    func testStorageOverviewUsesBookIdentityAcrossParentPathAliases()async throws {
        let fm=FileManager.default,temp=temporaryRoot.appendingPathComponent("operations-alias-"+UUID().uuidString);try fm.createDirectory(at:temp,withIntermediateDirectories:false);defer{try? fm.removeItem(at:temp)}
        let actual=temp.appendingPathComponent("actual"),alias=temp.appendingPathComponent("alias");try fm.createDirectory(at:actual.appendingPathComponent("library"),withIntermediateDirectories:true);try fm.createSymbolicLink(at:alias,withDestinationURL:actual)
        // An existing library selected through a parent alias is canonicalized.
        // Missing children below an unresolved symlink still retain the existing
        // containment rejection; this test does not weaken that safety rule.
        let repo=LibraryRepository(rootURL:alias.appendingPathComponent("library")),source=temp.appendingPathComponent("source.txt"),text=Data("保留原书。".utf8);try text.write(to:source)
        let book=BookProject(title:"别名书库",originalName:source.lastPathComponent,sourceHash:SHA256.hash(data:text).map{String(format:"%02x",$0)}.joined(),units:[SourceUnit(id:"u",order:0,chapter:"章",text:"保留原书。")]);_=try await repo.create(book,sourceURL:source)
        let overview=try await repo.storageOverview(),standalone=try await repo.storageBook(id:book.id)
        XCTAssertGreaterThan(try XCTUnwrap(overview.books.first).bytes,0);XCTAssertEqual(overview.books.first?.bytes,standalone.bytes);XCTAssertEqual(overview.totalBytes,try actualBytes(actual.appendingPathComponent("library")))
    }
}
