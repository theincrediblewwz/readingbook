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

    private func traversalFixture() throws -> BookProject {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "前文", page: 1, text: "概念甲、概念乙、概念丙、概念丁、概念庚。前提与结论。208年旧事，209年关系变更。"),
            SourceUnit(id: "u2", order: 1, chapter: "后文", page: 2, text: "后文概念戊带来新增关联。")]
        let hash = try BookImporter.sha256(Data(units.map(\.text).joined().utf8))
        var book = BookProject(title: "关系与对照", originalName: "arguments.txt", sourceHash: hash, units: units)
        PluginEngine.seed(&book)
        book.types += [EntityType(id: "proof-concept", name: "概念", fields: [TypeField(key: "definition", label: "定义"), TypeField(key: "condition", label: "条件")]),
            EntityType(id: "proof-claim", name: "论点", fields: [TypeField(key: "reason", label: "理由")])]
        let first = Evidence(unitID: "u1", quote: units[0].text), second = Evidence(unitID: "u2", quote: units[1].text)
        book.entities = [KnowledgeEntity(id: "a", typeID: "proof-concept", name: "概念甲", properties: ["definition": "前提", "condition": "结论"], evidence: [first]),
            KnowledgeEntity(id: "b", typeID: "proof-concept", name: "概念乙", properties: ["definition": "结论"], evidence: [first]),
            KnowledgeEntity(id: "c", typeID: "proof-concept", name: "概念丙", evidence: [first]),
            KnowledgeEntity(id: "d", typeID: "proof-claim", name: "概念丁", properties: ["reason": "前提"], evidence: [first]),
            KnowledgeEntity(id: "e", typeID: "proof-concept", name: "后文概念戊", properties: ["definition": "新增关联"], evidence: [second]),
            KnowledgeEntity(id: "g", typeID: "proof-concept", name: "概念庚", evidence: [first])]
        func proof(_ quote: String, future: Bool = false) -> [Evidence] { [Evidence(unitID: future ? "u2" : "u1", quote: quote)] }
        book.relations = [KnowledgeRelation(id: "ab", fromID: "a", toID: "b", label: "依赖", evidence: proof("前提")),
            KnowledgeRelation(id: "ab2", fromID: "a", toID: "b", label: "依赖", evidence: proof("结论")),
            KnowledgeRelation(id: "bc", fromID: "b", toID: "c", label: "依赖", evidence: proof("概念乙")),
            KnowledgeRelation(id: "ca", fromID: "c", toID: "a", label: "回指", evidence: proof("概念丙")),
            KnowledgeRelation(id: "self", fromID: "b", toID: "b", label: "依赖", evidence: proof("前提")),
            KnowledgeRelation(id: "ba", fromID: "b", toID: "a", label: "反对", evidence: proof("结论")),
            KnowledgeRelation(id: "ad", fromID: "a", toID: "d", label: "解释", evidence: proof("概念甲")),
            KnowledgeRelation(id: "dc", fromID: "d", toID: "c", label: "解释", evidence: proof("概念丁")),
            KnowledgeRelation(id: "future", fromID: "a", toID: "e", label: "依赖", evidence: proof("新增关联", future: true)),
            KnowledgeRelation(id: "futureBridge", fromID: "e", toID: "g", label: "依赖", evidence: proof("新增关联", future: true)),
            KnowledgeRelation(id: "eventIn", fromID: "a", toID: "ev", label: "事件链", evidence: proof("旧事")),
            KnowledgeRelation(id: "eventOut", fromID: "ev", toID: "c", label: "事件链", evidence: proof("旧事")),
            KnowledgeRelation(id: "timed", fromID: "a", toID: "g", label: "时限", evidence: proof("关系变更"))]
        book.events = [KnowledgeEvent(id: "ev", name: "旧事", dateText: "208年", startYear: 208, evidence: [first])]
        let anchors = try units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: hash, unitID: $0.id, quote: $0.text, in: book) }
        func extent(_ year: Int) -> TemporalExtent { TemporalExtent(sourceText: "\(year)年", calendar: "gregorian", start: TemporalDate(year: year), precision: .year, uncertainty: .exact) }
        book.temporalKnowledge = TemporalKnowledgeState(anchors: anchors,
            eventMetadata: [EventTemporalMetadata(eventID: "ev", extent: extent(208), sourceAnchorIDs: [anchors[0].id], assertion: .explicit)],
            relationMetadata: [RelationTemporalMetadata(id: "timed-209", relationID: "timed", validity: extent(209), sourceAnchorIDs: [anchors[0].id], assertion: .explicit)])
        return book
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

    func testSharedTemporalQueriesPreserveScopeTimeAndOrderedEndpointEvidence() throws {
        var book = try fixture()
        let first = book.entities[1].evidence[0], second = book.entities[3].evidence[0]
        let person = Evidence(unitID: "u1", quote: "神秘人"), participant = Evidence(unitID: "u1", quote: "刘备")
        let place = Evidence(unitID: "u1", quote: "江陵"), yearQuote = Evidence(unitID: "u1", quote: "208年")
        book.relations = [
            KnowledgeRelation(id: "support", fromID: "cao", toID: "liu", label: "支持", evidence: [person, participant, person]),
            KnowledgeRelation(id: "against", fromID: "cao", toID: "jiangling", label: "反对", evidence: [place, participant]),
            KnowledgeRelation(id: "self", fromID: "cao", toID: "cao", label: "支持", evidence: [yearQuote, person])]
        let anchor = book.temporalKnowledge!.anchors[0]
        let extent = TemporalExtent(sourceText: "208年", calendar: "gregorian", start: TemporalDate(year: 208), precision: .year, uncertainty: .exact)
        book.temporalKnowledge!.relationMetadata = ["one", "two"].map {
            RelationTemporalMetadata(id: $0, relationID: "support", validity: extent, sourceAnchorIDs: [anchor.id], assertion: .explicit)
        }
        let sources = [
            CompositionDataSource(id: "all", collection: .relations, scope: .book, timeGroup: "wide", relation: .neighbors),
            CompositionDataSource(id: "supports", collection: .relations, scope: .book, timeGroup: "alsoWide", relation: .neighbors,
                filters: [CompositionFilter(field: "label", operation: .equals, value: "支持")]),
            CompositionDataSource(id: "local", collection: .relations, timeGroup: "wide", relation: .neighbors),
            CompositionDataSource(id: "pointEvents", collection: .events, scope: .book, timeGroup: "point", relation: .events),
            CompositionDataSource(id: "windowEvents", collection: .events, scope: .book, timeGroup: "wide", relation: .events),
            CompositionDataSource(id: "map", collection: .objects, scope: .book, typeIDs: ["person"], timeGroup: "wide", relation: .selected)]
        let primitives: [CompositionPrimitive] = [.relations, .relations, .relations, .timeline, .timeline, .map]
        let context = ReadingContext(sourceHash: book.sourceHash, unitID: "u1", page: 1)
        let selection: [String: Set<String>] = ["main": ["cao"]]
        let times: [String: TemporalQueryPoint] = ["wide": .date(TemporalDate(year: 209), calendar: "gregorian"),
            "alsoWide": .date(TemporalDate(year: 208), calendar: "gregorian"), "point": .date(TemporalDate(year: 209), calendar: "gregorian")]
        let window = TemporalQueryWindow.date(from: TemporalDate(year: 208), to: TemporalDate(year: 209), calendar: "gregorian")
        let windows = ["wide": window, "alsoWide": window]
        let combined = try CompositionRuntime.project(definition(sources, primitives: primitives), in: book, context: context,
            selections: selection, times: times, windows: windows)
        for (index, source) in sources.enumerated() {
            let single = try CompositionRuntime.project(definition([source], primitives: [primitives[index]]), in: book, context: context,
                selections: selection, times: times, windows: windows)[source.id]!
            let shared = combined[source.id]!
            XCTAssertEqual(shared.items, single.items); XCTAssertEqual(shared.edges, single.edges)
            XCTAssertEqual(shared.mapPoints, single.mapPoints); XCTAssertEqual(shared.total, single.total)
            XCTAssertEqual(shared.partial, single.partial); XCTAssertEqual(shared.diagnostics, single.diagnostics)
        }
        XCTAssertEqual(combined["all"]!.items.first { $0.id == "cao" }?.evidence, [first, second, person, participant, place, yearQuote])
        XCTAssertEqual(combined["supports"]!.items.first { $0.id == "cao" }?.evidence, [first, second, person, participant, yearQuote])
        XCTAssertEqual(combined["supports"]!.edges.map(\.id), ["support", "self"])
        XCTAssertEqual(combined["local"]!.items.first { $0.id == "cao" }?.title, "神秘人")
        XCTAssertTrue(combined["pointEvents"]!.items.isEmpty)
        XCTAssertEqual(combined["windowEvents"]!.items.map(\.id), ["campaign"])
        XCTAssertTrue(combined["all"]!.items.first { $0.id == "cao" }!.fields["此时行动"]!.contains("返回"))
        XCTAssertTrue(combined["supports"]!.items.first { $0.id == "cao" }!.fields["此时行动"]!.contains("抵达"))
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

    func testTraversalDirectionsCyclesParallelEdgesAndBudgets() throws {
        let book = try traversalFixture(), selected: [String: Set<String>] = ["main": ["a"]]
        var source = CompositionDataSource(id: "graph", collection: .relations, scope: .book, relation: .neighbors,
            traversal: CompositionTraversal(labels: ["依赖"], direction: .outgoing, depth: 1))
        func project(_ source: CompositionDataSource) throws -> CompositionProjection {
            try CompositionRuntime.project(definition([source], primitives: [.relations]), in: book, selections: selected)["graph"]!
        }
        let first = try project(source)
        XCTAssertEqual(Set(first.items.map(\.id)), ["a", "b", "e"])
        XCTAssertEqual(first.edges.filter { $0.fromID == "a" && $0.toID == "b" }.map(\.id), ["ab", "ab2"])
        XCTAssertEqual(first.edges.first { $0.id == "ab" }?.evidence.first?.quote, "前提")
        XCTAssertEqual(first.edges.first { $0.id == "ab2" }?.evidence.first?.quote, "结论")
        source.traversal!.depth = 2
        let second = try project(source)
        XCTAssertTrue(second.items.contains { $0.id == "c" }); XCTAssertTrue(second.items.contains { $0.id == "g" })
        XCTAssertEqual(second.edges.filter { $0.id == "self" }.count, 1)
        source.traversal = CompositionTraversal(labels: ["反对"], direction: .incoming)
        let incoming = try project(source)
        XCTAssertEqual(incoming.edges.map(\.id), ["ba"])
        XCTAssertEqual(incoming.edges.first?.fromID, "b"); XCTAssertEqual(incoming.edges.first?.toID, "a")
        source.traversal = CompositionTraversal(direction: .both, depth: 4)
        let cyclic = try project(source)
        XCTAssertEqual(cyclic.items.count, 7); XCTAssertEqual(cyclic.edges.count, book.relations.count); XCTAssertFalse(cyclic.partial)
        source.traversal = CompositionTraversal(labels: ["依赖"], direction: .outgoing, depth: 2, maxNodes: 2)
        let nodeBound = try project(source)
        XCTAssertEqual(Set(nodeBound.items.map(\.id)), ["a", "b"]); XCTAssertTrue(nodeBound.partial)
        source.traversal = CompositionTraversal(labels: ["依赖"], direction: .outgoing, depth: 2, maxEdges: 1)
        let edgeBound = try project(source)
        XCTAssertEqual(edgeBound.edges.map(\.id), ["ab"]); XCTAssertTrue(edgeBound.partial)
        XCTAssertEqual(try project(source).items, edgeBound.items, "Truncation must be deterministic.")
    }

    func testTraversalFiltersTimeAndPermissionBeforeWalkingAndDoesNotInventBridges() throws {
        var book = try traversalFixture()
        let selected: [String: Set<String>] = ["main": ["a"]]
        var source = CompositionDataSource(id: "graph", collection: .relations, scope: .book, typeIDs: ["proof-concept"], relation: .neighbors,
            traversal: CompositionTraversal(labels: ["解释"], direction: .outgoing, depth: 2))
        var value = definition([source], primitives: [.relations])
        let hidden = try CompositionRuntime.project(value, in: book, selections: selected)["graph"]!
        XCTAssertEqual(Set(hidden.items.map(\.id)), ["a", "c"]); XCTAssertTrue(hidden.edges.isEmpty)
        XCTAssertTrue(hidden.partial); XCTAssertTrue(hidden.diagnostics.contains { $0.contains("端点") })
        source.typeIDs = []; source.traversal!.labels = ["依赖"]; source.traversal!.depth = 4
        value = definition([source], primitives: [.relations])
        let bounded = try CompositionRuntime.project(value, in: book, selections: selected, boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]))["graph"]!
        XCTAssertEqual(Set(bounded.items.map(\.id)), ["a", "b", "c"])
        XCTAssertFalse(bounded.edges.contains { $0.id == "future" || $0.id == "futureBridge" })
        source.traversal!.labels = ["事件链"]
        value = definition([source], primitives: [.relations])
        func window(_ year: Int) -> [String: TemporalQueryWindow] { ["main": .date(from: TemporalDate(year: year), to: TemporalDate(year: year), calendar: "gregorian")] }
        let outside = try CompositionRuntime.project(value, in: book, selections: selected, windows: window(209))["graph"]!
        XCTAssertEqual(outside.items.map(\.id), ["a"]); XCTAssertTrue(outside.edges.isEmpty)
        let possible = try CompositionRuntime.project(value, in: book, selections: selected, windows: window(208))["graph"]!
        XCTAssertEqual(Set(possible.items.map(\.id)), ["a", "c", "ev"])
        XCTAssertTrue(possible.edges.allSatisfy { $0.temporalMatch == .unknown })
        XCTAssertTrue(possible.diagnostics.contains { $0.contains("时间待考") })
        source.traversal!.labels = ["时限"]; value = definition([source], primitives: [.relations])
        XCTAssertTrue(try CompositionRuntime.project(value, in: book, selections: selected, windows: window(208))["graph"]!.edges.isEmpty)
        let matched = try CompositionRuntime.project(value, in: book, selections: selected, windows: window(209))["graph"]!
        XCTAssertEqual(matched.edges.map(\.id), ["timed"]); XCTAssertEqual(matched.edges.first?.temporalMatch, .matches)
        XCTAssertTrue(matched.edges.first!.evidence.contains { $0.quote.contains("209年") }, "Keep the independent temporal provenance as well as the relation quote.")
        let first = book.entities[0].evidence[0], anchorID = book.temporalKnowledge!.anchors[0].id
        book.events.append(KnowledgeEvent(id: "undated", name: "前提", evidence: [first]))
        book.relations += [KnowledgeRelation(id: "unknownIn", fromID: "a", toID: "undated", label: "未知链", evidence: [first]),
            KnowledgeRelation(id: "unknownOut", fromID: "undated", toID: "c", label: "未知链", evidence: [first])]
        let time = TemporalExtent(sourceText: "209年", calendar: "gregorian", start: TemporalDate(year: 209), precision: .year, uncertainty: .exact)
        var state = book.temporalKnowledge!
        state.relationMetadata += ["unknownIn", "unknownOut"].map { RelationTemporalMetadata(id: "date." + $0, relationID: $0, validity: time, sourceAnchorIDs: [anchorID], assertion: .explicit) }
        book.temporalKnowledge = state
        source.traversal!.labels = ["未知链"]; value = definition([source], primitives: [.relations])
        let unknownNode = try CompositionRuntime.project(value, in: book, selections: selected, windows: window(209))["graph"]!
        XCTAssertTrue(unknownNode.edges.allSatisfy { $0.temporalMatch == .matches })
        XCTAssertEqual(unknownNode.items.first { $0.id == "undated" }?.fields["temporalMatch"], "unknown")
        XCTAssertTrue(unknownNode.diagnostics.contains { $0.contains("时间待考") }, "Dated edges cannot promote an undated intermediate event into a confirmed time.")
        let unauthorized = try CompositionRuntime.project(value, in: book, selections: ["main": ["e"]], boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]))["graph"]!
        XCTAssertTrue(unauthorized.items.isEmpty); XCTAssertTrue(unauthorized.edges.isEmpty)
    }

    func testObjectTableReadsDeclaredFieldsAndKeepsUnknownsSourcesAndFullValues() throws {
        var book = try traversalFixture()
        let longDefinition = String(repeating: "长内容", count: 300)
        book.entities[0].properties["definition"] = longDefinition
        let source = CompositionDataSource(id: "table", collection: .objects, scope: .book, typeIDs: ["proof-concept"])
        var value = definition([source], primitives: [.table])
        value.parts[0].columns = [CompositionTableColumn(field: "name", title: "概念"), CompositionTableColumn(field: "properties.definition", title: "定义"), CompositionTableColumn(field: "properties.condition")]
        XCTAssertNoThrow(try CompositionRuntime.validate(value, in: book))
        XCTAssertEqual(try JSONDecoder().decode(CompositionDefinition.self, from: JSONEncoder().encode(value)), value)
        let projected = try CompositionRuntime.project(value, in: book, boundary: KnowledgeReadBoundary(allowedUnitIDs: ["u1"]))["table"]!
        let first = try XCTUnwrap(projected.items.first { $0.id == "a" }), second = try XCTUnwrap(projected.items.first { $0.id == "b" })
        XCTAssertEqual(CompositionRuntime.tableValue("properties.definition", in: first), longDefinition)
        XCTAssertNil(CompositionRuntime.tableValue("properties.condition", in: second))
        XCTAssertEqual(first.evidence, book.entities[0].evidence)
        XCTAssertFalse(projected.items.contains { $0.id == "e" || $0.id == "d" || $0.id == "ev" })
        var invalid = value; invalid.parts[0].columns = [CompositionTableColumn(field: "properties.reason")]
        XCTAssertThrowsError(try CompositionRuntime.validate(invalid, in: book), "A field declared only by another type is not a table capability.")
        invalid = value; invalid.sources[0].typeIDs.append("proof-claim")
        XCTAssertThrowsError(try CompositionRuntime.validate(invalid, in: book))
        invalid = value; invalid.parts[0].columns = [CompositionTableColumn(field: "summary"), CompositionTableColumn(field: "summary")]
        XCTAssertThrowsError(try CompositionRuntime.validate(invalid, in: book))
        invalid = value; invalid.parts[0].primitive = .objectList
        XCTAssertThrowsError(try CompositionRuntime.validate(invalid, in: book))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        _ = try PluginEngine.apply(name: "views_configure", arguments: JSONSerialization.data(withJSONObject: ["views": [["id": "compare", "title": "概念对照", "kind": "knowledge", "rendererID": "reading.composition", "composition": encoded]]]), to: &book, allowedUnitIDs: [])
        XCTAssertEqual(book.views.first { $0.id == "compare" }?.composition, value)
    }

    func testOptionalTraversalAndTableAreClosedCompatibleAndShareTheActualToolSchema() throws {
        let book = try traversalFixture()
        let legacy = definition([CompositionDataSource(id: "legacy", collection: .objects)])
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil((raw["sources"] as? [[String: Any]])?.first?["traversal"])
        XCTAssertNil((raw["parts"] as? [[String: Any]])?.first?["columns"])
        XCTAssertThrowsError(try JSONDecoder().decode(CompositionTraversal.self, from: Data(#"{"depth":2,"script":"run()"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(CompositionTraversal.self, from: Data(#"{"direction":"sideways"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(CompositionTableColumn.self, from: Data(#"{"field":"summary","request":"https://example.invalid"}"#.utf8)))
        var value = definition([CompositionDataSource(id: "graph", collection: .relations, scope: .book, relation: .neighbors, traversal: CompositionTraversal())], primitives: [.relations])
        XCTAssertEqual(try JSONDecoder().decode(CompositionDefinition.self, from: JSONEncoder().encode(value)), value)
        for invalid in [CompositionTraversal(depth: 0), CompositionTraversal(depth: 5), CompositionTraversal(maxNodes: 0), CompositionTraversal(maxNodes: 201), CompositionTraversal(maxEdges: 0), CompositionTraversal(maxEdges: 801), CompositionTraversal(labels: ["依赖", "依赖"])] {
            value.sources[0].traversal = invalid; XCTAssertThrowsError(try CompositionRuntime.validate(value, in: book))
        }
        value.sources[0].traversal = CompositionTraversal(); value.sources[0].relation = .selected
        XCTAssertThrowsError(try CompositionRuntime.validate(value, in: book))
        let function = try XCTUnwrap(PluginEngine.tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "views_configure" })
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let views = try XCTUnwrap(properties["views"] as? [String: Any]), items = try XCTUnwrap(views["items"] as? [String: Any])
        let viewProperties = try XCTUnwrap(items["properties"] as? [String: Any]), actual = try XCTUnwrap(viewProperties["composition"] as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: .sortedKeys), try JSONSerialization.data(withJSONObject: CompositionSchema.definition, options: .sortedKeys))
    }
}
