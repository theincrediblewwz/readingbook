import Foundation
import XCTest
@testable import ReadingCore

final class TemporalKnowledgeTests: XCTestCase {
    private let texts = ["208年，曹操至江陵；许都军报提及刘备参加南征。", "209年，曹操回到许都。", "第三回，曹操与刘备决裂。"]
    private func year(_ value: Int, label: String? = nil) -> TemporalExtent {
        TemporalExtent(sourceText: label ?? "\(value)年", calendar: "gregorian", start: TemporalDate(year: value), precision: .year, uncertainty: .exact)
    }
    private func fixture(temporal: Bool = true) throws -> BookProject {
        let units = texts.enumerated().map { SourceUnit(id: "u\($0.offset + 1)", order: $0.offset, chapter: "第\($0.offset + 1)章", page: $0.offset + 1, text: $0.element) }
        var book = BookProject(title: "时态测试读本", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(texts.joined(separator: "\n").utf8)), units: units)
        PluginEngine.seed(&book)
        let first = Evidence(unitID: "u1", quote: texts[0]), second = Evidence(unitID: "u2", quote: texts[1]), later = Evidence(unitID: "u3", quote: texts[2])
        book.entities = [KnowledgeEntity(id: "cao", typeID: "person", name: "曹操", aliases: ["孟德"], evidence: [first]),
                         KnowledgeEntity(id: "liu", typeID: "person", name: "刘备", evidence: [first]),
                         KnowledgeEntity(id: "jiangling", typeID: "place", name: "江陵", evidence: [first]),
                         KnowledgeEntity(id: "xudu", typeID: "place", name: "许都", evidence: [first, second])]
        book.events = [KnowledgeEvent(id: "campaign", name: "南征", dateText: "208年", startYear: 208, placeIDs: ["jiangling", "xudu"], participantIDs: ["cao", "liu"], evidence: [first]),
                       KnowledgeEvent(id: "phase", name: "抵达江陵", dateText: "208年", startYear: 208, placeIDs: ["jiangling"], participantIDs: ["cao"], evidence: [first])]
        book.relations = [KnowledgeRelation(id: "split", fromID: "cao", toID: "liu", label: "决裂", evidence: [later])]
        guard temporal else { return book }
        let anchors = try units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.id, quote: $0.text, in: book) }
        let narrative = TemporalExtent(sourceText: "第三回", precision: .narrative, uncertainty: .exact, narrativeStart: 3)
        book.temporalKnowledge = TemporalKnowledgeState(
            profile: BookProfile(genres: [.history, .warfare, .fiction], customGenres: ["传记"], entityTypeIDs: ["person", "place"], methodIDs: ["narrative"], rendererIDs: ["map"], timeSystem: "gregorian"), anchors: anchors,
            presences: [EntityPresence(id: "p208", entityID: "cao", placeID: "jiangling", eventID: "phase", extent: year(208), action: "至江陵", sourceAnchorIDs: [anchors[0].id], assertion: .explicit),
                        EntityPresence(id: "p209", entityID: "cao", placeID: "xudu", extent: year(209), action: "回到许都", sourceAnchorIDs: [anchors[1].id], assertion: .explicit)],
            participations: [Participation(id: "part", entityID: "liu", eventID: "campaign", role: "参加", extent: year(208), sourceAnchorIDs: [anchors[0].id], assertion: .explicit)],
            eventMetadata: [EventTemporalMetadata(eventID: "campaign", kind: "battle", extent: year(208), sourceAnchorIDs: [anchors[0].id], assertion: .explicit),
                            EventTemporalMetadata(eventID: "phase", kind: "phase", parentEventID: "campaign", phaseOrder: 0, extent: year(208), sourceAnchorIDs: [anchors[0].id], assertion: .explicit)],
            relationMetadata: [RelationTemporalMetadata(id: "r3", relationID: "split", validity: narrative, sourceAnchorIDs: [anchors[2].id], assertion: .explicit)])
        return book
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }

    func testOldJSONAdaptsStableObjectsWithoutMigrationOrManufacturedFootprints() throws {
        var old = try fixture(temporal: false)
        old.documents = [DocumentRecord(id: "note", title: "我的笔记")]
        let data = try encoded(old)
        XCTAssertNil((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["temporalKnowledge"])
        let restored = try JSONDecoder().decode(BookProject.self, from: data)
        XCTAssertNil(restored.temporalKnowledge)
        XCTAssertNoThrow(try TemporalKnowledgeRuntime.validateStoredState(in: restored))
        let objects = try TemporalKnowledgeRuntime.objects(in: restored, boundary: .all)
        XCTAssertEqual(Set(objects.map(\.id)), Set(old.entities.map(\.id) + old.events.map(\.id) + ["note"]))
        let person = try XCTUnwrap(objects.first { $0.id == "cao" })
        XCTAssertEqual(person.typeID, "person"); XCTAssertEqual(person.aliases, ["孟德"])
        XCTAssertEqual(person.version.count, 64)
        XCTAssertEqual(try TemporalKnowledgeRuntime.object(id: "cao", in: restored, boundary: .all)?.version, person.version)
        let snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "liu", in: restored, boundary: .all)
        XCTAssertFalse(snapshot.events.isEmpty)
        XCTAssertTrue(snapshot.presences.isEmpty); XCTAssertTrue(snapshot.footprints.isEmpty)
        XCTAssertTrue(snapshot.participations.isEmpty, "Legacy participant arrays are not independently anchored participation records.")
        XCTAssertEqual(try encoded(restored), data, "Queries do not persist or backfill new metadata.")
        XCTAssertEqual(try TemporalKnowledgeRuntime.events(in: restored, at: .date(TemporalDate(year: 208), calendar: "gregorian"), boundary: .all).first?.match, .unknown, "Legacy year numbers do not identify a calendar.")
    }

    func testTimeSnapshotUsesOnlyExplicitIndependentPresenceAndDoesNotInterpolate() throws {
        let book = try fixture()
        try TemporalKnowledgeRuntime.validateStoredState(in: book)
        let early = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, at: .date(TemporalDate(year: 208), calendar: "gregorian"), boundary: .all)
        XCTAssertEqual(early.footprints.map(\.placeID), ["jiangling"])
        let later = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, at: .date(TemporalDate(year: 209), calendar: "gregorian"), boundary: .all)
        XCTAssertEqual(later.footprints.map(\.placeID), ["xudu"])
        let after = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, at: .date(TemporalDate(year: 210), calendar: "gregorian"), boundary: .all)
        XCTAssertTrue(after.footprints.isEmpty, "The last known place is not extended into every later date.")
        let participant = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "liu", in: book, at: .date(TemporalDate(year: 208), calendar: "gregorian"), boundary: .all)
        XCTAssertEqual(participant.participations.map(\.id), ["part"])
        XCTAssertTrue(participant.footprints.isEmpty, "Two participants and two event places cannot create four person locations.")
    }

    func testUnknownApproximateAndNarrativeTimeStayDistinct() throws {
        XCTAssertEqual(TemporalKnowledgeRuntime.match(TemporalExtent(sourceText: "其后"), at: .date(TemporalDate(year: 208), calendar: "gregorian")), .unknown)
        let approximate = TemporalExtent(sourceText: "约208至210年", calendar: "gregorian", start: TemporalDate(year: 208), end: TemporalDate(year: 210), precision: .year, uncertainty: .approximate, kind: .uncertainRange)
        XCTAssertNoThrow(try TemporalKnowledgeRuntime.validateExtent(approximate))
        XCTAssertEqual(TemporalKnowledgeRuntime.match(approximate, at: .date(TemporalDate(year: 209), calendar: "gregorian")), .possible)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(approximate, at: .date(TemporalDate(year: 211), calendar: "gregorian")), .outside)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(year(208), at: .date(TemporalDate(year: 208, month: 6, day: 1), calendar: "gregorian")), .possible)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(year(208), at: .date(TemporalDate(year: 208), calendar: "reign-era")), .unknown)
        let narrative = TemporalExtent(sourceText: "第三回", precision: .narrative, uncertainty: .exact, narrativeStart: 3)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(narrative, at: .narrative(3)), .matches)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(narrative, at: .narrative(4)), .outside)
        let ongoing = TemporalExtent(sourceText: "第三回起", precision: .narrative, uncertainty: .exact, kind: .interval, narrativeStart: 3)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(ongoing, at: .narrative(4)), .matches)
        var invalid = TemporalExtent(); invalid.start = TemporalDate(year: 208)
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateExtent(invalid))
        invalid = TemporalExtent(sourceText: "209年2月29日", calendar: "gregorian", start: TemporalDate(year: 209, month: 2, day: 29), precision: .day, uncertainty: .exact)
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateExtent(invalid))
    }

    func testWindowIntersectionUsesMonthDayPrecisionAndInclusiveEndpoints() throws {
        let day = TemporalExtent(sourceText: "208年6月15日", calendar: "gregorian", start: TemporalDate(year: 208, month: 6, day: 15), precision: .day, uncertainty: .exact)
        let june = TemporalQueryWindow.date(from: TemporalDate(year: 208, month: 6), to: TemporalDate(year: 208, month: 6), calendar: "gregorian")
        XCTAssertEqual(TemporalKnowledgeRuntime.match(day, within: june), .matches)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(year(208), within: june), .possible, "只有年份不能冒充月份定位。")
        let endingOnDay = TemporalQueryWindow.date(from: TemporalDate(year: 208, month: 6, day: 1), to: TemporalDate(year: 208, month: 6, day: 15), calendar: "gregorian")
        XCTAssertEqual(TemporalKnowledgeRuntime.match(day, within: endingOnDay), .matches)
        let after = TemporalQueryWindow.date(from: TemporalDate(year: 208, month: 6, day: 16), to: TemporalDate(year: 208, month: 7), calendar: "gregorian")
        XCTAssertEqual(TemporalKnowledgeRuntime.match(day, within: after), .outside)
        let interval = TemporalExtent(sourceText: "208年1月至12月", calendar: "gregorian", start: TemporalDate(year: 208, month: 1), end: TemporalDate(year: 208, month: 12), precision: .month, uncertainty: .exact, kind: .interval)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(interval, within: june), .matches, "窗口在区间内部也须命中，不能只测端点。")
        let fine = TemporalQueryWindow.date(from: TemporalDate(year: 208, month: 6, day: 10), to: TemporalDate(year: 208, month: 6, day: 20), calendar: "gregorian")
        XCTAssertEqual(TemporalKnowledgeRuntime.match(interval, within: fine), .possible)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(day, within: .date(from: TemporalDate(year: 208), to: TemporalDate(year: 208), calendar: "reign-era")), .unknown)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(TemporalExtent(), within: june), .unknown)
    }

    func testWindowOpenBoundsNarrativeUncertaintyAndInvalidQueriesStayDistinct() throws {
        let after = TemporalQueryWindow.date(from: TemporalDate(year: 209), to: nil, calendar: "gregorian")
        let before = TemporalQueryWindow.date(from: nil, to: TemporalDate(year: 208), calendar: "gregorian")
        XCTAssertEqual(TemporalKnowledgeRuntime.match(year(208), within: after), .outside)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(year(208), within: before), .matches)
        let since = TemporalExtent(sourceText: "208年起", calendar: "gregorian", start: TemporalDate(year: 208), precision: .year, uncertainty: .exact, kind: .interval)
        let until = TemporalExtent(sourceText: "至208年", calendar: "gregorian", end: TemporalDate(year: 208), precision: .year, uncertainty: .exact, kind: .interval)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(since, within: after), .matches)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(until, within: after), .outside)
        var approximate = since; approximate.uncertainty = .approximate
        XCTAssertEqual(TemporalKnowledgeRuntime.match(approximate, within: after), .possible)
        let narrative = TemporalExtent(sourceText: "第三至五回", precision: .narrative, uncertainty: .approximate, kind: .uncertainRange, narrativeStart: 3, narrativeEnd: 5)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(narrative, within: .narrative(from: 4, to: 6)), .possible)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(narrative, within: .narrative(from: nil, to: 2)), .outside)
        XCTAssertEqual(TemporalKnowledgeRuntime.match(narrative, within: after), .unknown)
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validate(window: .date(from: nil, to: nil, calendar: "gregorian")))
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validate(window: .date(from: TemporalDate(year: 210), to: TemporalDate(year: 209), calendar: "gregorian")))
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validate(window: .date(from: TemporalDate(year: 209, month: 2, day: 29), to: nil, calendar: "gregorian")))
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validate(window: .date(from: TemporalDate(year: 208), to: nil, calendar: "")))
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validate(window: .narrative(from: 5, to: 3)))
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validate(window: .narrative(from: -1, to: nil)))
    }

    func testWindowSnapshotsKeepIndependentFootprintsAndSourceBoundaryWithoutChangingPointAPI() throws {
        let book = try fixture(), original = try encoded(book)
        let window = TemporalQueryWindow.date(from: TemporalDate(year: 208), to: TemporalDate(year: 209), calendar: "gregorian")
        XCTAssertEqual(try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, within: window, boundary: .all).footprints.map(\.id), ["p208", "p209"])
        XCTAssertEqual(try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, at: .date(TemporalDate(year: 209), calendar: "gregorian"), boundary: .all).footprints.map(\.id), ["p209"])
        let participant = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "liu", in: book, within: window, boundary: .all)
        XCTAssertEqual(participant.participations.map(\.id), ["part"])
        XCTAssertTrue(participant.footprints.isEmpty, "事件参与者不能与事件地点相乘造出人物位置。")
        let early = try KnowledgeReadBoundary.throughSourceUnit("u1", in: book)
        XCTAssertEqual(try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, within: window, boundary: early).footprints.map(\.id), ["p208"])
        XCTAssertTrue(try TemporalKnowledgeRuntime.relations(in: book, within: .narrative(from: 2, to: 4), boundary: early).isEmpty)
        XCTAssertEqual(try TemporalKnowledgeRuntime.relations(objectID: "cao", in: book, within: .narrative(from: 2, to: 4), boundary: .all).first?.match, .matches)
        XCTAssertTrue(try TemporalKnowledgeRuntime.relations(in: book, within: .narrative(from: 4, to: 5), boundary: .all).isEmpty)
        XCTAssertEqual(try encoded(book), original, "时间窗口是只读查询，不迁移或回填原档。")
    }

    func testWindowDoesNotExtendNarrowParticipationOrDrawUncertainPresenceAsKnown() throws {
        var book = try fixture()
        book.temporalKnowledge?.eventMetadata[0].extent = TemporalExtent(sourceText: "208年", calendar: "gregorian", start: TemporalDate(year: 208), end: TemporalDate(year: 210), precision: .year, uncertainty: .exact, kind: .interval)
        let later = TemporalQueryWindow.date(from: TemporalDate(year: 209), to: TemporalDate(year: 210), calendar: "gregorian")
        XCTAssertFalse(try TemporalKnowledgeRuntime.events(in: book, within: later, boundary: .all).isEmpty)
        XCTAssertTrue(try TemporalKnowledgeRuntime.events(in: book, entityID: "liu", within: later, boundary: .all).isEmpty, "宽事件不能把208年的参与扩展到209–210年。")
        book.temporalKnowledge?.presences[0].assertion = .inferred
        book.temporalKnowledge?.presences[0].explanation = "仅推测在场。"
        book.temporalKnowledge?.presences[1].extent.uncertainty = .approximate
        let window = TemporalQueryWindow.date(from: TemporalDate(year: 208), to: TemporalDate(year: 209), calendar: "gregorian")
        let uncertain = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, within: window, boundary: .all)
        XCTAssertTrue(uncertain.footprints.isEmpty)
        XCTAssertEqual(uncertain.uncertainPresences.map(\.id), ["p208", "p209"])
        XCTAssertEqual(TemporalKnowledgeRuntime.match(book.temporalKnowledge!.presences[0], within: window), .possible)
    }

    func testWideWindowRequiresEventAndParticipantToShareOneComparableTime() throws {
        var book = try fixture()
        let window = TemporalQueryWindow.date(from: TemporalDate(year: 208), to: TemporalDate(year: 209), calendar: "gregorian")
        // Both individually intersect the window, but there is no simultaneous
        // point. Retain the contradictory source records without joining them.
        let laterAnchorID = book.temporalKnowledge!.anchors[1].id
        book.temporalKnowledge?.participations[0].extent = year(209)
        book.temporalKnowledge?.participations[0].sourceAnchorIDs = [laterAnchorID]
        try TemporalKnowledgeRuntime.validateStoredState(in: book)
        XCTAssertFalse(try TemporalKnowledgeRuntime.events(in: book, within: window, boundary: .all).isEmpty)
        XCTAssertTrue(try TemporalKnowledgeRuntime.events(in: book, entityID: "liu", within: window, boundary: .all).isEmpty)
        book.temporalKnowledge?.presences[0].extent = year(209)
        book.temporalKnowledge?.presences[0].sourceAnchorIDs = [laterAnchorID]
        XCTAssertFalse(try TemporalKnowledgeRuntime.events(in: book, entityID: "cao", within: window, boundary: .all).contains { $0.object.id == "phase" })

        book.temporalKnowledge?.participations[0].extent?.calendar = "reign-era"
        let incomparable = try TemporalKnowledgeRuntime.events(in: book, entityID: "liu", within: window, boundary: .all)
        XCTAssertEqual(incomparable.first?.participantMatch, .unknown)
        XCTAssertEqual(incomparable.first?.match, .unknown, "不同历法不能宣称同一时段明确参与。")

        let narrative = TemporalQueryWindow.narrative(from: 2, to: 4)
        book.temporalKnowledge?.eventMetadata[0].extent = TemporalExtent(sourceText: "第三回", precision: .narrative, uncertainty: .exact, narrativeStart: 3)
        book.temporalKnowledge?.participations[0].extent = TemporalExtent(sourceText: "第二回", precision: .narrative, uncertainty: .exact, narrativeStart: 2)
        XCTAssertTrue(try TemporalKnowledgeRuntime.events(in: book, entityID: "liu", within: narrative, boundary: .all).isEmpty)
    }

    func testWindowQueryCancellationDoesNotCancelCanonicalValidation() async throws {
        let book = try fixture()
        let task = Task.detached { () -> (Bool, Bool) in
            withUnsafeCurrentTask { $0?.cancel() }
            let cancelled: Bool
            do { _ = try TemporalKnowledgeRuntime.events(in: book, within: .narrative(from: 1, to: 5), boundary: .all); cancelled = false }
            catch is CancellationError { cancelled = true }
            catch { cancelled = false }
            return (cancelled, (try? TemporalKnowledgeRuntime.validateStoredState(in: book)) != nil)
        }
        let result = await task.value
        XCTAssertTrue(result.0); XCTAssertTrue(result.1)
    }

    func testSpoilerWhitelistHidesFutureSourcesAndMixedSourceSummaries() throws {
        var book = try fixture()
        let boundary = try KnowledgeReadBoundary.throughSourceUnit("u1", in: book)
        let snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, boundary: boundary)
        XCTAssertEqual(snapshot.footprints.map(\.id), ["p208"])
        XCTAssertTrue(snapshot.relations.isEmpty)
        XCTAssertNil(try TemporalKnowledgeRuntime.object(id: "xudu", in: book, boundary: boundary), "A summary with early and future evidence cannot leak its complete accumulated content.")
        let campaign = try XCTUnwrap(TemporalKnowledgeRuntime.object(id: "campaign", in: book, boundary: boundary))
        XCTAssertFalse(campaign.references["places"]?.contains("xudu") ?? true)
        XCTAssertEqual(campaign.withheldReferenceCount, 1)
        book.entities[0].summary = "包含后文的结局"; book.entities[0].evidence.append(Evidence(unitID: "u3", quote: texts[2]))
        XCTAssertNil(try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, boundary: boundary).object)
        XCTAssertNotNil(try TemporalKnowledgeRuntime.object(id: "cao", in: book, boundary: .all))
        XCTAssertTrue(try TemporalKnowledgeRuntime.objects(in: book, boundary: .processed(in: book)).isEmpty, "Processing coverage is not silently inferred from the selected page.")
    }

    func testParentBattleAndTemporalRelationsKeepProvenanceAndRejectBrokenReferences() throws {
        let good = try fixture()
        let phase = try XCTUnwrap(TemporalKnowledgeRuntime.events(in: good, boundary: .all).first { $0.object.id == "phase" })
        XCTAssertEqual(phase.metadata?.parentEventID, "campaign")
        XCTAssertTrue(try TemporalKnowledgeRuntime.relations(objectID: "cao", in: good, at: .narrative(2), boundary: .all).isEmpty)
        XCTAssertEqual(try TemporalKnowledgeRuntime.relations(objectID: "cao", in: good, at: .narrative(3), boundary: .all).first?.match, .matches)
        var bad = good; bad.temporalKnowledge?.presences[0].entityID = "missing"
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: bad))
        bad = good; bad.temporalKnowledge?.presences[0].placeID = "liu"
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: bad))
        bad = good; bad.temporalKnowledge?.presences[0].sourceAnchorIDs = ["missing-anchor"]
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: bad))
        bad = good; bad.temporalKnowledge?.presences[0].extent.sourceText = "原书未写的年份"
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: bad))
        bad = good; bad.temporalKnowledge?.eventMetadata[0].parentEventID = "phase"
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: bad), "Campaign/phase parent references cannot form a cycle.")
        bad = good; bad.temporalKnowledge?.relationMetadata[0].relationID = "missing"
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: bad))
    }

    func testInferredAndUnknownAssertionsNeverBecomeExplicitFootprints() throws {
        var book = try fixture()
        book.temporalKnowledge?.presences[0].assertion = .inferred
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: book), "An inference needs a retained explanation.")
        book.temporalKnowledge?.presences[0].explanation = "仅由上下文推测，未明言人物在场。"
        try TemporalKnowledgeRuntime.validateStoredState(in: book)
        let snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, at: .date(TemporalDate(year: 208), calendar: "gregorian"), boundary: .all)
        XCTAssertTrue(snapshot.footprints.isEmpty)
        XCTAssertEqual(snapshot.uncertainPresences.map(\.id), ["p208"])
    }

    func testBroadEventCannotExtendAnIndividualsNarrowParticipationTime() throws {
        let source = "南征从208年至210年；刘备仅在208年参战。"
        var book = BookProject(title: "参与时间", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(source.utf8)), units: [SourceUnit(id: "u1", order: 0, chapter: "第一章", text: source)])
        PluginEngine.seed(&book)
        let evidence = Evidence(unitID: "u1", quote: source)
        book.entities = [KnowledgeEntity(id: "liu", typeID: "person", name: "刘备", evidence: [evidence])]
        book.events = [KnowledgeEvent(id: "campaign", name: "南征", startYear: 208, endYear: 210, participantIDs: ["liu"], evidence: [evidence])]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: source, in: book)
        book.temporalKnowledge = TemporalKnowledgeState(anchors: [anchor], participations: [Participation(id: "p", entityID: "liu", eventID: "campaign", role: "参战", extent: year(208), sourceAnchorIDs: [anchor.id], assertion: .explicit)],
            eventMetadata: [EventTemporalMetadata(eventID: "campaign", extent: TemporalExtent(sourceText: "208年至210年", calendar: "gregorian", start: TemporalDate(year: 208), end: TemporalDate(year: 210), precision: .year, uncertainty: .exact, kind: .interval), sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        try TemporalKnowledgeRuntime.validateStoredState(in: book)
        XCTAssertTrue(try TemporalKnowledgeRuntime.events(in: book, entityID: "liu", at: .date(TemporalDate(year: 210), calendar: "gregorian"), boundary: .all).isEmpty)
        XCTAssertEqual(try TemporalKnowledgeRuntime.events(in: book, entityID: "liu", at: .date(TemporalDate(year: 208), calendar: "gregorian"), boundary: .all).first?.participantMatch, .matches)
        book.temporalKnowledge?.participations[0].extent = nil
        let unknown = try TemporalKnowledgeRuntime.events(in: book, entityID: "liu", at: .date(TemporalDate(year: 210), calendar: "gregorian"), boundary: .all)
        XCTAssertEqual(unknown.first?.participantMatch, .unknown)
        XCTAssertEqual(unknown.first?.match, .unknown, "An exact campaign date is not an exact individual participation date.")
    }

    func testTemporalMetadataRoundTripsThroughRealPackageAndUnrelatedNoteSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Temporal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("book.txt")
        try Data(texts.joined(separator: "\n").utf8).write(to: source)
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library", isDirectory: true))
        let book = try fixture()
        try await repository.create(book, sourceURL: source)
        let saved = try await repository.saveDocument(project: book, document: DocumentRecord(id: "note", title: "我的笔记"), markdown: "# 保留用户正文\n")
        var invalid = saved; invalid.temporalKnowledge?.presences[0].placeID = "missing-place"
        do { try await repository.save(invalid); XCTFail("The package writer must reject dangling temporal references.") } catch { }
        let report = try await repository.loadReport()
        XCTAssertTrue(report.issues.isEmpty)
        let reloaded = try XCTUnwrap(report.projects.first)
        XCTAssertEqual(reloaded.temporalKnowledge, book.temporalKnowledge)
        XCTAssertEqual(reloaded.entities, book.entities); XCTAssertEqual(reloaded.events, book.events)
        let markdown = try await repository.readDocument(bookID: saved.id, document: try XCTUnwrap(saved.documents.first))
        XCTAssertEqual(markdown, "# 保留用户正文\n")
    }
}
