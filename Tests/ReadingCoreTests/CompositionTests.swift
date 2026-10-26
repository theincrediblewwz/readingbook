import Foundation
import XCTest
@testable import ReadingCore

final class CompositionTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: "208年，神秘人到江陵，刘备参加南征。"),
                     SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "209年，神秘人其实是曹操，曹操返回许都。")]
        var book = BookProject(title: "组合读本", originalName: "history.txt", sourceHash: try BookImporter.sha256(Data(units.map(\.text).joined().utf8)), units: units)
        PluginEngine.seed(&book)
        let first = Evidence(unitID: "u1", quote: units[0].text), second = Evidence(unitID: "u2", quote: units[1].text)
        book.entities = [KnowledgeEntity(id: "cao", typeID: "person", name: "曹操", summary: "结局信息", properties: ["身份": "后文揭示"], aliases: ["神秘人"], evidence: [first, second]),
            KnowledgeEntity(id: "liu", typeID: "person", name: "刘备", evidence: [first]),
            KnowledgeEntity(id: "jiangling", typeID: "place", name: "江陵", latitude: 30.3, longitude: 112.2, evidence: [first]),
            KnowledgeEntity(id: "xudu", typeID: "place", name: "许都", latitude: 34, longitude: 113.8, evidence: [second])]
        book.events = [KnowledgeEvent(id: "campaign", name: "南征", dateText: "208年", startYear: 208, placeIDs: ["jiangling"], participantIDs: ["cao", "liu"], evidence: [first])]
        book.relations = [KnowledgeRelation(id: "relation", fromID: "cao", toID: "liu", label: "同行", evidence: [first])]
        book.documents = [DocumentRecord(id: "d1", title: "本页笔记", linkedIDs: ["cao"], evidence: [first]),
            DocumentRecord(id: "d2", title: "后页笔记", linkedIDs: ["cao"], evidence: [second]), DocumentRecord(id: "d3", title: "个人笔记")]
        book.nodes = [CanvasNode(id: "node1", targetID: "d1"), CanvasNode(id: "node2", targetID: "d2")]
        book.edges = [CanvasEdge(id: "edge", fromID: "node1", toID: "node2", label: "对比")]
        let anchors = try units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.id, quote: $0.text, in: book) }
        func year(_ value: Int) -> TemporalExtent { TemporalExtent(sourceText: "\(value)年", calendar: "gregorian", start: TemporalDate(year: value), precision: .year, uncertainty: .exact) }
        book.temporalKnowledge = TemporalKnowledgeState(anchors: anchors,
            presences: [EntityPresence(id: "p208", entityID: "cao", placeID: "jiangling", extent: year(208), action: "抵达", sourceAnchorIDs: [anchors[0].id], assertion: .explicit),
                EntityPresence(id: "p209", entityID: "cao", placeID: "xudu", extent: year(209), action: "返回", sourceAnchorIDs: [anchors[1].id], assertion: .explicit)],
            participations: [Participation(id: "part", entityID: "liu", eventID: "campaign", role: "参加", extent: year(208), sourceAnchorIDs: [anchors[0].id], assertion: .explicit)],
            eventMetadata: [EventTemporalMetadata(eventID: "campaign", extent: year(208), sourceAnchorIDs: [anchors[0].id], assertion: .explicit)])
        return book
    }
    private func definition(_ sources: [CompositionDataSource], primitives: [CompositionPrimitive]? = nil) -> CompositionDefinition {
        let parts = sources.enumerated().map { index, source in CompositionPart(id: "p\(index)", primitive: primitives?[index] ?? .objectList,
            sourceID: source.id, selectionGroup: source.selectionGroup, timeGroup: source.timeGroup) }
        var layout = parts.map { CompositionLayoutNode(id: "l." + $0.id, kind: .part, partID: $0.id) }
        if parts.count > 1 { layout.append(CompositionLayoutNode(id: "root", kind: .column, children: layout.map(\.id))) }
        return CompositionDefinition(sources: sources, parts: parts, layout: layout, rootID: parts.count == 1 ? layout[0].id : "root")
    }

    func testOldViewsRoundTripAndClosedTypedCompositionValidation() throws {
        let book = try fixture()
        let old = try JSONDecoder().decode(ViewDefinition.self, from: Data(#"{"id":"old","title":"旧组件","kind":"map"}"#.utf8))
        XCTAssertNil(old.composition)
        var value = definition([CompositionDataSource(id: "objects", collection: .objects)])
        value.layout[0].dock = .bottomTrailing
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(CompositionDefinition.self, from: data), value)
        XCTAssertNoThrow(try CompositionRuntime.validate(value, in: book))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); raw["script"] = "readFile('/secret')"
        XCTAssertThrowsError(try JSONDecoder().decode(CompositionDefinition.self, from: JSONSerialization.data(withJSONObject: raw)))
        value.version = 9; XCTAssertThrowsError(try CompositionRuntime.validate(value, in: book))
        value.version = 1; value.layout.append(CompositionLayoutNode(id: "orphan", kind: .part, partID: value.parts[0].id))
        XCTAssertThrowsError(try CompositionRuntime.validate(value, in: book))
        value = definition([CompositionDataSource(id: "objects", collection: .objects)])
        value.layout[0].children = [value.rootID]; XCTAssertThrowsError(try CompositionRuntime.validate(value, in: book))
        value = definition([CompositionDataSource(id: "objects", collection: .objects)])
        value.sources[0].filters = [CompositionFilter(field: "properties.unregistered", operation: .exists)]
        XCTAssertThrowsError(try CompositionRuntime.validate(value, in: book))
        value.sources[0].filters = []; value.parts[0].timeGroup = "other"
        XCTAssertThrowsError(try CompositionRuntime.validate(value, in: book))
    }

    func testCurrentScopeUsesExactSelectionAndIdentityWithoutFutureSummary() throws {
        let book = try fixture()
        let value = definition([CompositionDataSource(id: "all", collection: .objects), CompositionDataSource(id: "quotes", collection: .evidence)], primitives: [.objectList, .sourceExcerpt])
        let context = ReadingContext(sourceHash: book.sourceHash, unitID: "u1", page: 1)
        let projection = try CompositionRuntime.project(value, in: book, context: context)
        let person = try XCTUnwrap(projection["all"]?.items.first { $0.id == "cao" })
        XCTAssertEqual(person.title, "神秘人"); XCTAssertEqual(person.summary, ""); XCTAssertTrue(person.fields.isEmpty)
        XCTAssertFalse(projection["all"]!.items.contains { $0.id == "xudu" })
        let selection = ReadingContext(sourceHash: book.sourceHash, unitID: "u1", selectedText: "刘备参加南征", page: 1)
        let selected = try CompositionRuntime.project(value, in: book, context: selection)
        XCTAssertEqual(selected["quotes"]?.items.first?.evidence.first?.quote, "刘备参加南征")
        XCTAssertTrue(selected["all"]!.items.isEmpty, "A whole-page evidence quote is not admitted by a smaller selected substring.")
        let noContext = try CompositionRuntime.project(value, in: book)
        XCTAssertTrue(noContext["all"]!.items.isEmpty); XCTAssertFalse(noContext["all"]!.diagnostics.isEmpty)
        let bookScope = definition([CompositionDataSource(id: "book", collection: .objects, scope: .book)])
        let bounded = try CompositionRuntime.project(bookScope, in: book, selections: ["main": ["xudu"]], boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]))
        XCTAssertFalse(bounded["book"]!.items.contains { $0.id == "xudu" })
        XCTAssertEqual(bounded["book"]!.items.first { $0.id == "cao" }?.title, "神秘人")
    }

    func testBookComponentCannotTreatCroppedEarlyPageAsFullIdentityPermission() throws {
        var book = try fixture()
        // A stored canonical identity can be backed by only the earlier alias;
        // the later reveal need not have been attached as a second evidence row.
        book.entities[0].evidence = [Evidence(unitID: "u1", quote: "神秘人")]
        book.events[0].name = "曹操称王"; book.events[0].summary = "曹操后来称王。"
        book.events[0].dateText = "209年"; book.events[0].startYear = 209
        let value = definition([CompositionDataSource(id: "objects", collection: .objects, scope: .book)])
        let result = try CompositionRuntime.project(value, in: book, boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]))["objects"]!
        let person = try XCTUnwrap(result.items.first { $0.id == "cao" })
        XCTAssertEqual(person.title, "神秘人"); XCTAssertTrue(person.summary.isEmpty); XCTAssertTrue(person.fields.isEmpty)
        let event = try XCTUnwrap(result.items.first { $0.id == "campaign" })
        XCTAssertEqual(event.title, "本段关联事件"); XCTAssertTrue(event.summary.isEmpty)
        XCTAssertFalse(event.fields.values.contains(where: { $0.contains("209") || $0.contains("曹操") }))
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        let ordinary = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        XCTAssertEqual(ordinary.scopedKnowledgeProject()?.entities.first { $0.id == "cao" }?.name, "神秘人")
        let explicitlyAuthorized = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, allowsFullIdentity: true)
        XCTAssertEqual(explicitlyAuthorized.scopedKnowledgeProject()?.entities.first { $0.id == "cao" }?.name, "曹操",
            "仅宿主明确授予完整原书身份可读时保留原身份，不能从组件book字样推断授权。")
    }

    func testInlinePagePolicyKeepsLocatorAndExplicitSelectionBoundarySeparate() throws {
        var book = try fixture()
        book.units[1].page = 1 // A source whitelist still wins over page membership.
        let value = definition([CompositionDataSource(id: "objects", collection: .objects)])
        let context = ReadingContext(sourceHash: book.sourceHash, unitID: "u1", selectedText: "刘备", objectID: "liu", page: 1)
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: ["u1"])
        let automatic = try CompositionRuntime.project(value, in: book, context: context, boundary: boundary)
        XCTAssertTrue(automatic["objects"]!.items.isEmpty)
        let page = try CompositionRuntime.project(value, in: book, context: context, boundary: boundary, currentScope: .page)
        XCTAssertTrue(page["objects"]!.items.contains { $0.id == "liu" })
        XCTAssertFalse(page["objects"]!.items.contains { $0.id == "xudu" })
        XCTAssertEqual(page["objects"]!.items.first { $0.id == "cao" }?.title, "神秘人")
        let selected = try CompositionRuntime.project(value, in: book, context: context, boundary: boundary, currentScope: .selection)
        XCTAssertTrue(selected["objects"]!.items.isEmpty)
    }

    func testPreparedInputIsBoundToCapturedProjectAndOnlyMapSourcesComputePoints() throws {
        var book = try fixture()
        let value = definition([CompositionDataSource(id: "objects", collection: .objects, scope: .book)])
        let prepared = try CompositionRuntime.prepare(value, in: book)
        book.entities.removeAll(); book.events.removeAll()
        let result = try CompositionRuntime.project(prepared)["objects"]!
        XCTAssertTrue(result.items.contains { $0.id == "jiangling" })
        XCTAssertTrue(result.mapPoints.isEmpty)
        XCTAssertFalse(result.partial)
        let map = definition([CompositionDataSource(id: "objects", collection: .objects, scope: .book)], primitives: [.map])
        let mapped = try CompositionRuntime.project(map, in: fixture())["objects"]!
        XCTAssertFalse(mapped.mapPoints.isEmpty)
    }

    func testWindowFiltersEventsAndRelationsWhileCursorAndMapModeStayDistinct() throws {
        var book = try fixture()
        let first = book.entities[1].evidence[0], second = book.entities[3].evidence[0]
        let anchors = book.temporalKnowledge!.anchors
        func year(_ year: Int) -> TemporalExtent {
            TemporalExtent(sourceText: "\(year)年", calendar: "gregorian", start: TemporalDate(year: year), precision: .year, uncertainty: .exact)
        }
        book.events.append(KnowledgeEvent(id: "return", name: "返回许都", dateText: "209年", startYear: 209,
            placeIDs: ["xudu"], participantIDs: ["cao"], evidence: [second]))
        book.events.append(KnowledgeEvent(id: "undated", name: "另一次行动", participantIDs: ["cao"], evidence: [first]))
        book.temporalKnowledge!.eventMetadata.append(EventTemporalMetadata(eventID: "return", extent: year(209),
            sourceAnchorIDs: [anchors[1].id], assertion: .explicit))
        book.temporalKnowledge!.relationMetadata = [RelationTemporalMetadata(id: "early-relation", relationID: "relation", validity: year(208),
            sourceAnchorIDs: [anchors[0].id], assertion: .explicit)]
        book.temporalKnowledge!.presences.append(EntityPresence(id: "inferred-location", entityID: "cao", placeID: "jiangling", extent: year(209),
            action: "推测到访", sourceAnchorIDs: [anchors[0].id], assertion: .inferred, explanation: "仅为推测"))
        let value = definition([
            CompositionDataSource(id: "people", collection: .objects, scope: .book, typeIDs: ["person"], relation: .selected),
            CompositionDataSource(id: "events", collection: .events, scope: .book, relation: .events),
            CompositionDataSource(id: "graph", collection: .relations, scope: .book, relation: .neighbors)], primitives: [.map, .timeline, .relations])
        let selection: [String: Set<String>] = ["main": ["cao"]]
        let cursor: [String: TemporalQueryPoint] = ["main": .date(TemporalDate(year: 209), calendar: "gregorian")]
        let window: [String: TemporalQueryWindow] = ["main": .date(from: TemporalDate(year: 208), to: TemporalDate(year: 209), calendar: "gregorian")]
        let prepared = try CompositionRuntime.prepare(value, in: book)
        let baseline = try CompositionRuntime.project(prepared, selections: selection)
        let instant = try CompositionRuntime.project(prepared, selections: selection, times: cursor, windows: window)
        XCTAssertEqual(Set(instant["events"]!.items.map(\.id)), ["campaign", "return", "undated"])
        XCTAssertEqual(instant["events"]!.items.first { $0.id == "undated" }?.fields["temporalMatch"], "unknown")
        XCTAssertFalse(instant["events"]!.diagnostics.isEmpty)
        XCTAssertEqual(instant["graph"]!.edges.map(\.id), ["relation"], "An in-window relation must not disappear solely because the cursor is later.")
        XCTAssertTrue(instant["people"]!.items.first!.fields["此时行动"]!.contains("返回"))
        XCTAssertEqual(instant["people"]!.mapPoints.filter { $0.kind == "presence" }.map(\.latitude), [34])
        let footprints = try CompositionRuntime.project(prepared, selections: selection, times: cursor, windows: window, mapModes: ["main": .windowFootprints])
        XCTAssertEqual(Set(footprints["people"]!.mapPoints.map(\.id)), ["presence.p208", "presence.p209"])
        let late = try CompositionRuntime.project(prepared, selections: selection, times: cursor,
            windows: ["main": .date(from: TemporalDate(year: 209), to: TemporalDate(year: 209), calendar: "gregorian")])
        XCTAssertFalse(late["events"]!.items.contains { $0.id == "campaign" })
        XCTAssertTrue(late["graph"]!.edges.isEmpty)
        XCTAssertEqual(baseline["events"]!.items.count, 3, "Filtering must leave the prepared full-period baseline intact.")
        let bounded = try CompositionRuntime.project(value, in: book, selections: selection, times: cursor,
            boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]), windows: window, mapModes: ["main": .windowFootprints])
        XCTAssertFalse(bounded["events"]!.items.contains { $0.id == "return" })
        XCTAssertEqual(bounded["people"]!.mapPoints.map(\.id), ["presence.p208"])
    }

    func testSharedSelectionTimeAndNoInventedParticipantLocations() throws {
        let book = try fixture()
        let value = definition([
            CompositionDataSource(id: "people", collection: .objects, scope: .book, typeIDs: ["person"], relation: .selected),
            CompositionDataSource(id: "events", collection: .events, scope: .book, relation: .events),
            CompositionDataSource(id: "graph", collection: .relations, scope: .book, relation: .neighbors)], primitives: [.map, .timeline, .relations])
        let early = try CompositionRuntime.project(value, in: book, selections: ["main": ["cao"]], times: ["main": .date(TemporalDate(year: 208), calendar: "gregorian")])
        XCTAssertEqual(early["people"]?.mapPoints.filter { $0.kind == "presence" }.map(\.latitude), [30.3])
        XCTAssertEqual(early["events"]?.items.map(\.id), ["campaign"])
        XCTAssertEqual(early["graph"]?.edges.first?.fromID, "cao")
        let later = try CompositionRuntime.project(value, in: book, selections: ["main": ["cao"]], times: ["main": .date(TemporalDate(year: 209), calendar: "gregorian")])
        XCTAssertEqual(later["people"]?.mapPoints.filter { $0.kind == "presence" }.map(\.latitude), [34])
        XCTAssertTrue(later["people"]!.items.first!.fields["此时行动"]!.contains("返回"))
        XCTAssertTrue(later["events"]!.items.isEmpty)
        let participant = try CompositionRuntime.project(value, in: book, selections: ["main": ["liu"]], times: ["main": .date(TemporalDate(year: 208), calendar: "gregorian")])
        XCTAssertTrue(participant["people"]!.mapPoints.isEmpty, "A participant and an event place cannot fabricate a personal footprint.")
        let forged = try CompositionRuntime.project(value, in: book, selections: ["main": ["xudu"]], boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]))
        XCTAssertTrue(forged["people"]!.items.isEmpty); XCTAssertTrue(forged["events"]!.items.isEmpty)
        let noEdges = definition([CompositionDataSource(id: "graph", collection: .relations, scope: .book,
            filters: [CompositionFilter(field: "label", operation: .equals, value: "敌对")])], primitives: [.relations])
        XCTAssertTrue(try CompositionRuntime.project(noEdges, in: book)["graph"]!.items.isEmpty)
    }

    func testDocumentProjectionMapsPhysicalEdgesAndDoesNotReadMarkdown() throws {
        let book = try fixture()
        let value = definition([CompositionDataSource(id: "docs", collection: .documents, scope: .book)], primitives: [.documentGraph])
        let all = try CompositionRuntime.project(value, in: book)["docs"]!
        XCTAssertEqual(Set(all.items.compactMap(\.documentID)), ["d1", "d2", "d3"])
        XCTAssertEqual(all.edges.first?.fromID, "d1"); XCTAssertEqual(all.edges.first?.toID, "d2")
        XCTAssertTrue(all.items.allSatisfy { $0.summary.isEmpty && $0.fields["markdown"] == nil })
        let bounded = try CompositionRuntime.project(value, in: book, boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]))["docs"]!
        XCTAssertEqual(bounded.items.map(\.id), ["d1"]); XCTAssertTrue(bounded.edges.isEmpty)
        let current = definition([CompositionDataSource(id: "docs", collection: .documents)], primitives: [.markdown])
        let local = try CompositionRuntime.project(current, in: book, context: ReadingContext(unitID: "u1", page: 1))["docs"]!
        XCTAssertEqual(local.items.map(\.id), ["d1"])
        var mountedBook = book
        var standalone = CanvasNode(id: "standalone", targetID: "standalone"); standalone.isStandalone = true; standalone.documentIDs = ["d1", "d3"]
        var entity = CanvasNode(id: "entityNode", targetID: "cao"); entity.documentIDs = ["d2"]
        mountedBook.nodes = [standalone, entity]; mountedBook.edges = [CanvasEdge(id: "mounted", fromID: standalone.id, toID: entity.id)]
        let mounts = try CompositionRuntime.project(value, in: mountedBook)["docs"]!
        XCTAssertEqual(Set(mounts.edges.map(\.fromID)), ["d1", "d3"]); XCTAssertEqual(Set(mounts.edges.map(\.toID)), ["d2"])
        XCTAssertTrue(mounts.edges.allSatisfy { $0.kind == "layout" }); XCTAssertFalse(mounts.diagnostics.isEmpty)
        XCTAssertTrue(try CompositionRuntime.project(value, in: mountedBook, boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]))["docs"]!.edges.isEmpty)
    }

    func testConfigureToolsKeepDistinctViewsAndRejectInvalidBatchAtomically() throws {
        var book = try fixture()
        let value = definition([CompositionDataSource(id: "people", collection: .objects, typeIDs: ["person"])])
        let composition = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        let views: [[String: Any]] = ["one", "two"].map { ["id": $0, "title": $0, "kind": "knowledge", "rendererID": "reading.composition", "composition": composition] }
        _ = try PluginEngine.apply(name: "views_configure", arguments: JSONSerialization.data(withJSONObject: ["views": views]), to: &book, allowedUnitIDs: [])
        XCTAssertEqual(book.views.filter { $0.rendererID == "reading.composition" }.count, 2)
        XCTAssertEqual(book.views.first { $0.id == "one" }?.composition, value)
        XCTAssertNoThrow(try PluginEngine.validateSchemeConfiguration(BookSchemeConfiguration(project: book), in: book))
        let before = book.views
        var bad = views[0]; bad["id"] = "bad"; bad["composition"] = ["version": 1, "sources": [], "parts": [], "layout": [], "rootID": "missing"]
        XCTAssertThrowsError(try PluginEngine.apply(name: "views_configure", arguments: JSONSerialization.data(withJSONObject: ["views": [views[1], bad]]), to: &book, allowedUnitIDs: []))
        XCTAssertEqual(book.views, before)
    }

    func testMapProjectionBoundIsHonestAndDeterministic() throws {
        var book = try fixture()
        let anchor = book.temporalKnowledge!.anchors[0]
        book.temporalKnowledge!.presences = (0..<405).map { index in
            EntityPresence(id: "many.\(index)", entityID: "cao", placeID: "jiangling", action: "记录\(index)", sourceAnchorIDs: [anchor.id], assertion: .explicit)
        }
        let value = definition([CompositionDataSource(id: "people", collection: .objects, scope: .book, typeIDs: ["person"], relation: .selected)], primitives: [.map])
        let result = try CompositionRuntime.project(value, in: book, selections: ["main": ["cao"]])["people"]!
        XCTAssertEqual(result.mapPoints.count, 400); XCTAssertTrue(result.partial)
        XCTAssertFalse(result.diagnostics.isEmpty)
        XCTAssertEqual(result.mapPoints.map(\.id), try CompositionRuntime.project(value, in: book, selections: ["main": ["cao"]])["people"]!.mapPoints.map(\.id))
    }
}
