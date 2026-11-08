import Foundation
import XCTest
@testable import ReadingCore

private actor ReferenceProposalSubmissions {
    var count = 0
    func submit() -> Data { count += 1; return Data(#"{"ok":true,"status":"success","applied":true}"#.utf8) }
}

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

    func testOpaqueIDCopyErrorReportsEveryFieldAndScopedIdentityWithoutApplyingIt() throws {
        var book = fixture()
        let actual = "w-e03efa270fd3df0611832255b0c22ec353fb7f86"
        let typo = "w-e03efa270fd3df0611832255b0b22ec353fb7f86"
        book.events = [.init(id: actual, name: "黃蓋火攻", evidence: [.init(unitID: "unit-000001", quote: book.units[0].text)])]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "unit-000001", page: 1))
        let query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let data = try JSONSerialization.data(withJSONObject: ["batch": ["knowledge": ["eventMetadata": [["eventID": typo, "kind": "部署", "sourceAnchorIDs": ["anchor-one"], "assertion": "explicit", "explanation": "合成资料"], ["eventID": typo, "kind": "行军", "sourceAnchorIDs": ["anchor-two"], "assertion": "explicit", "explanation": "合成资料"]]]]])
        do { try query.validateProposal(name: "knowledge_changes_propose", data: data); XCTFail("Typo must still fail") }
        catch let error as ReadingProposalReferenceError {
            XCTAssertEqual(error.issues.map(\.path), ["$.batch.knowledge.eventMetadata[0].eventID", "$.batch.knowledge.eventMetadata[1].eventID"])
            XCTAssertEqual(error.issues[0].candidates.map(\.id), [actual])
            XCTAssertEqual(error.issues[0].candidates[0].name, "黃蓋火攻")
            XCTAssertEqual(error.issues[0].candidates[0].kind, "event")
            XCTAssertFalse(error.issues[0].candidatesPartial)
            XCTAssertFalse(error.receiptIssues.isEmpty)
        }
        XCTAssertEqual(query.project?.events.map(\.id), [actual]); XCTAssertNil(query.project?.temporalKnowledge)
    }
    func testIdentityHintsNeverRevealHiddenObjectsOrOfferReplacementForKnownOutOfScopeID() throws {
        let visible = ReadingProposalReferenceError.Candidate(id: "event-visible-01", name: "范围内", kind: "event")
        let hidden = ReadingProposalReferenceError.Candidate(id: "event-hidden-01", name: "未分享的后文秘密", kind: "event")
        for id in ["event-hidden-01", "event-hidden-02"] {
            do { try ReadingProposalReferenceError.check([("$.eventID", id)], allowed: [visible.id], known: [visible.id, hidden.id], identities: [visible, hidden]); XCTFail("Hidden ID must fail") }
            catch let error as ReadingProposalReferenceError {
                XCTAssertTrue(error.issues[0].candidates.isEmpty)
                let text = String(decoding: try JSONSerialization.data(withJSONObject: error.receiptIssues), as: UTF8.self)
                XCTAssertFalse(text.contains(hidden.name))
            }
        }
    }
    func testAmbiguousIDHintsStayBoundedAndNeverSelectOneForTheModel() throws {
        let identities = (1...6).map { ReadingProposalReferenceError.Candidate(id: "event-000\($0)", name: "事件\($0)", kind: "event") }
        do {
            try ReadingProposalReferenceError.check((0..<30).map { ("$.events[\($0)].id", "event-0000") }, allowed: Set(identities.map(\.id)), known: [], identities: identities)
            XCTFail("Ambiguous ID must fail")
        } catch let error as ReadingProposalReferenceError {
            XCTAssertEqual(error.issues.count, 8); XCTAssertEqual(error.issues[0].candidates.count, 3)
            XCTAssertTrue(error.issues[0].candidatesPartial)
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject: error.receiptIssues).count, 9000)
        }
    }
    func testOneByteIDComparisonIncludesMissingCharacterButDoesNotGuessNamesOrLargeIDs() throws {
        for pair in [("event-1234", "event-1235"), ("event-1234", "event-12345"), ("event-12345", "event-1234")] {
            XCTAssertTrue(ReadingProposalReferenceError.differsByOneByte(pair.0, pair.1))
        }
        for pair in [("event-1234", "event-1234"), ("event-1234", "event-1256"), ("person", "persen"), ("事件-123456", "事仟-123456"), (String(repeating: "a", count: 129), String(repeating: "a", count: 128))] {
            XCTAssertFalse(ReadingProposalReferenceError.differsByOneByte(pair.0, pair.1))
        }
        XCTAssertNoThrow(try ReadingProposalReferenceError.check([("$.eventID", "new-event")], allowed: ["new-event"], known: [], identities: []), "Explicit same-batch declarations remain valid")
    }
    func testEngineFeedsReferenceErrorBackAndOnlySubmitsExplicitModelCorrection() async throws {
        var book = fixture()
        let actual = "entity-000001", other = "entity-000002", typo = "entity-000001x"
        let source = Evidence(unitID: book.units[0].id, quote: book.units[0].text)
        book.entities = [.init(id: actual, typeID: "person", name: "黃蓋", evidence: [source]), .init(id: other, typeID: "place", name: "本页地点", evidence: [source])]
        let submissions = ReferenceProposalSubmissions()
        let proposals = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in await submissions.submit() })
        func payload(_ fromID: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["batch": ["knowledge": ["newRelationIDs": ["new-relation"], "relations": [["id": "new-relation", "fromID": fromID, "toID": other, "label": "出现在", "evidence": [["unitID": source.unitID, "quote": source.quote]]]]]]])
            return String(decoding: data, as: UTF8.self)
        }
        var requests = 0
        _ = try await ReadingAnswerEngine.run(question: "整理这页关系", project: book, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128000), documents: [:],
            context: .init(unitID: book.units[0].id, page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 128000, remainingRequests: 5, proposalAccess: proposals, preferences: .init(interaction: .functional)) { messages, _, _, _ in
                requests += 1
                if requests == 2 {
                    let receipt = try XCTUnwrap(messages.last?["content"] as? String)
                    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receipt.utf8)) as? [String: Any])
                    XCTAssertNotNil(value["referenceIssues"]); XCTAssertNil(value["referenceGuide"], "ID errors should not drown the actual repair in unrelated type instructions")
                    XCTAssertTrue(receipt.contains(actual)); XCTAssertTrue(receipt.contains("relations[0].fromID"))
                    let count = await submissions.count; XCTAssertEqual(count, 0, "Hint never repairs or submits the invalid proposal")
                }
                if requests <= 2 { return .init(message: .init(role: "assistant", content: nil, refusal: nil,
                    tool_calls: [.init(id: "repair-\(requests)", type: "function", function: .init(name: "knowledge_changes_propose", arguments: try payload(requests == 1 ? typo : actual)))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20) }
                return .init(message: .init(role: "assistant", content: "已整理这页关系。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        XCTAssertEqual(requests, 3)
        let count = await submissions.count; XCTAssertEqual(count, 1)
    }
    func testMixedSourceReferenceFeedbackListsExactFieldsAndCountsAllRowsWithoutRepairing() throws {
        let query = try session(), ref = try XCTUnwrap(query.sourceReferences.keys.sorted().first)
        let rows: [[String: Any]] = (0..<24).map { ["clientID": "anchor-\($0)", "sourceRef": ref, "unitID": "wrong-unit", "quote": "错误引文"] }
        let data = try JSONSerialization.data(withJSONObject: ["batch": ["knowledge": ["anchors": rows]]])
        do { _ = try query.resolveSourceReferences(in: data); XCTFail("Contradictory fields cannot be silently removed") }
        catch let error as ReadingSourceReferenceError {
            XCTAssertEqual(error.affectedCount, 24); XCTAssertEqual(error.issues.count, 4)
            XCTAssertEqual(error.issues[0]["path"] as? String, "$.batch.knowledge.anchors[0]")
            XCTAssertEqual(error.issues[0]["removeFields"] as? [String], ["quote", "unitID"])
            XCTAssertEqual(error.issues[0]["sourceRefIsValid"] as? Bool, true)
            let example = try XCTUnwrap(error.issues[0]["correctedShapeExample"] as? [String: String])
            XCTAssertEqual(example, ["clientID": "anchor-0", "sourceRef": ref])
            XCTAssertTrue(ReadingSourceReferenceError.repairRule.contains("unitID"))
        }
        XCTAssertEqual(query.sourceExcerpts.count, 2)
    }
    func testSourceReferenceErrorDoesNotOfferAReplacementForInventedOrExpiredReference() throws {
        var query = try session()
        let invalidRows: [[String: Any]] = [["sourceRef": "source-invented"], ["sourceRef": 5]]
        for value in invalidRows {
            do { _ = try query.resolveSourceReferences(in: JSONSerialization.data(withJSONObject: ["evidence": [value]])); XCTFail("Invalid sourceRef admitted") }
            catch let error as ReadingSourceReferenceError {
                XCTAssertEqual(error.issues[0]["sourceRefIsValid"] as? Bool, false)
                XCTAssertNil(error.issues[0]["correctedShapeExample"])
            }
        }
        let ref = try XCTUnwrap(query.sourceReferences.keys.first); query.sourceExcerpts = []
        XCTAssertThrowsError(try query.resolveSourceReferences(in: JSONSerialization.data(withJSONObject: ["evidence": [["sourceRef": ref]]])))
    }
    func testEventFactAndTimeAssertionConflictHasFieldFeedbackAndKeepsSavedClassification() throws {
        var book = fixture()
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: book.units[0].id, quote: book.units[0].text, in: book)
        book.events = [.init(id: "fire-event", name: "黃蓋火攻", evidence: [.init(unitID: book.units[0].id, quote: book.units[0].text)])]
        book.temporalKnowledge = .init(anchors: [anchor], eventMetadata: [.init(eventID: "fire-event", kind: "战事", sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: book.units[0].id, page: 1))
        var query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        query.sourceExcerpts = [(book.units[0].id, book.units[0].text)]
        func proposal(_ assertion: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["batch": ["knowledge": ["eventMetadata": [["eventID": "fire-event", "kind": "战事", "sourceAnchorIDs": [anchor.id], "assertion": assertion, "explanation": "仅补充时间说明"]]]]])
        }
        do { try query.validateProposal(name: "knowledge_changes_propose", data: proposal("inferred")); XCTFail("Event assertion must not be rewritten when only deriving time") }
        catch let error as ReadingProposalMetadataError {
            XCTAssertEqual(error.issues[0]["path"], "$.batch.knowledge.eventMetadata[0].assertion")
            XCTAssertEqual(error.issues[0]["currentValue"], "explicit")
            XCTAssertEqual(error.issues[0]["proposedValue"], "inferred")
            XCTAssertTrue(error.issues[0]["reason"]?.contains("extent.assertion") == true)
        }
        XCTAssertNoThrow(try query.validateProposal(name: "knowledge_changes_propose", data: proposal("explicit")))
        XCTAssertEqual(query.project?.temporalKnowledge?.eventMetadata.first?.assertion, .explicit)
    }
    func testAnchorFormDeclaresBothSourceRoutesAndTheirMutualExclusion() throws {
        let schema = ReadingProposalSchemas.sourceAnchor
        XCTAssertEqual(schema["required"] as? [String], ["clientID"])
        let variants = try XCTUnwrap(schema["oneOf"] as? [[String: Any]])
        XCTAssertEqual(variants.count, 2)
        XCTAssertEqual(variants[0]["required"] as? [String], ["sourceRef"])
        let forbidden = try XCTUnwrap((variants[0]["not"] as? [String: Any])?["anyOf"] as? [[String: Any]])
        XCTAssertEqual(forbidden.compactMap { ($0["required"] as? [String])?.first }, ["unitID", "quote", "prefix", "suffix"])
        XCTAssertEqual(variants[1]["required"] as? [String], ["unitID", "quote"])
        XCTAssertEqual((variants[1]["not"] as? [String: Any])?["required"] as? [String], ["sourceRef"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

}
