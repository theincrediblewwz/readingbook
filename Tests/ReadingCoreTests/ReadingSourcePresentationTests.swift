import Foundation
import XCTest
@testable import ReadingCore

final class ReadingSourcePresentationTests: XCTestCase {
    private func book(_ text: String = "甲行\n乙行。") -> BookProject {
        BookProject(id: "clean-source", title: "原书", originalName: "book.txt", sourceHash: "unchanged", units: [
            .init(id: "unit-000001", order: 605, chapter: "第一章", page: 104, text: text),
            .init(id: "unit-000002", order: 701, chapter: "后文", page: 105, text: "后文秘密")])
    }
    private func pageSession(_ value: BookProject, selection: String? = nil) throws -> ReadingQuerySession {
        let snapshot = try ReadingQuerySnapshot.freeze(scope: selection == nil ? .page : .selection, in: value,
            context: .init(unitID: value.units[0].id, selectedText: selection, page: 104))
        return ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: value)
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func reference(_ id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["batch": ["knowledge": ["anchors": [["clientID": "anchor-one", "sourceRef": id]]]]])
    }
    func testPlainPresentationPreservesOriginalLineBreaksCodeQuotesAndLiteralEscapes() throws {
        let text = "甲行\n乙行。\n```swift\nlet s = \"\\n\"\n```\n$\\alpha+1$ 与 \"原引号\"。"
        let value = book(text); var session = try pageSession(value)
        let canonical = try XCTUnwrap(session.initialSource(maximumBytes: 4000)), clean = try session.modelSourceText(canonical)
        XCTAssertTrue(clean.contains(text), "不能用全局替换去改书中原有代码、公式或转义序列")
        XCTAssertTrue(clean.hasPrefix("【原文 [unit:unit-000001]｜本范围完整】\n"))
        XCTAssertFalse(clean.contains("actualReadFragments")); XCTAssertFalse(clean.contains("fragmentTruncated"))
        XCTAssertFalse(clean.contains("\"hash\"")); XCTAssertFalse(clean.contains("后文秘密"))
        XCTAssertLessThan(clean.utf8.count, canonical.utf8.count)
        XCTAssertEqual(value.units[0].text, text)
    }
    func testShortReferenceResolvesOnlyExactSelectionAndKeepsLegacyReference() throws {
        let value = book("前面的原文，选中的原句，后面的原文。"), selected = "选中的原句"
        var session = try pageSession(value, selection: selected)
        let payload = try XCTUnwrap(session.initialSource(maximumBytes: 3000)), clean = try session.modelSourceText(payload)
        XCTAssertTrue(clean.contains(selected)); XCTAssertFalse(clean.contains("前面的原文")); XCTAssertFalse(clean.contains("后面的原文"))
        let resolved = try object(String(decoding: session.resolveSourceReferences(in: reference("unit-000001")), as: UTF8.self))
        let group = try XCTUnwrap((resolved["batch"] as? [String: Any])?["knowledge"] as? [String: Any])
        let row = try XCTUnwrap((group["anchors"] as? [[String: String]])?.first)
        XCTAssertEqual(row["unitID"], "unit-000001"); XCTAssertEqual(row["quote"], selected)
        let stable = try session.sourceReferenceID(unitID: "unit-000001", text: selected)
        XCTAssertEqual(try session.resolveSourceReferences(in: reference(stable)), try session.resolveSourceReferences(in: reference("unit-000001")))
        XCTAssertThrowsError(try session.resolveSourceReferences(in: reference("unit-000002")))
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("[unit:unit-000002]", session: session))
    }
    func testDuplicateTextKeepsTwoExactIdentitiesInsteadOfReverseSearchingFirstMatch() throws {
        var value = book("相同的一句话。"); value.units[1].text = value.units[0].text
        var context = ReadingContext(unitID: "unit-000001", page: 104); context.queryRange = .init(pageStart: 104, pageEnd: 105)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: value, context: context)
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: value)
        let clean = try session.modelSourceText(try XCTUnwrap(session.initialSource(maximumBytes: 4000)))
        XCTAssertTrue(clean.contains("[unit:unit-000001]")); XCTAssertTrue(clean.contains("[unit:unit-000002]"))
        XCTAssertEqual(session.sourceReferences["unit-000001"]?.unitID, "unit-000001")
        XCTAssertEqual(session.sourceReferences["unit-000002"]?.unitID, "unit-000002")
        XCTAssertEqual(try ReadingAnswerEngine.citations("[unit:unit-000002]", session: session).first?.unitID, "unit-000002")
    }
    func testTruncatedLongPageDoesNotGainTheUnsentTailOrLoseItsBudget() throws {
        let value = book("开头" + String(repeating: "甲👨‍👩‍👧‍👦乙\n", count: 1200) + "未提供的末尾秘密")
        for cap in [700, 1600, 3000] {
            var session = try pageSession(value)
            let payload = try XCTUnwrap(session.initialSource(maximumBytes: cap)), clean = try session.modelSourceText(payload)
            XCTAssertLessThanOrEqual(clean.utf8.count, payload.utf8.count); XCTAssertLessThanOrEqual(clean.utf8.count, cap)
            XCTAssertTrue(clean.contains("｜节选】")); XCTAssertFalse(clean.contains("未提供的末尾秘密"))
            let retained = try XCTUnwrap(session.sourceExcerpts.first?.1)
            XCTAssertTrue(value.units[0].text.hasPrefix(retained)); XCTAssertTrue(clean.contains(retained))
            XCTAssertEqual(session.sourceReferences["unit-000001"]?.quote, retained)
        }
    }
    func testTooLargeRangeDoesNotRegisterIdentityOrPretendItsSubsetIsComplete() throws {
        let value = book(String(repeating: "长段正文", count: 1000))
        var context = ReadingContext(unitID: "unit-000001", page: 104); context.queryRange = .init(pageStart: 104, pageEnd: 105)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: value, context: context)
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: value)
        XCTAssertNil(try session.initialSource(maximumBytes: 1000))
        XCTAssertTrue(session.sourceExcerpts.isEmpty); XCTAssertTrue(session.sourceReferences.isEmpty)
    }
    func testExistingReferenceCannotBeReboundToDifferentFragment() throws {
        let value = book(); var session = try pageSession(value)
        let previous = Evidence(unitID: "unit-000002", quote: "另一个已读片段")
        session.sourceReferences["unit-000001"] = previous
        let payload = try XCTUnwrap(session.initialSource(maximumBytes: 3000)), clean = try session.modelSourceText(payload)
        XCTAssertEqual(session.sourceReferences["unit-000001"], previous)
        XCTAssertTrue(clean.contains("整理引用编号：source-"), "遇到歧义显式提供真正的已发编号，不覆盖旧引用")
        XCTAssertTrue(clean.contains(value.units[0].text))
    }
    func testLocationLookupDoesNotReadTextOrGrantCitationsAndUsesActualOrder() async throws {
        let value = book(); var session = try pageSession(value)
        let response = try object(try await session.execute(name: "source_locate", arguments: ["ids": ["unit-000001"]], maximumBytes: 1600))
        let row = try XCTUnwrap((response["locations"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["id"] as? String, "unit-000001"); XCTAssertEqual(row["order"] as? Int, 605)
        XCTAssertTrue((row["locator"] as? String)?.contains("104") == true)
        XCTAssertEqual(response["bodyProvided"] as? Bool, false)
        XCTAssertNil(row["text"]); XCTAssertNil(row["hash"]); XCTAssertNil(row["sourceRef"])
        XCTAssertTrue(session.sourceExcerpts.isEmpty); XCTAssertTrue(session.sourceReferences.isEmpty)
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("[unit:unit-000001]", session: session))
        do { _ = try await session.execute(name: "source_locate", arguments: ["ids": ["unit-000002"]], maximumBytes: 1600); XCTFail("不能查范围外原文") } catch {}
        XCTAssertTrue(session.sourceExcerpts.isEmpty)
    }
    func testLocationLookupRejectsBadListsAndKeepsAllGrantedSchemas() async throws {
        var session = try pageSession(book())
        for args: [String: Any] in [["ids": []], ["ids": ["unit-000001", "unit-000001"]], ["ids": [1]], ["ids": ["unit-000001"], "approve": true]] {
            do { _ = try await session.execute(name: "source_locate", arguments: args, maximumBytes: 1600); XCTFail("无效定位参数通过") } catch {}
        }
        XCTAssertTrue(ReadingQueryToolCatalog.readNames.contains("source_locate"))
        XCTAssertTrue(ReadingAnswerPreferences.readingToolNames.contains("source_locate"))
        XCTAssertTrue(ReadingQuerySession.tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "source_locate" })
    }
    func testClosingPresentationSeparatesBookNotesMessagesAndActualReceipts() throws {
        var session = try pageSession(book())
        session.sourceExcerpts = [("unit-000001", "甲行\n乙行。")]
        session.documentExcerpts = [("note", "我的笔记\n第二行")]
        session.conversationExcerpts = [("old-answer", "旧回答\n不是原书")]
        session.hostReceipts = [#"{"status":"success","applied":true,"message":"只保存了出处"}"#]
        let canonical = try XCTUnwrap(session.finalEvidence(maximumBytes: 2000)), clean = try session.modelSourceText(canonical)
        XCTAssertTrue(clean.contains("【原文 [unit:unit-000001]")); XCTAssertTrue(clean.contains("【已分享笔记 [doc:note]")); XCTAssertTrue(clean.contains("【旧问答 [message:old-answer]"))
        XCTAssertTrue(clean.contains("软件回执（非正文）")); XCTAssertTrue(clean.contains("只保存了出处"))
        XCTAssertTrue(clean.contains("我的笔记\n第二行")); XCTAssertLessThanOrEqual(clean.utf8.count, canonical.utf8.count)
        XCTAssertThrowsError(try session.modelSourceText("{}"))
    }
}
