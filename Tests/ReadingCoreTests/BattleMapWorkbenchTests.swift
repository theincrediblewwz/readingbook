import Foundation
import XCTest
@testable import ReadingCore

private actor BattleProposalCounter { var value = 0; func increment() { value += 1 } }

final class BattleMapWorkbenchTests: XCTestCase {
    private func day(_ number: Int, inferred: Bool = false) -> TemporalExtent {
        .init(sourceText: number == 20 ? "十一月二十日" : "二十一日", calendar: "建安", start: .init(year: 12, month: 11, day: number), precision: .day, uncertainty: .exact,
              assertion: inferred ? .inferred : .explicit, explanation: inferred ? "年与月由前文纪年推算，原文只写日" : nil)
    }
    private func fixture() throws -> BookProject {
        let texts = ["建安十二年十一月二十日，黄盖自南岸向乌林火攻。", "二十一日，曹操从乌林经华容退向江陵。", "后文，另有一支新军来到。"]
        let units = texts.enumerated().map { SourceUnit(id: "u\($0.offset+1)", order: $0.offset, chapter: "第\($0.offset+1)回", page: $0.offset+1, text: $0.element) }
        var book = BookProject(title: "地图行动测试（合成数据）", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(texts.joined().utf8)), units: units)
        PluginEngine.seed(&book)
        let a = Evidence(unitID: "u1", quote: texts[0]), b = Evidence(unitID: "u2", quote: texts[1]), c = Evidence(unitID: "u3", quote: texts[2])
        book.entities = [
            .init(id: "gai", typeID: "person", name: "黄盖", evidence: [a]), .init(id: "cao", typeID: "person", name: "曹操", evidence: [b]),
            .init(id: "south", typeID: "place", name: "南岸", latitude: 29.8, longitude: 113.6, locationNote: "合成测试坐标", evidence: [a]),
            .init(id: "wulin", typeID: "place", name: "乌林", latitude: 29.9, longitude: 113.7, locationNote: "合成测试坐标", evidence: [a]),
            .init(id: "huarong", typeID: "place", name: "华容", latitude: 30.0, longitude: 113.0, locationNote: "合成测试坐标", evidence: [b]),
            .init(id: "jiangling", typeID: "place", name: "江陵", latitude: 30.3, longitude: 112.2, locationNote: "合成测试坐标", evidence: [b]),
            .init(id: "future", typeID: "person", name: "后文新军", evidence: [c])]
        book.events = [.init(id: "fire", name: "火攻", placeIDs: ["south", "wulin"], participantIDs: ["gai"], evidence: [a]),
                       .init(id: "retreat", name: "退向江陵", placeIDs: ["wulin", "huarong", "jiangling"], participantIDs: ["cao"], evidence: [b])]
        book.relations = [.init(id: "attack", fromID: "south", toID: "wulin", label: "黄盖火攻", evidence: [a]),
                          .init(id: "withdraw", fromID: "wulin", toID: "jiangling", label: "曹操撤退", evidence: [b])]
        let anchors = try units.prefix(2).map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.id, quote: $0.text, in: book) }
        book.temporalKnowledge = .init(anchors: anchors, eventMetadata: [
            .init(eventID: "fire", extent: day(20), sourceAnchorIDs: [anchors[0].id], assertion: .explicit),
            .init(eventID: "retreat", extent: day(21, inferred: true), sourceAnchorIDs: [anchors[0].id, anchors[1].id], assertion: .explicit)], relationMetadata: [
                .init(id: "attack-time", relationID: "attack", validity: day(20), sourceAnchorIDs: [anchors[0].id], assertion: .explicit,
                      spatial: .init(kind: "火攻", actorIDs: ["gai"], eventID: "fire")),
                .init(id: "withdraw-time", relationID: "withdraw", validity: day(21, inferred: true), sourceAnchorIDs: [anchors[0].id, anchors[1].id], assertion: .explicit,
                      explanation: "方向示意，非古道路测绘", spatial: .init(kind: "撤退", actorIDs: ["cao"], viaPlaceIDs: ["huarong"], eventID: "retreat"))])
        return book
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func grant(_ book: BookProject, units: Set<String> = ["u1", "u2"]) -> ControlledWriteGrant {
        .init(id: "test-grant", bookID: book.id, sourceHash: book.sourceHash, baseRevision: "rev", grantRevision: 0, permissions: [.knowledge], allowedUnitIDs: units,
              editableDocumentIDs: [], requiresReceipts: false, reason: "地图整理", expiresAt: .distantFuture)
    }
    private func prepare(_ changes: ControlledKnowledgeChanges, in book: BookProject, units: Set<String> = ["u1", "u2"]) throws -> PreparedControlledChange {
        try ControlledChangeBuilder.prepare(.init(knowledge: changes), grant: grant(book, units: units), project: book, documents: [:], proposalID: "preview", operationID: "operation", baseRevision: "rev")
    }
    func testLegacyTemporalPayloadKeepsBytesAndNoSpatialMigration() throws {
        let legacy = Data(#"{"assertion":"explicit","explanation":"","id":"r","relationID":"shared","sourceAnchorIDs":["a"],"validity":{"kind":"point","precision":"unknown","sourceText":"","uncertainty":"unknown"}}"#.utf8)
        let record = try JSONDecoder().decode(RelationTemporalMetadata.self, from: legacy)
        XCTAssertNil(record.spatial); XCTAssertNil(record.validity.assertion); XCTAssertNil(record.validity.explanation)
        XCTAssertEqual(try encoded(record), legacy)
    }
    func testDateAxisSeparatesEventsWithinSameYearAndPreservesNamedCalendar() throws {
        let properties = try XCTUnwrap(ReadingProposalSchemas.extent["properties"] as? [String: Any])
        let calendar = try XCTUnwrap(properties["calendar"] as? [String: Any])
        XCTAssertTrue((calendar["description"] as? String)?.contains("同一历法") == true)
        let axis = TemporalAxis("calendar-day:建安"), a = try XCTUnwrap(axis.value(day(20))), b = try XCTUnwrap(axis.value(day(21)))
        XCTAssertEqual(b-a, 1); XCTAssertEqual(axis.label(a), "12年11月20日"); XCTAssertEqual(axis.input(a), "12/11/20")
        XCTAssertEqual(axis.point(a), .date(.init(year: 12, month: 11, day: 20), calendar: "建安"))
        XCTAssertEqual(axis.window(from: a, to: b), .date(from: .init(year: 12, month: 11, day: 20), to: .init(year: 12, month: 11, day: 21), calendar: "建安"))
        XCTAssertEqual(TemporalAxis.available([day(20)]), ["calendar-day:建安", "calendar:建安"])
        XCTAssertNil(axis.value(.init(sourceText: "208年", calendar: "gregorian", start: .init(year: 208), precision: .year, uncertainty: .exact)))
    }
    func testAxisInputsAndExtremeCustomDatesAreBoundedWithoutGregorianConversion() throws {
        let axis = TemporalAxis("calendar-day:自定历法")
        for year in [-1_000_000_000_000, -1, 0, 1_000_000_000_000] {
            let extent = TemporalExtent(sourceText: "日期", calendar: "自定历法", start: .init(year: year, month: 64, day: 128), precision: .day, uncertainty: .exact)
            let value = try XCTUnwrap(axis.value(extent)); XCTAssertEqual(axis.date(value), extent.start)
            XCTAssertEqual(axis.parse(axis.input(value)), value)
        }
        XCTAssertNil(axis.parse("12/0/1")); XCTAssertNil(axis.parse("12/65/1")); XCTAssertNil(axis.parse("12/1/129")); XCTAssertNil(axis.parse("NaN"))
        XCTAssertNil(axis.point(.infinity)); XCTAssertNil(axis.window(from: 2, to: 1)); XCTAssertNil(axis.window(from: .nan, to: 2))
        XCTAssertNil(TemporalAxis("calendar-day:gregorian").parse("209/2/29")); XCTAssertNotNil(TemporalAxis("calendar-day:gregorian").parse("208/2/29"))
        XCTAssertEqual(TemporalAxis("calendar:建安").parse("12"), 12)
        XCTAssertEqual(TemporalAxis("narrative").label(.infinity), "时间待定")
    }
    func testRoutesReuseCanonicalPlacesAndOrderedWaypointsWithoutInventingPresence() throws {
        let book = try fixture(); try TemporalKnowledgeRuntime.validateStoredState(in: book)
        let routes = try SpatialKnowledgeRuntime.routes(in: book)
        XCTAssertEqual(routes.map(\.relationID), ["attack", "withdraw"])
        XCTAssertEqual(routes[1].placeIDs, ["wulin", "huarong", "jiangling"]); XCTAssertEqual(routes[1].actorNames, ["曹操"])
        XCTAssertEqual(routes[1].coordinates.count, 3); XCTAssertEqual(routes[0].assertion, .explicit)
        XCTAssertFalse(routes[0].isUncertain); XCTAssertTrue(routes[1].isUncertain)
        XCTAssertTrue(try TemporalKnowledgeRuntime.entitySnapshot(entityID: "cao", in: book, boundary: .all).footprints.isEmpty)
        XCTAssertTrue(routes.allSatisfy { !$0.evidence.isEmpty && $0.locationNotes == Array(repeating: "合成测试坐标", count: $0.placeIDs.count) })
    }
    func testRangeFilteringUsesDayPrecisionAndIncludesInferredDatesAsPossible() throws {
        let book = try fixture(), axis = TemporalAxis("calendar-day:建安")
        let a = try XCTUnwrap(axis.value(day(20))), b = try XCTUnwrap(axis.value(day(21)))
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: book, within: axis.window(from: a, to: a)).map(\.relationID), ["attack"])
        let inferred = try SpatialKnowledgeRuntime.routes(in: book, within: axis.window(from: b, to: b))
        XCTAssertEqual(inferred.map(\.relationID), ["withdraw"]); XCTAssertEqual(inferred[0].timeMatch, .possible)
        let events = try TemporalKnowledgeRuntime.events(in: book, within: try XCTUnwrap(axis.window(from: b, to: b)), boundary: .all)
        XCTAssertEqual(events.map { $0.object.id }, ["retreat"]); XCTAssertEqual(events.first?.match, .possible)
        XCTAssertEqual(book.temporalKnowledge?.eventMetadata[1].assertion, .explicit, "行动依据不能被日期推断覆盖")
    }
    func testTimeAndFactUncertaintyRemainIndependentForPointSnapshots() throws {
        var book = try fixture()
        book.temporalKnowledge!.relationMetadata[0].assertion = .inferred
        book.temporalKnowledge!.relationMetadata[0].explanation = "行动有推断"
        let route = try XCTUnwrap(SpatialKnowledgeRuntime.routes(in: book, at: .date(.init(year: 12, month: 11, day: 20), calendar: "建安")).first)
        XCTAssertTrue(route.isUncertain); XCTAssertEqual(route.timeMatch, .possible)
        let anchor = book.temporalKnowledge!.anchors[0].id
        var time = day(20); time.assertion = .inferred; time.explanation = "仅时间有推算"
        book.temporalKnowledge!.presences = [.init(id: "presence", entityID: "gai", placeID: "south", extent: time, action: "出现", sourceAnchorIDs: [anchor], assertion: .explicit)]
        let snapshot = try TemporalKnowledgeRuntime.entitySnapshot(entityID: "gai", in: book, at: .date(.init(year: 12, month: 11, day: 20), calendar: "建安"), boundary: .all)
        XCTAssertTrue(snapshot.footprints.isEmpty); XCTAssertEqual(snapshot.uncertainPresences.count, 1)
    }
    func testUnknownTimeRoutesNeverPretendToMatchChosenPeriod() throws {
        var book = try fixture(); book.temporalKnowledge!.relationMetadata[0].validity = .init()
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: book).count, 2)
        XCTAssertTrue(try SpatialKnowledgeRuntime.routes(in: book, at: .narrative(1)).isEmpty)
    }
    func testActorEventAndObjectFiltersRemainIndependent() throws {
        let book = try fixture()
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: book, actorID: "cao").map(\.relationID), ["withdraw"])
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: book, eventIDs: ["fire"]).map(\.relationID), ["attack"])
        XCTAssertTrue(try SpatialKnowledgeRuntime.routes(in: book, eventIDs: []).isEmpty)
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: book, relevantObjectIDs: ["huarong"]).map(\.relationID), ["withdraw"])
        XCTAssertTrue(try SpatialKnowledgeRuntime.routes(in: book, relevantObjectIDs: ["missing"]).isEmpty)
    }
    func testScopeHidesFutureRouteReferencesAndKeepsVisibleRelation() throws {
        var book = try fixture(); book.temporalKnowledge!.relationMetadata[0].spatial!.actorIDs += ["future"]
        try TemporalKnowledgeRuntime.validateStoredState(in: book)
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: ["u1"])
        XCTAssertTrue(try SpatialKnowledgeRuntime.routes(in: book, boundary: boundary).isEmpty)
        let values = try TemporalKnowledgeRuntime.relations(in: book, boundary: boundary)
        XCTAssertEqual(values.count, 1); XCTAssertNil(values[0].metadata?.spatial, "不能在只读关系返回中泄漏后文ID")
        let window = TemporalQueryWindow.date(from: .init(year: 12), to: .init(year: 12), calendar: "建安")
        XCTAssertNil(try TemporalKnowledgeRuntime.relations(in: book, within: window, boundary: boundary).first?.metadata?.spatial)
    }
    func testCoordinatesMissingOrInvalidStayOffMapButKeepKnowledge() throws {
        var book = try fixture(); book.entities[2].latitude = nil
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: book).map(\.relationID), ["withdraw"])
        book.entities[3].longitude = .infinity
        XCTAssertThrowsError(try SpatialKnowledgeRuntime.routes(in: book))
        XCTAssertEqual(book.relations.count, 2)
        XCTAssertThrowsError(try SpatialKnowledgeRuntime.routes(in: book, limit: 0)); XCTAssertThrowsError(try SpatialKnowledgeRuntime.routes(in: book, limit: 129))
    }
    func testInvalidSpatialReferencesAndLoopsFailValidation() throws {
        let book = try fixture()
        for spatial in [SpatialRelation(kind: "进攻", actorIDs: ["missing"]), .init(kind: "进攻", viaPlaceIDs: ["gai"]),
                        .init(kind: "进攻", viaPlaceIDs: ["south"]), .init(kind: "进攻", eventID: "missing"), .init(kind: "")] {
            var invalid = book; invalid.temporalKnowledge!.relationMetadata[0].spatial = spatial
            XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: invalid))
        }
        var invalid = book; invalid.temporalKnowledge!.eventMetadata[1].extent!.explanation = ""
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: invalid))
    }
    func testSameBatchClientIDsResolveActorsWaypointsAndEventAtomically() throws {
        var book = try fixture(); book.relations = []; book.temporalKnowledge!.relationMetadata = []
        let evidence = Evidence(unitID: "u1", quote: book.units[0].text)
        let changes = ControlledKnowledgeChanges(entities: [.init(id: "new-army", typeID: "person", name: "水军", evidence: [evidence])],
            relations: [.init(id: "new-action", fromID: "south", toID: "wulin", label: "水军行动", evidence: [evidence])], newEntityIDs: ["new-army"], newRelationIDs: ["new-action"],
            relationMetadata: [.init(id: "new-time", relationID: "new-action", validity: day(20), sourceAnchorIDs: [book.temporalKnowledge!.anchors[0].id], assertion: .explicit,
                                     spatial: .init(kind: "佯降与火攻", actorIDs: ["new-army"], eventID: "fire"))])
        let prepared = try prepare(changes, in: book)
        let route = try XCTUnwrap(SpatialKnowledgeRuntime.routes(in: prepared.project).first)
        XCTAssertEqual(route.kind, "佯降与火攻"); XCTAssertEqual(route.actorNames, ["水军"])
        XCTAssertNotEqual(route.actorIDs, ["new-army"]); XCTAssertNotEqual(route.relationID, "new-action")
        XCTAssertEqual(book.relations.count, 0); XCTAssertEqual(book.entities.count, 7)
    }
    func testExistingMetadataCanAddMissingSpatialOnlyWithReviewAndConflictsPreserveOriginal() throws {
        var book = try fixture(); let spatial = book.temporalKnowledge!.relationMetadata[0].spatial!; book.temporalKnowledge!.relationMetadata[0].spatial = nil
        var value = book.temporalKnowledge!.relationMetadata[0]; value.spatial = spatial
        let prepared = try prepare(.init(relationMetadata: [value]), in: book)
        XCTAssertTrue(prepared.proposal.requiresConfirmation); XCTAssertEqual(prepared.project.temporalKnowledge?.relationMetadata[0].spatial, spatial)
        XCTAssertNil(book.temporalKnowledge?.relationMetadata[0].spatial)
        value.spatial?.kind = "改成撤退"
        XCTAssertThrowsError(try prepare(.init(relationMetadata: [value]), in: prepared.project))
        value = book.temporalKnowledge!.relationMetadata[0]; value.spatial = spatial; value.validity = day(21)
        XCTAssertThrowsError(try prepare(.init(relationMetadata: [value]), in: book))
    }
    func testProposalCannotReferToActorsOutsideGrantedSource() throws {
        let book = try fixture(); var metadata = book.temporalKnowledge!.relationMetadata[0]; metadata.spatial!.actorIDs = ["future"]
        XCTAssertThrowsError(try prepare(.init(relationMetadata: [metadata]), in: book, units: ["u1"]))
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: book).first?.actorIDs, ["gai"])
    }
    func testDeleteAndRestoreActorCarrySharedRouteDependencies() throws {
        let book = try fixture(), removed = try ManualTrashRuntime.trashing(kind: .entity, id: "cao", in: book)
        try TemporalKnowledgeRuntime.validateStoredState(in: removed)
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: removed).map(\.relationID), ["attack"])
        let item = try XCTUnwrap(removed.manualTrash?.items.last)
        XCTAssertTrue(item.dependencies.contains { $0.collection == .entities && $0.id == "huarong" })
        let restored = try ManualTrashRuntime.restoring(itemID: item.id, expectedItemIDs: [item.id], in: removed)
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: restored).map(\.relationID), ["attack", "withdraw"])
        XCTAssertEqual(restored.units, book.units); XCTAssertEqual(restored.documents, book.documents)
    }
    func testPositionReviewNamesCoordinatesAndChangesWithoutEscapedOriginalPages() throws {
        var book = try fixture(); book.entities[2].latitude = nil; book.entities[2].longitude = nil
        book.entities[2].summary = "已有地点说明"
        book.entities[2].locationNote = "已有位置说明"
        var entity = book.entities[2]; entity.latitude = 29.81; entity.longitude = 113.61; entity.locationNote = "现代参考，非精确古战场"
        entity.summary = "已有地点说明\n\n新增原文背景"
        let value = try prepare(.init(entities: [entity]), in: book)
        let summary = value.proposal.summary.joined(separator: "\n")
        XCTAssertTrue(summary.contains("南岸")); XCTAssertTrue(summary.contains("未记录 → 29.81000, 113.61000"))
        XCTAssertTrue(summary.contains("现代参考，非精确古战场")); XCTAssertFalse(summary.contains("\"unitID\"")); XCTAssertFalse(summary.contains("\"evidence\""))
        XCTAssertTrue(summary.contains("简介补充：新增原文背景")); XCTAssertFalse(summary.contains("已有地点说明"))
        entity.summary = "已有地点说明但带上新信息"
        let extended = try prepare(.init(entities: [entity]), in: book).proposal.summary.joined(separator: "\n")
        XCTAssertTrue(extended.contains("简介补充：已有地点说明但带上新信息"))
        XCTAssertTrue(value.proposal.requiresConfirmation)
    }
    func testRouteReviewShowsNamedDirectionActorsAndSeparateTimeInference() throws {
        var book = try fixture(); let metadata = book.temporalKnowledge!.relationMetadata.removeLast()
        let value = try prepare(.init(relationMetadata: [metadata]), in: book)
        let summary = value.proposal.summary.joined(separator: "\n")
        XCTAssertTrue(summary.contains("乌林 → 华容 → 江陵")); XCTAssertTrue(summary.contains("曹操"))
        XCTAssertTrue(summary.contains("时间为推算")); XCTAssertTrue(summary.contains("行动依据：原文明说"))
        XCTAssertFalse(summary.contains("sourceAnchorIDs"))
    }
    func testPendingReviewStopsFurtherToolsAndRequestsWithoutClaimingSaved() async throws {
        let book = try fixture(); var requests = 0; let proposals = BattleProposalCounter()
        let access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in
            await proposals.increment()
            return Data(#"{"ok":false,"status":"needs_confirmation","applied":false,"proposalID":"review-one"}"#.utf8)
        })
        let result = try await ReadingAnswerEngine.run(question: "把行动放到地图上", project: book, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000),
            documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 128_000, remainingRequests: 20, proposalAccess: access, preferences: .init(interaction: .functional)) { _, _, _, _ in
                requests += 1
                return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                    .init(id: "proposal", type: "function", function: .init(name: "knowledge_changes_propose", arguments: #"{"batch":{"knowledge":{}}}"#)),
                    .init(id: "later", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u1"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
            }
        let preparedCount = await proposals.value
        XCTAssertEqual(requests, 1); XCTAssertEqual(preparedCount, 1); XCTAssertTrue(result.diagnostics.awaitingReview)
        XCTAssertEqual(result.diagnostics.toolCalls, 1); XCTAssertTrue(result.message.content.contains("尚未继续"))
        XCTAssertFalse(result.message.content.contains("已经保存")); XCTAssertTrue(result.message.evidence.isEmpty)
    }
    func testSuccessfulProposalDoesNotPauseTheModelLoop() async throws {
        let book = try fixture(); var requests = 0
        let access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in Data(#"{"ok":true,"status":"success","applied":true}"#.utf8) })
        let result = try await ReadingAnswerEngine.run(question: "整理行动", project: book, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000),
            documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 128_000, remainingRequests: 20, proposalAccess: access, preferences: .init(interaction: .functional)) { _, _, _, _ in
                requests += 1
                if requests == 1 { return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: "proposal", type: "function", function: .init(name: "knowledge_changes_propose", arguments: #"{"batch":{"knowledge":{}}}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20) }
                return .init(message: .init(role: "assistant", content: "整理已保存。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        XCTAssertEqual(requests, 2); XCTAssertFalse(result.diagnostics.awaitingReview)
    }
    func testUndeclaredClientEventIsNotMisreportedAsOutOfScope() throws {
        let book = try fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        let access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in Data() })
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, proposalAccess: access)
        let batch = ControlledChangeBatch(knowledge: .init(events: [.init(id: "client-event", name: "火攻", evidence: [.init(unitID: "u1", quote: book.units[0].text)])]))
        do { try session.validateProposal(name: "knowledge_changes_propose", data: JSONSerialization.data(withJSONObject: ["batch": JSONSerialization.jsonObject(with: encoded(batch))])); XCTFail("未声明的ID不能写入") }
        catch { XCTAssertTrue(error.localizedDescription.contains("newEventIDs")); XCTAssertFalse(error.localizedDescription.contains("先切换范围")) }
    }
    func testDateDragSnapsToRealMilestonesAcrossMonthGaps() throws {
        let axis = TemporalAxis("calendar-day:gregorian")
        let dates = [TemporalExtent(sourceText: "一月末", calendar: "gregorian", start: .init(year: 208, month: 1, day: 31), precision: .day, uncertainty: .exact),
                     .init(sourceText: "二月初", calendar: "gregorian", start: .init(year: 208, month: 2, day: 2), precision: .day, uncertainty: .exact)]
        let values = try dates.map { try XCTUnwrap(axis.value($0)) }
        let snapped = axis.snapped((values[0]+values[1])/2, among: dates)
        XCTAssertTrue(values.contains(snapped)); XCTAssertNotNil(axis.point(snapped))
        XCTAssertEqual(axis.parse("208/2/1"), axis.value(.init(sourceText: "日期", calendar: "gregorian", start: .init(year: 208, month: 2, day: 1), precision: .day, uncertainty: .exact)))
    }
    func testStoredActionsSurviveExportImportAndControlledUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BattleMap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var book = try fixture(); let metadata = book.temporalKnowledge!.relationMetadata[0]
        book.temporalKnowledge!.relationMetadata.removeFirst()
        let source = root.appendingPathComponent("book.txt"); try Data(book.units.map(\.text).joined().utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        let fresh = try await repository.create(book, sourceURL: source)
        let authority = try await repository.issueChangeGrant(bookID: fresh.id, permissions: [.knowledge], allowedUnitIDs: ["u1", "u2"], requiresReceipts: false, reason: "补行动")
        let proposal = try await repository.prepareChanges(.init(knowledge: .init(relationMetadata: [metadata])), grant: authority)
        let saved = try await repository.commitChanges(proposalID: proposal.id, grant: authority)
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: saved.project).count, 2)
        let export = root.appendingPathComponent("copy.readingbook"); try await repository.exportProject(saved.project, to: export)
        let imported = try await repository.importProject(from: export)
        XCTAssertNotEqual(imported.id, saved.project.id)
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: imported).map(\.placeIDs), try SpatialKnowledgeRuntime.routes(in: saved.project).map(\.placeIDs))
        let undone = try await repository.undoChanges(bookID: fresh.id, operationID: proposal.operationID)
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: undone.project).map(\.relationID), ["withdraw"])
        XCTAssertEqual(undone.project.units, fresh.units); XCTAssertEqual(undone.project.relations, fresh.relations)
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: imported).count, 2, "撤销原书不改导入副本")
    }
    func testArrowGeometryTracksDirectionIncludingDatelineAndDuplicateEndpoints() throws {
        let east = SpatialRouteGeometry.arrowhead([.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 1)])
        XCTAssertEqual(east.count, 3); XCTAssertGreaterThan(east[0].longitude, east[1].longitude); XCTAssertGreaterThan(east[0].longitude, east[2].longitude)
        let west = SpatialRouteGeometry.arrowhead([.init(latitude: 0, longitude: 1), .init(latitude: 0, longitude: 0)])
        XCTAssertLessThan(west[0].longitude, west[1].longitude)
        let crossing = SpatialRouteGeometry.arrowhead([.init(latitude: 10, longitude: 179.9), .init(latitude: 10, longitude: -179.9)])
        XCTAssertEqual(crossing.count, 3); XCTAssertTrue(crossing.allSatisfy { $0.longitude.isFinite && (-180...180).contains($0.longitude) })
        XCTAssertTrue(SpatialRouteGeometry.arrowhead([.init(latitude: 1, longitude: 1), .init(latitude: 1, longitude: 1)]).isEmpty)
        XCTAssertEqual(SpatialRouteGeometry.arrowhead([.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 1), .init(latitude: 0, longitude: 1)]), east)
    }
    func testCompositionProjectsSameRoutesAndSortsMonthDayWithinOneYear() throws {
        let book = try fixture(), source = CompositionDataSource(id: "events", collection: .events, scope: .book, sort: .time)
        let definition = CompositionDefinition(sources: [source], parts: [.init(id: "map", primitive: .map, sourceID: "events"), .init(id: "axis", primitive: .timeline, sourceID: "events")],
            layout: [.init(id: "m", kind: .part, partID: "map"), .init(id: "t", kind: .part, partID: "axis"), .init(id: "root", kind: .column, children: ["m", "t"])], rootID: "root")
        let full = try CompositionRuntime.project(definition, in: book)
        XCTAssertEqual(full["events"]?.items.map(\.title), ["火攻", "退向江陵"], "Actual: \(full["events"]?.items.map { ($0.title, $0.extent?.start?.day) } ?? [])")
        XCTAssertEqual(full["events"]?.mapRoutes.map(\.relationID), ["attack", "withdraw"])
        let window = TemporalQueryWindow.date(from: .init(year: 12, month: 11, day: 20), to: .init(year: 12, month: 11, day: 20), calendar: "建安")
        let filtered = try CompositionRuntime.project(definition, in: book, windows: [source.timeGroup: window])
        XCTAssertEqual(filtered["events"]?.mapRoutes.map(\.relationID), ["attack"])
        XCTAssertEqual(book.temporalKnowledge?.relationMetadata.count, 2, "组合视图不创建私有副本")
    }
}
