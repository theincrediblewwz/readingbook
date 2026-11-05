import Foundation
import XCTest
@testable import ReadingCore

private actor SearchContextCalls {
    private var count = 0
    func next() -> Int { count += 1; return count }
    func value() -> Int { count }
}

final class SearchContextRegressionTests: XCTestCase {
    private func project(_ count: Int = 3) -> BookProject {
        BookProject(id:"book",title:"原书",originalName:"book.pdf",sourceHash:"hash",units:(0..<count).map {
            SourceUnit(id:"u\($0)",order:$0,chapter:"章",page:$0+1,text:$0 == 1 ? "司徒王允歸到府中，\n尋思今日席間之事，坐不安席。" : "第\($0)页的原文，不属于当前选择。")
        })
    }
    private func response(_ text: String, cost: Int = 100, finish: String = "stop") -> ProviderClient.Result {
        .init(message:.init(role:"assistant",content:text,refusal:nil,tool_calls:nil,reasoning_content:nil),finishReason:finish,tokenCost:cost)
    }
    private func rows(_ values: [[String:String]]) throws -> String {
        String(decoding:try JSONSerialization.data(withJSONObject:["matches":values],options:[.sortedKeys]),as:UTF8.self)
    }
    private func row(_ id: String, _ quote: String) -> [String:String] { ["partID":id,"quote":quote,"reason":"相关内容"] }
    private func batch(_ p: BookProject) throws -> WholeBookSearchBatch {
        try WholeBookSearchPlan.prepare(query:"王允",snapshot:.init(project:p),settings:.init(model:"fixture",contextWindowTokens:128_000)).batches[0]
    }

    func testPageQuestionStartsWithActualPageAndNoAdjacentPage() async throws {
        let p=project()
        let result=try await ReadingAnswerEngine.run(question:"这页讲啥",project:p,settings:.init(model:"fixture",contextWindowTokens:128_000),documents:[:],context:.init(unitID:"u1",page:2),scope:.page,history:[],memory:nil,memoryEnabled:false,documentIDs:nil,loader:nil,operationLimit:128_000,remainingRequests:1) { messages,_,_,_ in
            let contents=messages.compactMap { $0["content"] as? String }.joined()
            XCTAssertTrue(contents.contains("司徒王允歸到府中"));XCTAssertTrue(contents.contains("actualReadFragments"))
            XCTAssertFalse(contents.contains("第0页的原文"));XCTAssertFalse(contents.contains("第2页的原文"))
            return self.response("王允回到府中，因席间之事不安。[unit:u1]")
        }
        XCTAssertEqual(result.message.evidence.map(\.unitID),["u1"])
        XCTAssertEqual(result.diagnostics.sourceReadIDs,["u1"])
        XCTAssertEqual(result.diagnostics.toolCalls,0,"宿主初始正文不是模型工具调用")
    }

    func testSelectionBootstrapSharesOnlyTheExactSelectedText() async throws {
        let p=project(), quote="尋思今日席間之事"
        let result=try await ReadingAnswerEngine.run(question:"解释选句",project:p,settings:.init(model:"fixture",contextWindowTokens:128_000),documents:[:],context:.init(unitID:"u1",selectedText:quote,page:2),scope:.selection,history:[],memory:nil,memoryEnabled:false,documentIDs:nil,loader:nil,operationLimit:128_000,remainingRequests:1) { messages,_,_,_ in
            let contents=messages.compactMap { $0["content"] as? String }.joined()
            XCTAssertTrue(contents.contains(quote));XCTAssertFalse(contents.contains("司徒王允歸到府中"));XCTAssertFalse(contents.contains("坐不安席"))
            return self.response("他回想席间发生的事情。[unit:u1]")
        }
        XCTAssertEqual(result.message.evidence.first?.quote,quote)
    }

    func testWideScopeKeepsOnDemandSourcePermissions() async throws {
        let p=project()
        let result=try await ReadingAnswerEngine.run(question:"可以怎样阅读",project:p,settings:.init(model:"fixture",contextWindowTokens:128_000),documents:[:],context:nil,scope:.book,history:[],memory:nil,memoryEnabled:false,documentIDs:nil,loader:nil,operationLimit:128_000,remainingRequests:1) { messages,_,_,_ in
            XCTAssertFalse(messages.compactMap { $0["content"] as? String }.joined().contains("司徒王允歸到府中"))
            return self.response("可以先确定阅读目标。")
        }
        XCTAssertTrue(result.diagnostics.sourceReadIDs.isEmpty)
    }

    func testLongPageBootstrapIsBoundedAndReportsTruncation() async throws {
        var p=project();p.units[1].text="当前页开头"+String(repeating:"正文",count:20_000)+"不可冒称已提供的页尾"
        let snapshot=try ReadingQuerySnapshot.freeze(scope:.page,in:p,context:.init(unitID:"u1",page:2))
        var session=ReadingQuerySession(snapshot:snapshot,history:[],loader:nil,providedDocuments:[:])
        let data=try XCTUnwrap(session.initialSource(maximumBytes:3000))
        XCTAssertLessThanOrEqual(data.utf8.count,3000)
        XCTAssertTrue(data.contains("fragmentTruncated\":true"));XCTAssertFalse(data.contains("不可冒称已提供的页尾"))
        XCTAssertEqual(session.toolCalls,0);XCTAssertEqual(session.sourceExcerpts.map { $0.0 },["u1"])
    }

    func testMissingPageCitationGetsOneBoundedVerifiedCorrection() async throws {
        let p=project(), calls=SearchContextCalls()
        let result=try await ReadingAnswerEngine.run(question:"这页讲啥",project:p,settings:.init(model:"fixture",contextWindowTokens:128_000),documents:[:],context:.init(unitID:"u1",page:2),scope:.page,history:[],memory:nil,memoryEnabled:false,documentIDs:nil,loader:nil,operationLimit:128_000,remainingRequests:2) { messages,tools,_,final in
            let n=await calls.next()
            if n==1 { return self.response("王允回想席间之事，坐立不安。") }
            XCTAssertTrue(final);XCTAssertTrue(tools.isEmpty)
            let contents=messages.compactMap { $0["content"] as? String }.joined()
            XCTAssertTrue(contents.contains("司徒王允歸到府中"));XCTAssertFalse(contents.contains("第0页的原文"))
            return self.response("王允回想席间之事，坐立不安。[unit:u1]")
        }
        let count=await calls.value();XCTAssertEqual(count,2)
        XCTAssertEqual(result.message.evidence.map(\.unitID),["u1"])
        XCTAssertTrue(result.diagnostics.notices.contains { $0.contains("补核") })
    }

    func testCorrectionNeverAuthorizesAnAdjacentPage() async throws {
        let p=project(), calls=SearchContextCalls()
        do {
            _ = try await ReadingAnswerEngine.run(question:"这页讲啥",project:p,settings:.init(model:"fixture",contextWindowTokens:128_000),documents:[:],context:.init(unitID:"u1",page:2),scope:.page,history:[],memory:nil,memoryEnabled:false,documentIDs:nil,loader:nil,operationLimit:128_000,remainingRequests:2) { _,_,_,_ in
                _ = await calls.next();return self.response("伪造别页引用。[unit:u0]")
            };XCTFail("不能接受未提供的页")
        } catch {}
        let count=await calls.value();XCTAssertEqual(count,2)
    }

    func testMissingCitationCannotRenewTheRequestBudget() async throws {
        let p=project(), calls=SearchContextCalls()
        do {
            _ = try await ReadingAnswerEngine.run(question:"这页讲啥",project:p,settings:.init(model:"fixture",contextWindowTokens:128_000),documents:[:],context:.init(unitID:"u1",page:2),scope:.page,history:[],memory:nil,memoryEnabled:false,documentIDs:nil,loader:nil,operationLimit:128_000,remainingRequests:1) { _,_,_,_ in
                _ = await calls.next();return self.response("回答没有出处。")
            };XCTFail("请求额度不能自动续上")
        } catch {}
        let count=await calls.value();XCTAssertEqual(count,1)
    }

    func testSearchRestoresOriginalLineBreaksAndUniqueActualPage() throws {
        let p=project(), b=try batch(p)
        let hits=try WholeBookSearchEngine.parse(rows([row(b.parts[0].id,"司徒王允歸到府中，尋思今日席間之事")]),batch:b)
        let hit=try XCTUnwrap(hits.first?.source)
        XCTAssertEqual(hit.page,2);XCTAssertEqual(hit.unitID,"u1");XCTAssertTrue(hit.quote.contains("\n"))
        XCTAssertNoThrow(try hit.validate(in:p))
        XCTAssertEqual((p.units[1].text as NSString).substring(with:NSRange(location:hit.utf16Location,length:hit.utf16Length)),hit.quote)
    }

    func testSearchDoesNotFoldWordSpacesOrGuessAmbiguousPages() throws {
        var p=project();p.units[1].text="重复原句 now here";p.units[2].text="重复原句"
        let b=try batch(p)
        XCTAssertThrowsError(try WholeBookSearchEngine.parse(rows([row(b.parts[0].id,"重复原句")]),batch:b))
        XCTAssertThrowsError(try WholeBookSearchEngine.parse(rows([row(b.parts[1].id,"nowhere")]),batch:b))
        XCTAssertThrowsError(try WholeBookSearchEngine.parse(rows([row("invented","重复原句")]),batch:b))
    }

    func testOneSearchRepairKeepsVerifiedRowsAndUsesOnlyNearbySentParts() async throws {
        let p=project(20), b=try batch(p), calls=SearchContextCalls()
        let bad=try rows([row(b.parts[1].id,"司徒王允歸到府中"),row(b.parts[4].id,"跨页拼接但并不存在的文字")])
        let result=try await WholeBookSearchEngine.execute(b,settings:.init(model:"fixture",contextWindowTokens:128_000)) { messages,_,remaining in
            let n=await calls.next()
            if n==1 { return self.response(bad,cost:200) }
            XCTAssertEqual(remaining,b.capacity-200)
            let contents=messages.compactMap { $0["content"] as? String }.joined()
            XCTAssertTrue(contents.contains("unverifiedMatches"));XCTAssertTrue(contents.contains("第4页的原文"));XCTAssertFalse(contents.contains("第19页的原文"))
            return self.response(try self.rows([self.row(b.parts[4].id,"第4页的原文")]),cost:100)
        }
        let count=await calls.value();XCTAssertEqual(count,2)
        XCTAssertEqual(result.tokenCost,300);XCTAssertEqual(result.matches.count,2)
        for hit in result.matches { XCTAssertNoThrow(try hit.source.validate(in:p)) }
    }

    func testSearchRepairCannotGuessOrLoopOnFabricatedQuotes() async throws {
        let b=try batch(project()), calls=SearchContextCalls()
        do {
            _ = try await WholeBookSearchEngine.execute(b,settings:.init(model:"fixture",contextWindowTokens:128_000)) { _,_,_ in
                _ = await calls.next();return self.response(try self.rows([self.row(b.parts[1].id,"完全不存在的句子")]))
            };XCTFail("第二次仍无法核验必须停止")
        } catch {}
        let count=await calls.value();XCTAssertEqual(count,2)
    }

    func testSearchCorrectionCannotExceedTheOriginalTokenBudget() async throws {
        let b=try batch(project()), calls=SearchContextCalls()
        do {
            _ = try await WholeBookSearchEngine.execute(b,settings:.init(model:"fixture",contextWindowTokens:128_000)) { _,_,_ in
                _ = await calls.next();return self.response(try self.rows([self.row(b.parts[1].id,"不存在")]),cost:b.capacity-8)
            };XCTFail("不足剩余预算不能补发")
        } catch {}
        let count=await calls.value();XCTAssertEqual(count,1)
    }

    func testTruncatedSearchResultNeverStartsARepairOrCountsAsRead() async throws {
        let b=try batch(project()), calls=SearchContextCalls()
        do {
            _ = try await WholeBookSearchEngine.execute(b,settings:.init(model:"fixture",contextWindowTokens:128_000)) { _,_,_ in
                _ = await calls.next();return self.response("{\"matches\":[]}",finish:"length")
            };XCTFail("截断不得计入已读")
        } catch {}
        let count=await calls.value();XCTAssertEqual(count,1)
    }
}
