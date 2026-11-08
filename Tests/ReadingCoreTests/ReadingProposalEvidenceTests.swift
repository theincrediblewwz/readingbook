import Foundation
import XCTest
@testable import ReadingCore

final class ReadingProposalEvidenceTests: XCTestCase {
    private func fixture() -> BookProject {
        var book = BookProject(title: "引文修复合成样例", originalName: "book.txt", sourceHash: "literal-fixture", units: [
            .init(id: "unit-000001", order: 0, chapter: "第一章", page: 1, text: "黃蓋火攻。\n將近三更。"),
            .init(id: "unit-000002", order: 1, chapter: "第一章", page: 2, text: "曹操走至五更。"),
            .init(id: "unit-000003", order: 2, chapter: "后文", page: 3, text: "后文尚未提供。")])
        PluginEngine.seed(&book); return book
    }
    private func session() throws -> ReadingQuerySession {
        let book = fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        for unit in book.units.prefix(2) {
            session.sourceExcerpts.append((unit.id, unit.text))
            session.sourceReferences[try session.sourceReferenceID(unitID: unit.id, text: unit.text)] = .init(unitID: unit.id, quote: unit.text)
        }
        return session
    }
    func testEvidenceErrorListsBothBadQuotesAndOnlyActuallySuppliedCandidates() throws {
        let session = try session()
        let data = Data(#"{"batch":{"knowledge":{"anchors":[{"clientID":"wrong-page","unitID":"unit-000001","quote":"曹操走至五更。"},{"clientID":"rewritten","unitID":"unit-000001","quote":"黃蓋立即火攻。"}]}}}"#.utf8)
        do { try session.validateProposal(name: "knowledge_changes_propose", data: data); XCTFail("Invalid evidence admitted") }
        catch let error as ReadingProposalEvidenceError {
            XCTAssertEqual(error.issues.count, 2)
            XCTAssertEqual(error.issues[0]["path"], "$.batch.knowledge.anchors[0]")
            XCTAssertEqual(error.issues[0]["matchingSuppliedUnitID"], "unit-000002")
            XCTAssertNotNil(error.issues[0]["matchingSuppliedSourceRef"])
            XCTAssertEqual(error.issues[1]["unitID"], "unit-000001")
            XCTAssertNotNil(error.issues[1]["suppliedUnitSourceRef"])
        }
    }
    func testRepairHintsDoNotSearchHiddenBookTextOrGrantNewEvidence() throws {
        let session = try session()
        let data = Data(#"{"batch":{"knowledge":{"anchors":[{"clientID":"hidden","unitID":"unit-000001","quote":"后文尚未提供。"}]}}}"#.utf8)
        do { try session.validateProposal(name: "knowledge_changes_propose", data: data); XCTFail("Hidden evidence admitted") }
        catch let error as ReadingProposalEvidenceError {
            XCTAssertNil(error.issues[0]["matchingSuppliedUnitID"])
            XCTAssertNil(error.issues[0]["matchingSuppliedSourceRef"])
        }
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("[unit:unit-000003]", session: session))
        XCTAssertThrowsError(try ReadingAnswerEngine.citations("[unit:000001]", session: session), "No silent ID guessing")
    }
    func testExplicitCorrectionAndIssuedReferencePassTheSameLiteralGuard() throws {
        let session = try session()
        let ref = try session.sourceReferenceID(unitID: "unit-000002", text: fixture().units[1].text)
        let data = try JSONSerialization.data(withJSONObject: ["batch": ["knowledge": ["anchors": [["clientID": "correct", "sourceRef": ref]]]]])
        let expanded = try session.resolveSourceReferences(in: data)
        XCTAssertNoThrow(try session.validateProposal(name: "knowledge_changes_propose", data: expanded))
        XCTAssertTrue(String(decoding: expanded, as: UTF8.self).contains("曹操走至五更。"))
    }
    func testFinalPackingPrefersToolReferencedTextAndSuppliesExactCitation() throws {
        var session = try session()
        session.sourceExcerpts.append(("unit-000003", String(repeating: "不相关尾页", count: 1000)))
        session.recordSourceExcerpt("unit-000001", text: fixture().units[0].text)
        let result = try XCTUnwrap(session.finalEvidence(maximumBytes: 900))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(value["actualReadFragments"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["id"] as? String, "unit-000001")
        XCTAssertEqual(rows.first?["citation"] as? String, "[unit:unit-000001]")
        XCTAssertFalse(session.hasOnlyPreloadedSources)
    }
    func testFullWidthCitationPunctuationNormalizesWithoutGuessingIdentity() throws {
        let session = try session()
        let text = ReadingAnswerEngine.normalizedCitationDelimiters("原文［unit:unit-000001］，笔记［doc：note-1］。")
        XCTAssertEqual(text, "原文[unit:unit-000001]，笔记[doc:note-1]。")
        XCTAssertEqual(try ReadingAnswerEngine.citations(ReadingAnswerEngine.normalizedCitationDelimiters("［unit:unit-000001］"), session: session).map(\.unitID), ["unit-000001"])
        XCTAssertThrowsError(try ReadingAnswerEngine.citations(ReadingAnswerEngine.normalizedCitationDelimiters("［unit:000001］"), session: session))
        XCTAssertThrowsError(try ReadingAnswerEngine.citations(ReadingAnswerEngine.normalizedCitationDelimiters("［unit:unit-000003］"), session: session))
        XCTAssertEqual(ReadingAnswerEngine.normalizedCitationDelimiters("普通全角［说明］与原字保持不动"), "普通全角［说明］与原字保持不动")
    }

}
