import Foundation
import XCTest
@testable import ReadingCore

/// All names, IDs, coordinates and source offsets vary; nothing in production
/// may recognize these fixtures or a particular book to make them work.
struct ScenarioPresentationFixture {
    let project: BookProject
    let eventID: String
    let placeID: String
    let routeID: String
    let viewID: String
    let firstOrder: Int
    let moving: Bool
    init(index: Int, moving: Bool) throws {
        let labels = [("湖泊调查", "移交样本", "北岸站", "芦苇湾"),
                      ("山地救援", "伤员转运", "山口", "补给点"),
                      ("Field journal", "Calibration", "Station North", "Station South"),
                      ("城市维护", "设备复检", "东站", "西站")][index % 4]
        let prefix = "scenario-\(index)-"
        eventID = prefix + "event"; placeID = prefix + "destination"; routeID = prefix + "movement"; viewID = prefix + "view"
        firstOrder = 11 + index * 37; self.moving = moving
        let startOrder = firstOrder
        let units = (0..<3).map { offset in SourceUnit(id: prefix + "source-\(offset)", order: startOrder + offset,
            chapter: labels.0, page: index * 3 + offset + 1, text: "\(labels.0)：\(labels.1)，由\(labels.2)到\(labels.3)。记录\(offset)。") }
        var book = BookProject(title: labels.0, originalName: "new-scene.txt", sourceHash: prefix + "hash", units: units)
        book.id = prefix + "book"; PluginEngine.seed(&book)
        let proofs = units.map { Evidence(unitID: $0.id, quote: $0.text) }
        book.entities = [
            .init(id: prefix + "origin", typeID: "place", name: labels.2, latitude: -36 + Double(index), longitude: 143 - Double(index), evidence: [proofs[0]]),
            .init(id: placeID, typeID: "place", name: labels.3, latitude: -35 + Double(index), longitude: 144 - Double(index), evidence: [proofs[1]]),
            .init(id: prefix + "unrelated", typeID: "place", name: labels.3, latitude: 10, longitude: 22, evidence: [proofs[2]])]
        book.events = [.init(id: eventID, name: labels.1, dateText: "原文顺序", placeIDs: [placeID], evidence: Array(proofs.prefix(2)))]
        let anchors = try units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.id, quote: $0.text, in: book) }
        book.relations = moving ? [.init(id: routeID, fromID: prefix + "origin", toID: placeID, label: labels.1, evidence: [proofs[1]])] : []
        book.temporalKnowledge = .init(anchors: anchors,
            eventMetadata: [.init(eventID: eventID, kind: "field-record", sourceAnchorIDs: Array(anchors.prefix(2).map(\.id)), assertion: .explicit)],
            relationMetadata: moving ? [.init(id: prefix + "movement-metadata", relationID: routeID, validity: .init(), sourceAnchorIDs: [anchors[1].id], assertion: .explicit,
                spatial: .init(kind: "sample-transfer", eventID: eventID))] : [])
        book.views = [.init(id: viewID, title: labels.0, kind: .knowledge, rendererID: "reading.composition", composition: ReadingWorkbench.definition(for: ReadingWorkbench.timeMapTemplateID))]
        project = book
    }
    func workspace() -> ReadingWorkspaceSnapshot {
        let place = project.entities.first { $0.id == placeID }!
        return .init(bookID: project.id, sourceHash: project.sourceHash, rendererID: viewID, selectedObjectIDs: [eventID],
            visibleObjects: .init(rendererID: viewID, objectIDs: [placeID]),
            mapViewports: [.init(partID: "map", latitude: place.latitude!, longitude: place.longitude!, latitudeDelta: 3, longitudeDelta: 3,
                objectIDs: [placeID], visibleRouteIDs: moving ? [routeID] : [], projectedRouteIDs: moving ? [routeID] : [])],
            timeWindows: [.init(groupID: "independent-clock", axis: "narrative-domain:source-order", from: Double(firstOrder), to: Double(firstOrder + 1), current: Double(firstOrder))], observationStatus: .ready)
    }
}

actor ScenarioPresentationFeed {
    let fixture: ScenarioPresentationFixture
    let openStatus: String
    let returnedViewID: String?
    let cancelOpening: Bool
    let preferredAxis: String?
    var calls: [(String, Data)] = []
    init(_ fixture: ScenarioPresentationFixture, openStatus: String = "success", returnedViewID: String? = nil, cancelOpening: Bool = false, preferredAxis: String? = nil) {
        self.fixture = fixture; self.openStatus = openStatus; self.returnedViewID = returnedViewID; self.cancelOpening = cancelOpening
        self.preferredAxis = preferredAxis
    }
    func apply(_ name: String, _ data: Data) throws -> Data {
        calls.append((name, data))
        if name == "component_show" {
            if cancelOpening { throw CancellationError() }
            let args = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if args["viewID"] as? String != fixture.viewID {
                return Data(#"{"ok":false,"status":"unsupported","opened":false}"#.utf8)
            }
            return try JSONSerialization.data(withJSONObject: ["ok": openStatus == "success", "status": openStatus,
                "viewID": returnedViewID ?? fixture.viewID, "rendererID": "reading.composition", "opened": openStatus == "success", "created": false, "analysisCreated": false])
        }
        return try JSONSerialization.data(withJSONObject: ["ok": true, "status": "success", "rendererID": fixture.viewID, "cameraStatus": "success"])
    }
    func read() -> ReadingWorkspaceSnapshot { var value = fixture.workspace(); value.timeAxis = preferredAxis; return value }
    nonisolated func access(openAllowed: Bool = true) -> ReadingHostToolAccess {
        .init(viewActions: openAllowed ? ["component_show", "view_show_event"] : ["view_show_event"],
            performViewAction: { try await self.apply($0, $1) }, readWorkspace: { await self.read() }, readWorkspaceAfterOpening: { _ in await self.read() })
    }
}

func runScenarioPresentationChain(_ fixture: ScenarioPresentationFixture, combined: Bool) async throws -> [String: Any] {
    let feed = ScenarioPresentationFeed(fixture); var requests = 0, inputBytes = 0
    let result = try await ReadingAnswerEngine.run(question: "打开已有调查工作台并展示指定记录。", project: fixture.project,
        settings: .init(model: "offline", maxOutputTokens: 1024, contextWindowTokens: 262_144), documents: [:], context: nil, scope: .book,
        history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 262_144, remainingRequests: 8,
        hostTools: feed.access(), preferences: .init(interaction: .functional)) { messages, tools, _, _ in
            requests += 1; inputBytes += try QueryBudget.inputBytes(messages, tools: tools, model: "offline")
            let name: String, args: [String: Any]
            if !combined && requests == 1 { name = "component_show"; args = ["viewID": fixture.viewID] }
            else if requests == (combined ? 1 : 2) {
                name = "view_show_event"; args = combined ? ["eventID": fixture.eventID, "viewID": fixture.viewID] : ["eventID": fixture.eventID]
            } else {
                return .init(message: .init(role: "assistant", content: "已显示调查记录及其地点。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
            }
            let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
            return .init(message: .init(role: "assistant", content: "", refusal: nil,
                tool_calls: [.init(id: "chain-\(requests)", type: "function", function: .init(name: name, arguments: String(decoding: data, as: UTF8.self)))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 30)
        }
    let calls = await feed.calls
    return ["modelTurns": requests, "inputEnvelopeBytes": inputBytes, "hostActions": calls.map(\.0), "toolCalls": result.diagnostics.toolCalls,
            "sourceReadIDs": result.diagnostics.sourceReadIDs, "answer": result.message.content]
}

final class ScenarioPresentationTests: XCTestCase {
    private func session(_ f: ScenarioPresentationFixture, host: ReadingHostToolAccess?) throws -> ReadingQuerySession {
        .init(snapshot: try .freeze(scope: .book, in: f.project), history: [], loader: nil, providedDocuments: [:], project: f.project, hostTools: host)
    }
    private func json(_ raw: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any] }
    func testRenamedNonWarEventsUseSharedProofAcrossCoordinatesAndOffsets() throws {
        for index in 0..<12 {
            for moving in [true, false] {
                let f = try ScenarioPresentationFixture(index: index, moving: moving)
                let snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: f.project)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let before = try encoder.encode(f.project), plan = try ReadingEventPresentationPlan.resolve(eventID: f.eventID, in: f.project, snapshot: snapshot)
                XCTAssertEqual(plan.window.from, Double(f.firstOrder)); XCTAssertEqual(plan.window.to, Double(f.firstOrder + 1))
                XCTAssertEqual(plan.knownPlaceIDs, [f.placeID]); XCTAssertEqual(plan.knownRouteIDs, moving ? [f.routeID] : [])
                XCTAssertEqual(plan.missing(in: f.workspace()), [])
                var unrelated = f.workspace(); unrelated.mapViewports?[0].objectIDs = ["scenario-\(index)-unrelated"]
                unrelated.mapViewports?[0].visibleRouteIDs = []
                XCTAssertTrue(plan.missing(in: unrelated).contains("event_visible"), "Same name or another place is not proof")
                XCTAssertEqual(try encoder.encode(f.project), before)
            }
        }
    }
    func testCombinedOpeningAndPresentationRetainsSameHostEffectsWithOneLessModelTurn() async throws {
        let f = try ScenarioPresentationFixture(index: 2, moving: true)
        let old = try await runScenarioPresentationChain(f, combined: false), new = try await runScenarioPresentationChain(f, combined: true)
        XCTAssertEqual(old["modelTurns"] as? Int, 3); XCTAssertEqual(new["modelTurns"] as? Int, 2)
        XCTAssertEqual(old["hostActions"] as? [String], new["hostActions"] as? [String])
        XCTAssertEqual(new["hostActions"] as? [String], ["component_show", "view_show_event"])
        XCTAssertEqual(old["answer"] as? String, new["answer"] as? String)
        XCTAssertTrue((new["inputEnvelopeBytes"] as? Int ?? Int.max) < (old["inputEnvelopeBytes"] as? Int ?? 0))
        XCTAssertEqual((new["sourceReadIDs"] as? [String])?.count, 0)
    }
    func testWholeBookPresentationKeepsAdmittedAnalyzedNamesAndPlaceReferences() throws {
        let fixture = try ScenarioPresentationFixture(index: 3, moving: false)
        var book = fixture.project
        // Analysis labels need not be literal words from the source: this also
        // represents translated names, aliases and reader-renamed objects.
        book.entities[1].name = "Survey station beta"
        book.events[0].name = "Inspection completed"
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        XCTAssertEqual(try ReadingEventPresentationPlan.resolve(eventID: fixture.eventID, in: book, snapshot: snapshot).knownPlaceIDs, [], "Full identity remains a host policy, not a default grant")
        let plan = try ReadingEventPresentationPlan.resolve(eventID: fixture.eventID, in: book, snapshot: snapshot, allowsFullIdentity: true)
        XCTAssertEqual(plan.knownPlaceIDs, [fixture.placeID])
        XCTAssertEqual(plan.missing(in: fixture.workspace()), [])
        let narrow = try ReadingQuerySnapshot.freeze(scope: .page, in: book,
            context: .init(unitID: book.units[0].id, page: book.units[0].page))
        XCTAssertThrowsError(try ReadingEventPresentationPlan.resolve(eventID: fixture.eventID, in: book, snapshot: narrow, allowsFullIdentity: true))
        XCTAssertEqual(book.entities[1].name, "Survey station beta")
    }
    func testCombinedActionWorksWithNonWarNamesAndNeverCreatesOrReadsFacts() async throws {
        for index in 0..<4 {
            let f = try ScenarioPresentationFixture(index: index, moving: index % 2 == 0), feed = ScenarioPresentationFeed(f)
            var s = try session(f, host: feed.access())
            let value = try json(try await s.execute(name: "view_show_event", arguments: ["viewID": f.viewID, "eventID": f.eventID], maximumBytes: 16000))
            XCTAssertEqual(value["complete"] as? Bool, true); XCTAssertEqual(value["openedViewID"] as? String, f.viewID)
            let calls = await feed.calls
            XCTAssertEqual(calls.map(\.0), ["component_show", "view_show_event"])
            let opened = try JSONSerialization.jsonObject(with: calls[0].1) as! [String: Any]
            XCTAssertEqual(Set(opened.keys), ["viewID"])
            XCTAssertTrue(s.sourceExcerpts.isEmpty); XCTAssertTrue(s.sourceReferences.isEmpty); XCTAssertNil(s.lastComponentReceipt)
            XCTAssertEqual(s.project?.events, f.project.events); XCTAssertEqual(s.project?.views, f.project.views)
        }
    }
    func testMissingOpenPermissionInvalidTargetAndUnknownFieldsCauseNoSideEffects() async throws {
        let f = try ScenarioPresentationFixture(index: 1, moving: false), feed = ScenarioPresentationFeed(f)
        var s = try session(f, host: feed.access(openAllowed: false))
        do { _ = try await s.execute(name: "view_show_event", arguments: ["eventID": f.eventID, "viewID": f.viewID], maximumBytes: 16000); XCTFail("requires opening permission") } catch {}
        s = try session(f, host: feed.access())
        for args: [String: Any] in [["eventID": "unknown", "viewID": f.viewID],
            ["eventID": f.eventID, "viewID": 1], ["eventID": f.eventID, "viewID": " "], ["eventID": f.eventID, "viewID": f.viewID, "from": 1]] {
            do { _ = try await s.execute(name: "view_show_event", arguments: args, maximumBytes: 16000); XCTFail("invalid target") } catch {}
        }
        let count = await feed.calls.count; XCTAssertEqual(count, 0)
    }
    func testHostRegistryOwnsNewViewsAndRejectsUnknownViewsWithoutCreatingData() async throws {
        let f = try ScenarioPresentationFixture(index: 1, moving: false), feed = ScenarioPresentationFeed(f)
        var old = f.project; old.views = []
        var s = ReadingQuerySession(snapshot: try .freeze(scope: .book, in: old), history: [], loader: nil, providedDocuments: [:], project: old, hostTools: feed.access())
        let shown = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": f.eventID, "viewID": f.viewID], maximumBytes: 16000))
        XCTAssertEqual(shown["complete"] as? Bool, true, "A component just created by this task is absent from the frozen knowledge directory")
        XCTAssertEqual(s.project?.views.count, 0, "Opening a live view must not import new knowledge or permissions")
        let unknown = ScenarioPresentationFeed(f); s = try session(f, host: unknown.access())
        let rejected = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": f.eventID, "viewID": "unknown"], maximumBytes: 16000))
        XCTAssertEqual(rejected["complete"] as? Bool, false)
        let calls = await unknown.calls; XCTAssertEqual(calls.map(\.0), ["component_show"])
    }
    func testFailedOrWrongOpeningDoesNotPresentIntoAnotherWindow() async throws {
        let f = try ScenarioPresentationFixture(index: 3, moving: false)
        for status in ["busy", "unsupported", "needs_confirmation", "success"] {
            let feed = ScenarioPresentationFeed(f, openStatus: status, returnedViewID: status == "success" ? "another-view" : nil)
            var s = try session(f, host: feed.access())
            let value = try json(try await s.execute(name: "view_show_event", arguments: ["viewID": f.viewID, "eventID": f.eventID], maximumBytes: 16000))
            XCTAssertEqual(value["complete"] as? Bool, false); XCTAssertEqual(value["applied"] as? Bool, false)
            XCTAssertTrue((value["missing"] as? [String] ?? []).contains("component_opened"))
            let calls = await feed.calls; XCTAssertEqual(calls.map(\.0), ["component_show"])
        }
    }
    func testCancellationAndInsufficientBudgetDoNotApplyPresentation() async throws {
        let f = try ScenarioPresentationFixture(index: 0, moving: true), feed = ScenarioPresentationFeed(f, cancelOpening: true)
        var s = try session(f, host: feed.access())
        let low = try json(try await s.execute(name: "view_show_event", arguments: ["viewID": f.viewID, "eventID": f.eventID], maximumBytes: 4000))
        XCTAssertEqual(low["budgetLimited"] as? Bool, true)
        do { _ = try await s.execute(name: "view_show_event", arguments: ["viewID": f.viewID, "eventID": f.eventID], maximumBytes: 16000); XCTFail("cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await feed.calls; XCTAssertEqual(calls.map(\.0), ["component_show"])
    }
    func testPartialSourceRangeCannotOpenAViewToRecoverHiddenEventDetails() async throws {
        for index in 0..<4 {
            let f = try ScenarioPresentationFixture(index: index, moving: true), feed = ScenarioPresentationFeed(f)
            let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: f.project,
                context: .init(unitID: f.project.units[0].id, page: f.project.units[0].page))
            var s = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: f.project, hostTools: feed.access())
            do { _ = try await s.execute(name: "view_show_event", arguments: ["viewID": f.viewID, "eventID": f.eventID], maximumBytes: 16000); XCTFail("unshared full event") } catch {}
            let calls = await feed.calls; XCTAssertTrue(calls.isEmpty)
            XCTAssertTrue(s.sourceExcerpts.isEmpty); XCTAssertTrue(s.sourceReferences.isEmpty)
        }
    }
    func testRecordedDatesUseNamedCalendarsAndPreserveExplicitSourceOrderChoice() throws {
        for calendar in ["公历", "调查纪元", "田野历"] {
            var f = try ScenarioPresentationFixture(index: 2, moving: true).project
            let first = TemporalDate(year: 2032, month: 5, day: 3), last = TemporalDate(year: 2032, month: 5, day: 6)
            let extent = TemporalExtent(sourceText: "记录原有日期", calendar: calendar, start: first, end: last,
                precision: .day, uncertainty: .exact, kind: .interval, assertion: .explicit)
            f.temporalKnowledge?.eventMetadata[0].extent = extent
            f.temporalKnowledge?.relationMetadata[0].validity = extent
            let snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: f), id = f.events[0].id
            let plan = try ReadingEventPresentationPlan.resolve(eventID: id, in: f, snapshot: snapshot)
            let axis = TemporalAxis("calendar-day:" + calendar)
            XCTAssertEqual(plan.window.axis, axis.id)
            XCTAssertEqual(axis.date(plan.window.from), first); XCTAssertEqual(axis.date(plan.window.to), last)
            XCTAssertEqual(plan.knownRouteIDs, [f.relations[0].id])
            let source = try ReadingEventPresentationPlan.resolve(eventID: id, in: f, snapshot: snapshot, preferredAxis: "narrative-domain:source-order")
            XCTAssertEqual(source.window.axis, "narrative-domain:source-order")
            XCTAssertEqual(source.window.from, Double(f.units[0].order)); XCTAssertEqual(source.window.to, Double(f.units[1].order))
        }
    }
    func testApproximateMonthOnlyAndUnassertedDatesDoNotInventDateBounds() throws {
        let f = try ScenarioPresentationFixture(index: 0, moving: false)
        let source = TemporalExtent(narrativeStart: f.firstOrder, narrativeEnd: f.firstOrder + 1, narrativeDomain: "source-order")
        let expected = try XCTUnwrap(ReadingEventPresentationPlan.sourceWindow(source))
        let precise = TemporalExtent(sourceText: "原记录确切日期", calendar: "公历", start: .init(year: 2032, month: 5, day: 3), precision: .day, uncertainty: .exact, assertion: .explicit)
        var uncertain = precise; uncertain.uncertainty = .approximate
        var inferred = precise; inferred.assertion = .inferred
        var monthOnly = precise; monthOnly.start?.day = nil; monthOnly.precision = .month
        var missingEnd = precise; missingEnd.kind = .interval
        for extent in [uncertain, inferred, monthOnly, missingEnd] {
            XCTAssertEqual(ReadingEventPresentationPlan.presentationWindow(recorded: extent, source: source), expected)
        }
        let year = TemporalExtent(sourceText: "原记录的年号范围", calendar: "本书年号", start: .init(year: -12), end: .init(year: -10), precision: .year, uncertainty: .exact, kind: .interval, assertion: .explicit)
        let window = try XCTUnwrap(ReadingEventPresentationPlan.presentationWindow(recorded: year, source: source))
        XCTAssertEqual(window.axis, "calendar:本书年号"); XCTAssertEqual(window.from, -12); XCTAssertEqual(window.to, -10)
    }
    func testCalendarReceiptAndRendererUseTheSameSavedDateWindow() throws {
        let fixture = try ScenarioPresentationFixture(index: 0, moving: true)
        var book = fixture.project
        let extent = TemporalExtent(sourceText: "2032年5月4日", calendar: "公历", start: .init(year: 2032, month: 5, day: 4),
            precision: .day, uncertainty: .exact, assertion: .explicit)
        book.temporalKnowledge?.eventMetadata[0].extent = extent; book.temporalKnowledge?.relationMetadata[0].validity = extent
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        let plan = try ReadingEventPresentationPlan.resolve(eventID: fixture.eventID, in: book, snapshot: snapshot)
        let group = try XCTUnwrap(book.views[0].composition?.parts.first { $0.primitive == .map }?.timeGroup)
        var state = fixture.workspace(); state.timeWindows = [.init(groupID: group, axis: plan.window.axis, from: plan.window.from, to: plan.window.to, current: plan.window.cursor)]
        let s = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, workspace: state)
        let context = try XCTUnwrap(s.eventReceiptContext(plan, maximumBytes: 8000))
        XCTAssertEqual(context["recordsInWindow"] as? Int, 1); XCTAssertEqual(context["visibleRelationCount"] as? Int, 1)
        let event = try XCTUnwrap(context["event"] as? [String: Any]); XCTAssertTrue((event["timeSummary"] as? String ?? "").contains("2032"))
        let prepared = try CompositionRuntime.prepare(try XCTUnwrap(book.views[0].composition), in: book, context: .init(), sourceSnapshot: snapshot)
        let projections = try CompositionRuntime.project(prepared)
        let item = try XCTUnwrap(projections.values.flatMap(\.items).first { $0.objectID == fixture.eventID })
        XCTAssertEqual(ReadingEventPresentationPlan.presentationWindow(recorded: item.extent, source: item.sourceExtent, preferredAxis: plan.window.axis), plan.window)
        XCTAssertEqual(plan.missing(in: state), [])
    }
    func testUserClockChangeIsReadFreshRatherThanFromLastModelReceipt() async throws {
        let fixture = try ScenarioPresentationFixture(index: 0, moving: false), feed = ScenarioPresentationFeed(try ScenarioPresentationFixture(index: 0, moving: false), preferredAxis: "narrative-domain:source-order")
        var book = fixture.project
        book.temporalKnowledge?.eventMetadata[0].extent = .init(sourceText: "2032年5月4日", calendar: "公历", start: .init(year: 2032, month: 5, day: 4), precision: .day, uncertainty: .exact, assertion: .explicit)
        var cached = fixture.workspace(); cached.timeAxis = "calendar-day:公历"
        var s = ReadingQuerySession(snapshot: try .freeze(scope: .book, in: book), history: [], loader: nil, providedDocuments: [:], project: book, workspace: cached, hostTools: feed.access())
        let value = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": fixture.eventID], maximumBytes: 16000))
        XCTAssertEqual(value["complete"] as? Bool, true)
        XCTAssertEqual((value["goal"] as? [String: Any])?["axis"] as? String, "narrative-domain:source-order")
    }
}
