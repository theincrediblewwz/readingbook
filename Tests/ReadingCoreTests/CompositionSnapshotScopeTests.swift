import Foundation
import CryptoKit
import XCTest
import ReadingCore

final class CompositionSnapshotScopeTests: XCTestCase {
    private func personID(_ index: Int) -> String { String(format: "person%03d", index) }

    private func fixture(_ count: Int = 2, futurePresence: Bool = true) throws -> BookProject {
        let intro = "叙事5，甲地有真实位置，人物有独立行动依据。"
        let units = [SourceUnit(id: "u1", order: 0, chapter: "当前", page: 1,
                                text: intro + "\n" + (0..<count).map { "人物\($0)。" }.joined()),
                     SourceUnit(id: "u2", order: 1, chapter: "后续", page: 2,
                                text: "叙事5，人物0又到甲地，存在另一条独立记录。")]
        let hash = SHA256.hash(data: Data(units.map(\.text).joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        var book = BookProject(id: "snapshot-scope-book", title: "快照范围", originalName: "synthetic.txt", sourceHash: hash, units: units)
        book.importedAt = Date(timeIntervalSince1970: 0)
        book.types = [EntityType(id: "person", name: "人物"), EntityType(id: "place", name: "地点")]
        book.entities = (0..<count).map { index in
            KnowledgeEntity(id: personID(index), typeID: "person", name: "人物\(index)",
                evidence: [Evidence(unitID: "u1", quote: "人物\(index)。")])
        }
        book.entities.append(KnowledgeEntity(id: "place", typeID: "place", name: "甲地", latitude: 20, longitude: 80,
            evidence: [Evidence(unitID: "u1", quote: "甲地")]))
        let first = try ReadingExperienceRuntime.createAnchor(sourceHash: hash, unitID: "u1", quote: intro, in: book)
        let later = try ReadingExperienceRuntime.createAnchor(sourceHash: hash, unitID: "u2", quote: units[1].text, in: book)
        let extent = TemporalExtent(sourceText: "叙事5", precision: .narrative, uncertainty: .exact, narrativeStart: 5)
        var presences = (0..<count).map { index in
            EntityPresence(id: "at-" + personID(index), entityID: personID(index), placeID: "place", extent: extent,
                action: "抵达-\(index)", sourceAnchorIDs: [first.id], assertion: .explicit)
        }
        if futurePresence {
            presences.append(EntityPresence(id: "future", entityID: personID(0), placeID: "place", extent: extent,
                action: "后续记录", sourceAnchorIDs: [later.id], assertion: .explicit))
        }
        book.temporalKnowledge = TemporalKnowledgeState(anchors: [first, later], presences: presences)
        return book
    }

    private func definition(_ sources: [CompositionDataSource], maps: Set<String> = []) -> CompositionDefinition {
        let parts = sources.enumerated().map { index, source in
            CompositionPart(id: "p\(index)", primitive: maps.contains(source.id) ? .map : .objectList,
                sourceID: source.id, selectionGroup: source.selectionGroup, timeGroup: source.timeGroup)
        }
        var layout = parts.map { CompositionLayoutNode(id: "leaf." + $0.id, kind: .part, partID: $0.id) }
        if parts.count == 1 { return CompositionDefinition(sources: sources, parts: parts, layout: layout, rootID: layout[0].id) }
        layout.append(CompositionLayoutNode(id: "root", kind: .column, children: layout.map(\.id)))
        return CompositionDefinition(sources: sources, parts: parts, layout: layout, rootID: "root")
    }

    private func encoded(_ book: BookProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(book)
    }

    func testSharedEntityMapsKeepScopeAndActualPointVersusWindowSeparate() throws {
        let book = try fixture(), original = try encoded(book)
        let sources = [
            CompositionDataSource(id: "wide", collection: .objects, scope: .book, typeIDs: ["person"], timeGroup: "selected"),
            CompositionDataSource(id: "local", collection: .objects, scope: .current, typeIDs: ["person"], timeGroup: "selected"),
            CompositionDataSource(id: "range", collection: .objects, scope: .book, typeIDs: ["person"], timeGroup: "range")]
        let value = try CompositionRuntime.project(definition(sources, maps: ["wide", "local", "range"]), in: book,
            context: ReadingContext(sourceHash: book.sourceHash, unitID: "u1", page: 1),
            times: ["selected": .narrative(5), "range": .narrative(6)],
            windows: ["range": .narrative(from: 4, to: 6)], mapModes: ["range": .windowFootprints])
        let wide = try XCTUnwrap(value["wide"]), local = try XCTUnwrap(value["local"]), range = try XCTUnwrap(value["range"])
        XCTAssertTrue(wide.mapPoints.contains { $0.id == "presence.future" })
        XCTAssertFalse(local.mapPoints.contains { $0.id == "presence.future" })
        XCTAssertEqual(local.mapPoints.count, 2, "The current page still has its two positively anchored footprints.")
        XCTAssertTrue(local.mapPoints.allSatisfy { !$0.evidence.isEmpty && $0.evidence.allSatisfy { $0.unitID == "u1" } })
        XCTAssertEqual(range.mapPoints.count, 3, "The window includes both source scopes at time5.")
        XCTAssertTrue(range.items.allSatisfy { $0.fields["此时行动"] == "没有已核实的行动记录" },
            "Rows describe cursor6 even when this source's map shows window4...6 footprints.")
        XCTAssertEqual(try encoded(book), original)
    }

    func testMoreThan200EntityTimeInputsPreserveOverflowAndReusedOutputs() throws {
        let book = try fixture(240, futurePresence: false)
        let sources = [
            CompositionDataSource(id: "five", collection: .objects, scope: .book, typeIDs: ["person"], timeGroup: "five", limit: 200),
            CompositionDataSource(id: "six", collection: .objects, scope: .book, typeIDs: ["person"], timeGroup: "six", limit: 200),
            CompositionDataSource(id: "again", collection: .objects, scope: .book, typeIDs: ["person"], timeGroup: "five", limit: 200)]
        let value = try CompositionRuntime.project(definition(sources, maps: ["again"]), in: book,
            times: ["five": .narrative(5), "six": .narrative(6)])
        let five = try XCTUnwrap(value["five"]), six = try XCTUnwrap(value["six"]), again = try XCTUnwrap(value["again"])
        for projection in [five, six, again] {
            XCTAssertEqual(projection.items.count, 200); XCTAssertEqual(projection.total, 240); XCTAssertTrue(projection.partial)
        }
        for (index, item) in five.items.enumerated() {
            XCTAssertEqual(item.id, personID(index))
            XCTAssertTrue(item.fields["此时行动"]?.hasPrefix("抵达-\(index) ·") == true)
        }
        XCTAssertEqual(six.items.map(\.id), five.items.map(\.id))
        XCTAssertTrue(six.items.allSatisfy { $0.fields["此时行动"] == "没有已核实的行动记录" })
        XCTAssertEqual(again.items, five.items)
        XCTAssertEqual(again.mapPoints.count, 200)
        XCTAssertEqual(Set(again.mapPoints.map(\.targetID)), Set(five.items.map(\.id)))
    }

    func testNewPreparedTemporalDataAndCancelledReadDoNotReusePriorResults() async throws {
        let original = try fixture()
        let spec = definition([CompositionDataSource(id: "people", collection: .objects, scope: .book, typeIDs: ["person"])], maps: ["people"])
        let times: [String: TemporalQueryPoint] = ["main": .narrative(5)]
        let prepared = try CompositionRuntime.prepare(spec, in: original)
        let before = try XCTUnwrap(CompositionRuntime.project(prepared, times: times)["people"])
        var changed = original
        var temporal = try XCTUnwrap(changed.temporalKnowledge)
        temporal.presences[0].action = "更新后的抵达"
        changed.temporalKnowledge = temporal
        XCTAssertEqual(changed.id, original.id); XCTAssertEqual(changed.sourceHash, original.sourceHash)
        let fresh = try XCTUnwrap(CompositionRuntime.project(spec, in: changed, times: times)["people"])
        XCTAssertTrue(fresh.items.first { $0.id == personID(0) }?.fields["此时行动"]?.contains("更新后的抵达") == true)
        XCTAssertTrue(fresh.mapPoints.first { $0.id == "presence.at-" + personID(0) }?.subtitle.hasPrefix("更新后的抵达 ·") == true)
        let retained = try XCTUnwrap(CompositionRuntime.project(prepared, times: times)["people"])
        XCTAssertEqual(retained.items, before.items); XCTAssertEqual(retained.mapPoints, before.mapPoints)
        let cancelled = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try CompositionRuntime.project(prepared, times: times); return false }
            catch { return error is CancellationError }
        }
        let rejected = await cancelled.value
        XCTAssertTrue(rejected)
    }
}
