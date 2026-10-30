import Foundation
import XCTest
@testable import ReadingCore

final class TemporalProjectionReuseTests: XCTestCase {
    private func book() -> BookProject {
        BookProject(id: "projection-isolation", title: "合成测试", originalName: "source.txt", sourceHash: "source", units: (0..<20).map { SourceUnit(id: "u\($0)", order: $0, chapter: "chapter\($0)", text: "原文\($0) e\u{301} 😀。") })
    }
    private func completeReceipts(_ book: BookProject) throws -> [ParagraphReceipt] {
        try book.units.flatMap { unit in
            try ReadingLedger.paragraphs(for: unit, in: book).map { p in
                try JSONDecoder().decode(ParagraphReceipt.self, from: JSONSerialization.data(withJSONObject: ["paragraphID":p.id,"unitID":p.unitID,"unitHash":p.unitHash,"textHash":p.textHash,"utf8Start":p.utf8Start,"utf8End":p.utf8End,"summary":"合成回执","startQuote":p.startQuote,"endQuote":p.endQuote,"issues":[String](),"createdAt":0]))
            }
        }
    }
    func testAtlasManyReceiptsKeepPerUnitCompletenessAndRejectDuplicateAndChangedBytes() throws {
        var b = book(); b.paragraphReceipts = try completeReceipts(b)
        XCTAssertEqual(ReadingAtlasRuntime.build(b).chapters.reduce(0) { $0 + $1.receiptUnits }, 20)
        let duplicate = try XCTUnwrap(b.paragraphReceipts?.first); b.paragraphReceipts?.append(duplicate)
        b.units[1].text += "修订"; b.paragraphReceipts?.removeAll { $0.unitID == "u2" }
        XCTAssertEqual(ReadingAtlasRuntime.build(b).chapters.filter { $0.receiptUnits == 0 }.flatMap(\.unitIDs), ["u0", "u1", "u2"])
        XCTAssertThrowsError(try ReadingLedger.requireComplete(unitIDs: ["u0"], in: b))
        XCTAssertThrowsError(try ReadingLedger.requireComplete(unitIDs: ["u1"], in: b))
        XCTAssertThrowsError(try ReadingLedger.requireComplete(unitIDs: ["u2"], in: b))
    }
    func testAtlasReceiptThresholdAndAmbiguousUnitDoNotInventCoverage() throws {
        for n in [0, 1, 16, 17, 20] {
            var b = book(); b.paragraphReceipts = Array(try completeReceipts(b).prefix(n))
            XCTAssertEqual(ReadingAtlasRuntime.build(b).chapters.reduce(0) { $0 + $1.receiptUnits }, n)
        }
        var b = book(); b.paragraphReceipts = try completeReceipts(b); b.units.append(b.units[0])
        let atlas = ReadingAtlasRuntime.build(b)
        XCTAssertFalse(atlas.chapters.flatMap(\.unitIDs).contains("u0"))
        XCTAssertEqual(atlas.chapters.reduce(0) { $0 + $1.receiptUnits }, 19)
    }
    func testAtlasSharedUnitResolverRechecksEachAnchorAndCurrentSource() throws {
        var b = book()
        let good = try ReadingExperienceRuntime.createAnchor(sourceHash: b.sourceHash, unitID: "u0", quote: b.units[0].text, in: b)
        var foreign = good; foreign.id = "foreign"; foreign.sourceHash = "another-source"
        var literal = good; literal.id = "canonical-equivalent"; literal.quote = literal.quote.precomposedStringWithCanonicalMapping
        b.readingExperience = ReadingExperienceState(anchors: [foreign, literal, good], layers: [ReadingLayer(id: "t", kind: "translation", title: "译文", markdown: "译文", sourceAnchorIDs: [foreign.id, literal.id, good.id])])
        XCTAssertEqual(ReadingAtlasRuntime.build(b).chapters[0].translatedUnits, 1)
        b.readingExperience?.layers[0].sourceAnchorIDs = [foreign.id, literal.id]
        XCTAssertEqual(ReadingAtlasRuntime.build(b).chapters[0].translationTouchedUnits, 0)
        b.readingExperience?.layers[0].sourceAnchorIDs = [good.id]; b.units[0].text += "新原文"
        XCTAssertEqual(ReadingAtlasRuntime.build(b).chapters[0].translationTouchedUnits, 0)
    }
    private func temporalBook() throws -> BookProject {
        var b = book(); let a = try b.units.prefix(2).map { try ReadingExperienceRuntime.createAnchor(sourceHash: b.sourceHash, unitID: $0.id, quote: $0.text, in: b) }
        let e0 = [Evidence(unitID: "u0", quote: b.units[0].text)], e1 = [Evidence(unitID: "u1", quote: b.units[1].text)]
        b.entities = [KnowledgeEntity(id: "p", typeID: "person", name: "人物", evidence: e0), KnowledgeEntity(id: "place", typeID: "place", name: "地点", latitude: 30, longitude: 110, evidence: e0)]
        b.events = [KnowledgeEvent(id: "early", name: "早期", participantIDs: ["p"], evidence: e0), KnowledgeEvent(id: "future", name: "后文", participantIDs: ["p"], evidence: e1)]
        let ext = TemporalExtent(sourceText: "208年", calendar: "gregorian", start: TemporalDate(year: 208), precision: .year, uncertainty: .exact)
        b.temporalKnowledge = TemporalKnowledgeState(anchors: a, presences: [EntityPresence(id: "known", entityID: "p", placeID: "place", eventID: "early", extent: ext, action: "抵达", sourceAnchorIDs: [a[0].id], assertion: .explicit)], eventMetadata: [EventTemporalMetadata(eventID: "early", kind: "event", extent: ext, sourceAnchorIDs: [a[0].id], assertion: .explicit), EventTemporalMetadata(eventID: "future", kind: "event", extent: ext, sourceAnchorIDs: [a[1].id], assertion: .explicit)])
        return b
    }
    func testNestedPointAndWindowSnapshotsKeepWhitelistAndCalendarDistinct() throws {
        let b = try temporalBook(), boundary = KnowledgeReadBoundary(allowedUnitIDs: ["u0"])
        let point = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "p", in: b, at: .date(TemporalDate(year: 208), calendar: "gregorian"), boundary: boundary)
        let window = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "p", in: b, within: .date(from: TemporalDate(year: 208), to: TemporalDate(year: 208), calendar: "gregorian"), boundary: boundary)
        XCTAssertEqual(point.events.map(\.object.id), ["early"]); XCTAssertEqual(window.events.map(\.object.id), ["early"])
        XCTAssertEqual(point.footprints.map(\.id), ["known"]); XCTAssertEqual(window.footprints.map(\.id), ["known"])
        let other = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "p", in: b, at: .date(TemporalDate(year: 208), calendar: "other"), boundary: boundary)
        XCTAssertTrue(other.footprints.isEmpty); XCTAssertEqual(other.events.first?.match, .unknown)
    }
    func testSnapshotIndexDoesNotSurviveProjectOrWhitelistChange() throws {
        var b = try temporalBook(); let first = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "p", in: b, boundary: .all)
        XCTAssertEqual(first.events.count, 2)
        b.events[0].name = "已修改"; b.entities[0].evidence.append(Evidence(unitID: "u1", quote: b.units[1].text))
        XCTAssertNil(try TemporalKnowledgeRuntime.entitySnapshot(entityID: "p", in: b, boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u0"])).object)
        XCTAssertEqual(try TemporalKnowledgeRuntime.entitySnapshot(entityID: "p", in: b, boundary: .all).events.first?.object.name, "已修改")
    }
    func testWindowSnapshotCancellationKeepsProjectBytes() async throws {
        let b = try temporalBook(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let before = try encoder.encode(b)
        let cancelled = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "p", in: b, within: .narrative(from: 1, to: 10), boundary: .all); return false }
            catch is CancellationError { return true } catch { return false }
        }.value
        XCTAssertTrue(cancelled); XCTAssertEqual(try encoder.encode(b), before)
    }
}
