import Foundation
import XCTest
@testable import ReadingCore

final class KnowledgeContinuationTests: XCTestCase {
    private func fixture() throws -> BookProject {
        var book = BookProject(title: "续整理", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data("第一回，208年，曹操到江陵。\n第二回，209年，曹操回许都。".utf8)), units: [
            .init(id: "one", order: 0, chapter: "第一回", page: 1, text: "第一回，208年，曹操到江陵。"),
            .init(id: "two", order: 1, chapter: "第二回", page: 2, text: "第二回，209年，曹操回许都。")])
        PluginEngine.seed(&book)
        book.events = [.init(id: "arrival", name: "到江陵", evidence: [.init(unitID: "one", quote: book.units[0].text)])]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "one", quote: book.units[0].text, in: book)
        book.temporalKnowledge = .init(anchors: [anchor], eventMetadata: [.init(eventID: "arrival", kind: "行程", sourceAnchorIDs: [anchor.id], assertion: .explicit, explanation: "原有说明")])
        return book
    }
    private func time(_ year: Int = 208) -> TemporalExtent {
        .init(sourceText: "\(year)年", calendar: "gregorian", start: .init(year: year), precision: .year, uncertainty: .exact)
    }
    private func updated(_ book: BookProject) -> EventTemporalMetadata {
        var value = book.temporalKnowledge!.eventMetadata[0]; value.extent = time(); value.explanation = "补充时间依据"; return value
    }
    private func prepared(_ value: EventTemporalMetadata, in book: BookProject, allowed: Set<String> = ["one"]) throws -> PreparedControlledChange {
        let grant = ControlledWriteGrant(id: "grant", bookID: book.id, sourceHash: book.sourceHash, baseRevision: "revision", grantRevision: 0,
            permissions: [.knowledge], allowedUnitIDs: allowed, editableDocumentIDs: [], requiresReceipts: false, reason: "继续整理", expiresAt: .distantFuture)
        return try ControlledChangeBuilder.prepare(.init(knowledge: .init(eventMetadata: [value])), grant: grant, project: book,
            documents: [:], proposalID: "proposal", operationID: "operation", baseRevision: "revision")
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    func testMissingEventTimePreparesReviewAndPreservesSharedRecords() throws {
        let book = try fixture(), value = try prepared(updated(book), in: book)
        XCTAssertTrue(value.proposal.requiresConfirmation)
        XCTAssertEqual(value.project.temporalKnowledge?.eventMetadata[0].extent, time())
        XCTAssertEqual(value.project.temporalKnowledge?.eventMetadata[0].explanation, "原有说明\n\n补充时间依据")
        XCTAssertEqual(value.project.events, book.events); XCTAssertEqual(value.project.units, book.units)
        XCTAssertEqual(value.project.sourceHash, book.sourceHash); XCTAssertEqual(value.project.documents, book.documents)
        XCTAssertNil(book.temporalKnowledge?.eventMetadata[0].extent, "准备提案不能提前修改调用方原书")
    }
    func testReviewCommitUndoAndIdempotentReplayKeepOneEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Continuation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.txt"), book = try fixture()
        try Data(book.units.map(\.text).joined(separator: "\n").utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        try await repository.create(book, sourceURL: source)
        let grant = try await repository.issueChangeGrant(bookID: book.id, permissions: [.knowledge], allowedUnitIDs: ["one"], requiresReceipts: false, reason: "补时间")
        let batch = ControlledChangeBatch(knowledge: .init(eventMetadata: [updated(book)]))
        let proposal = try await repository.prepareChanges(batch, grant: grant)
        XCTAssertTrue(proposal.requiresConfirmation)
        do { _ = try await repository.commitChanges(proposalID: proposal.id, grant: grant); XCTFail("修改已有记录必须先审阅") } catch {}
        let approval = try await repository.approveChanges(proposalID: proposal.id, digest: proposal.digest)
        let committed = try await repository.commitChanges(proposalID: proposal.id, grant: grant, approval: approval)
        XCTAssertEqual(committed.project.events.count, 1)
        XCTAssertEqual(committed.project.temporalKnowledge?.eventMetadata[0].extent, time())
        let replay = try await repository.commitChanges(proposalID: proposal.id, grant: grant, approval: approval)
        XCTAssertTrue(replay.replayed)
        let undone = try await repository.undoChanges(bookID: book.id, operationID: proposal.operationID)
        XCTAssertEqual(try encoded(undone.project.temporalKnowledge), try encoded(book.temporalKnowledge))
        XCTAssertEqual(undone.project.events, book.events); XCTAssertEqual(undone.project.units, book.units)
    }
    func testRepeatedEnrichmentIsNoOpAndDoesNotDuplicateExplanationOrAnchors() throws {
        let book = try fixture(), first = try prepared(updated(book), in: book).project
        var candidate = first, identity = ControlledIdentityMap(operationID: "repeat", project: candidate)
        try ControlledKnowledgeRuntime.apply(.init(eventMetadata: [updated(book)]), to: &candidate, allowedUnitIDs: ["one"], requiresReceipts: false, identity: &identity)
        XCTAssertEqual(try encoded(candidate), try encoded(first))
    }
    func testKnownTimeTypeParentClassificationAndAssertionCannotBeReplaced() throws {
        let base = try fixture()
        var book = base
        book.events.append(.init(id: "parent", name: "原父事件", evidence: base.events[0].evidence))
        book.events.append(.init(id: "other", name: "另父事件", evidence: base.events[0].evidence))
        book.temporalKnowledge!.eventMetadata[0].extent = time()
        book.temporalKnowledge!.eventMetadata[0].typeID = "person"
        book.temporalKnowledge!.eventMetadata[0].parentEventID = "parent"
        book.temporalKnowledge!.eventMetadata[0].phaseOrder = 1
        let original = try encoded(book)
        for field in ["extent", "typeID", "parentEventID", "phaseOrder", "kind", "assertion"] {
            var value = book.temporalKnowledge!.eventMetadata[0]
            switch field {
            case "extent": value.extent = time(209)
            case "typeID": value.typeID = "place"
            case "parentEventID": value.parentEventID = "other"
            case "phaseOrder": value.phaseOrder = 2
            case "kind": value.kind = "战役"
            default: value.assertion = .inferred
            }
            XCTAssertThrowsError(try prepared(value, in: book), field)
            XCTAssertEqual(try encoded(book), original)
        }
    }
    func testOmittedOptionalFieldsRetainExistingTimeAndReaderCorrections() throws {
        var book = try fixture()
        book.events[0].name = "读者修正名称"
        book.knowledgeUserEdits = .init(); book.knowledgeUserEdits?.records = [.init(kind: .event, objectID: "arrival", fields: ["name"], basis: .interpretation)]
        book.temporalKnowledge!.eventMetadata[0].extent = time()
        var value = book.temporalKnowledge!.eventMetadata[0]
        value.extent = nil; value.kind = "event"; value.assertion = .unknown; value.explanation = "追加依据"
        let result = try prepared(value, in: book).project
        XCTAssertEqual(result.events[0].name, "读者修正名称")
        XCTAssertEqual(result.knowledgeUserEdits, book.knowledgeUserEdits)
        XCTAssertEqual(result.temporalKnowledge?.eventMetadata[0].kind, "行程")
        XCTAssertEqual(result.temporalKnowledge?.eventMetadata[0].assertion, .explicit)
        XCTAssertEqual(result.temporalKnowledge?.eventMetadata[0].extent, time())
    }
    func testNewAnchorsMustStayInsideScopeAndMatchOriginalText() throws {
        var book = try fixture()
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "two", quote: book.units[1].text, in: book)
        book.temporalKnowledge?.anchors.append(anchor)
        var value = updated(book); value.sourceAnchorIDs = [anchor.id]; value.extent = time(209)
        XCTAssertThrowsError(try prepared(value, in: book), "不能用范围外锚点补时间")
        value.sourceAnchorIDs = ["forged"]
        XCTAssertThrowsError(try prepared(value, in: book))
        value = updated(book); value.extent?.sourceText = "第1回（依叙事顺序）"
        XCTAssertThrowsError(try prepared(value, in: book), "说明标签不能冒充原文时间字句")
    }
    func testNarrativeIntervalsNeedRealAnchorAndCannotMasqueradeAsDates() throws {
        let book = try fixture(); var value = updated(book)
        value.extent = .init(sourceText: "第一回", precision: .narrative, uncertainty: .approximate, kind: .interval, narrativeStart: 0, narrativeEnd: 3)
        XCTAssertEqual(try prepared(value, in: book).project.temporalKnowledge?.eventMetadata[0].extent, value.extent)
        value.extent?.kind = .point
        XCTAssertThrowsError(try prepared(value, in: book))
        value.extent?.kind = .interval; value.extent?.start = .init(year: 208)
        XCTAssertThrowsError(try prepared(value, in: book))
    }
    func testUnrelatedImmutableRecordsAndPhaseValidationRemainStrict() throws {
        let book = try fixture()
        var value = updated(book); value.phaseOrder = 1
        XCTAssertThrowsError(try prepared(value, in: book))
        value = updated(book); value.parentEventID = value.eventID
        XCTAssertThrowsError(try prepared(value, in: book))
        var anchors = book.temporalKnowledge!.anchors
        var replacement = anchors[0]; replacement.quote = "改写的原文"
        XCTAssertThrowsError(try ControlledKnowledgeRuntime.appendImmutable(replacement, to: &anchors))
        XCTAssertEqual(anchors, book.temporalKnowledge!.anchors)
    }
    func testEmptyOrDuplicateProposedTemporalEvidenceCannotBorrowOldAuthority() throws {
        let book = try fixture(); var value = updated(book)
        value.sourceAnchorIDs = []
        XCTAssertThrowsError(try prepared(value, in: book))
        value = updated(book); value.sourceAnchorIDs += value.sourceAnchorIDs
        XCTAssertThrowsError(try prepared(value, in: book))
    }
}
