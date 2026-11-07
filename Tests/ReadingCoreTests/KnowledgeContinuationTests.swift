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
    private func lineWrappedBook(_ text: String) throws -> BookProject {
        var book = try fixture(); book.units[0].text = text
        book.sourceHash = try BookImporter.sha256(Data(book.units.map(\.text).joined(separator: "\n").utf8))
        book.events[0].evidence = [.init(unitID: "one", quote: text)]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "one", quote: text, in: book)
        book.temporalKnowledge = .init(anchors: [anchor], eventMetadata: [.init(eventID: "arrival", kind: "行程", sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        return book
    }
    func testPDFLineWrappedTimeLabelResolvesToExactAnchorTextBeforeReview() throws {
        let book = try lineWrappedBook("第一回，208\n年，曹操到江陵。"), before = try encoded(book)
        let result = try prepared(updated(book), in: book)
        XCTAssertTrue(result.proposal.requiresConfirmation)
        XCTAssertEqual(result.project.temporalKnowledge?.eventMetadata[0].extent?.sourceText, "208\n年")
        XCTAssertEqual(result.project.events[0].evidence, book.events[0].evidence)
        XCTAssertEqual(result.project.temporalKnowledge?.anchors, book.temporalKnowledge?.anchors)
        XCTAssertEqual(try encoded(book), before)
        XCTAssertNoThrow(try TemporalKnowledgeRuntime.validateStoredState(in: result.project))
    }
    func testTimeLabelDoesNotNormalizeSpacesPunctuationOrDifferentWords() throws {
        let book = try lineWrappedBook("第一回，208\n年，曹操到江陵。")
        for label in ["208 年", "208，年", "209年", "二百零八年"] {
            var value = updated(book); value.extent?.sourceText = label
            XCTAssertThrowsError(try prepared(value, in: book), label)
        }
    }
    func testAmbiguousLineWrappedTimeCannotChooseAnArbitraryOccurrence() throws {
        let book = try lineWrappedBook("前记208\n年，后记208\r\n年。")
        XCTAssertThrowsError(try prepared(updated(book), in: book))
    }
    func testTimeLabelCannotBorrowAnUnreferencedAnchorOrAUnitOutsideScope() throws {
        var book = try lineWrappedBook("第一回，曹操到江陵。")
        book.units[1].text = "第二回，208\n年，曹操回许都。"
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "two", quote: book.units[1].text, in: book)
        book.temporalKnowledge?.anchors.append(anchor)
        XCTAssertThrowsError(try prepared(updated(book), in: book))
        var value = updated(book); value.sourceAnchorIDs = [anchor.id]
        XCTAssertThrowsError(try prepared(value, in: book))
    }
    func testTemporalPreviewShowsEventDateAndGroundingWithoutOpaqueRecordJSON() throws {
        let book = try fixture(), result = try prepared(updated(book), in: book)
        let text = result.proposal.summary.joined(separator: "\n")
        XCTAssertTrue(text.contains("到江陵")); XCTAssertTrue(text.contains("208年"))
        XCTAssertTrue(text.contains("未记录")); XCTAssertTrue(text.contains("时间依据原句"))
        XCTAssertTrue(text.contains("补充时间依据")); XCTAssertTrue(text.contains("原文明说"))
        XCTAssertFalse(text.contains("\"eventID\"")); XCTAssertFalse(text.contains("eventMetadata"))
        XCTAssertFalse(text.contains(book.temporalKnowledge!.anchors[0].id))
    }
    func testTemporalPreviewPreservesBothDateBoundsCalendarAndUncertainty() throws {
        var book = try fixture(); book.temporalKnowledge!.eventMetadata[0].extent = time()
        var after = book
        after.temporalKnowledge!.eventMetadata[0].extent = .init(sourceText: "208年", calendar: "建安", start: .init(year: 12, month: 11, day: 20), end: .init(year: 12, month: 11, day: 22), precision: .day, uncertainty: .approximate, kind: .interval)
        func preview(_ after: BookProject) throws -> String {
            try ControlledChangeSummary.describe([.init(collection: .eventMetadata, id: "arrival", before: encoded(book.temporalKnowledge!.eventMetadata[0]), after: encoded(after.temporalKnowledge!.eventMetadata[0]))], from: book, to: after).joined(separator: "\n")
        }
        let text = try preview(after)
        XCTAssertTrue(text.contains("公历208年")); XCTAssertTrue(text.contains("建安12年11月20日"))
        XCTAssertTrue(text.contains("12年11月22日")); XCTAssertTrue(text.contains("约"))
        after.temporalKnowledge!.eventMetadata[0].extent = .init(sourceText: "208年", calendar: "建安", end: .init(year: 13), precision: .year, uncertainty: .disputed, kind: .interval)
        let open = try preview(after)
        XCTAssertTrue(open.contains("建安13年")); XCTAssertTrue(open.contains("截至")); XCTAssertTrue(open.contains("有争议"))
    }
    func testNarrativePreviewDoesNotInventCalendarDates() throws {
        let book = try fixture(); var value = updated(book)
        value.extent = .init(sourceText: "第一回", precision: .narrative, uncertainty: .approximate, kind: .interval, narrativeStart: 0, narrativeEnd: 3)
        let text = try prepared(value, in: book).proposal.summary.joined(separator: "\n")
        XCTAssertTrue(text.contains("原文顺序0—3")); XCTAssertTrue(text.contains("第一回"))
        XCTAssertFalse(text.contains("公历")); XCTAssertFalse(text.contains("narrative"))
    }
    func testTemporalPreviewIncludesEveryChangedClassificationParentPhaseAndSourceLocation() throws {
        var book = try fixture()
        book.types.append(.init(id: "eventtype", name: "行程事件", icon: "clock", fields: []))
        book.events.append(.init(id: "parent", name: "南征", evidence: book.events[0].evidence))
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "two", quote: book.units[1].text, in: book)
        book.temporalKnowledge?.anchors.append(anchor)
        book.temporalKnowledge!.eventMetadata[0].kind = "event"
        book.temporalKnowledge!.eventMetadata[0].assertion = .unknown
        var value = updated(book); value.typeID = "eventtype"; value.kind = "行程"; value.assertion = .explicit
        value.parentEventID = "parent"; value.phaseOrder = 1; value.sourceAnchorIDs.append(anchor.id)
        let text = try prepared(value, in: book, allowed: ["one", "two"]).proposal.summary.joined(separator: "\n")
        for expected in ["行程事件", "通用事件", "行程", "南征", "阶段顺序", "待核对", "原文明说", "第2页", "2处"] { XCTAssertTrue(text.contains(expected), expected) }
        XCTAssertFalse(text.contains(anchor.id))
    }
}
