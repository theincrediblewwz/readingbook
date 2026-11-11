import Foundation
import XCTest
@testable import ReadingCore

final class MapAssetChoiceTests: XCTestCase {
    private func fixture() -> (BookProject, ViewDefinition) {
        var book = BookProject(id: "assets", title: "读者工作台", originalName: "book.txt", sourceHash: "h",
            units: [.init(id: "u", order: 0, chapter: "记录", text: "一次校验和一次转运。")])
        PluginEngine.seed(&book)
        let definition = CompositionDefinition(sources: [.init(id: "events", collection: .events)],
            parts: [.init(id: "map", primitive: .map, sourceID: "events")], layout: [.init(id: "root", kind: .part, partID: "map")], rootID: "root")
        let view = ViewDefinition(id: "view", title: "已有工作台", kind: .cards, rendererID: "reading.composition", composition: definition)
        book.views = [view]; return (book, view)
    }
    func testExplicitAssetChoiceOverridesHintsWithoutChangingFreeKinds() throws {
        for kind in ["特殊校验", "Field calibration", "任意新类别"] {
            XCTAssertEqual(SpatialMarkerAssets.resolve(kind: kind, title: "火攻", mappings: [kind: "measurement"]).id, "measurement")
            XCTAssertEqual(SpatialMarkerAssets.resolve(kind: kind, title: "火攻", mappings: [:]).id, "event")
            XCTAssertEqual(SpatialMarkerAssets.resolve(kind: kind, title: "火攻").id, "fire")
        }
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "retreat", title: "火攻", mappings: ["retreat": "observation"]).id, "observation")
        XCTAssertEqual(SpatialMarkerAssets.resolve(kind: "group", mappings: [:]).id, "event")
        XCTAssertEqual(SpatialMarkerAssets.asset("group").title, "一组记录")
        XCTAssertFalse(SpatialMarkerAssets.selectable.contains { $0.id == "group" })
    }
    func testProjectionUsesChosenAssetsForObjectsAndActionsAndPreservesFamily() {
        let point = CompositionMapPoint(id: "event.e.p", targetID: "e", title: "活动", subtitle: "站内",
            latitude: 31, longitude: 121, evidence: [], kind: "eventLocation", markerKind: "校验", affinityID: "root", affinityTitle: "一个过程")
        let route = SpatialRoute(id: "r", relationID: "r", eventID: "e", title: "送样", kind: "运送样本", actorIDs: [], actorNames: [],
            placeIDs: ["a", "b"], placeNames: ["甲站", "乙站"], coordinates: [.init(latitude: 31, longitude: 121), .init(latitude: 31.1, longitude: 121.1)],
            assertion: .explicit, timeMatch: .matches, extent: .init(), explanation: "", evidence: [], locationNotes: [])
        let seeds = SpatialMarkerSeeds.make(points: [point], routes: [route], mappings: ["校验": "measurement", "运送样本": "transport"])
        XCTAssertEqual(seeds.map(\.assetID), ["measurement", "transport"])
        XCTAssertEqual(seeds.map(\.affinityID), ["root", "root"])
        XCTAssertEqual(seeds[0].objectID, "e"); XCTAssertEqual(seeds[1].routeID, "r")
        XCTAssertEqual(point.markerKind, "校验"); XCTAssertEqual(route.kind, "运送样本")
        let grouped = SpatialMarkerPacking.layout(seeds.map { .init(seed: $0, x: 150, y: 150) }, width: 800, height: 500)
        XCTAssertEqual(grouped.nodes.first?.assetID, "group")
        XCTAssertEqual(Set(grouped.nodes.flatMap(\.members).map(\.assetID)), ["measurement", "transport"])
    }
    func testOldAndNewDefinitionsRoundTripAndMappingsDoNotBecomeFacts() throws {
        let (book, view) = fixture(); let old = view.composition!
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("markerAssets"))
        XCTAssertEqual(try JSONDecoder().decode(CompositionDefinition.self, from: data), old)
        var fresh = old; fresh.parts[0].markerAssets = ["校验": "measurement"]
        try CompositionRuntime.validate(fresh, in: book)
        XCTAssertEqual(try JSONDecoder().decode(CompositionDefinition.self, from: JSONEncoder().encode(fresh)), fresh)
        XCTAssertEqual(fresh.sources, old.sources); XCTAssertEqual(book.views, [view])
    }
    func testInvalidMappingReturnsFocusedIssueAndDoesNotChangeView() throws {
        let (book, view) = fixture()
        for mapping in [["校验":"not-installed"], ["":"measurement"], [" 校验":"measurement"], ["校验":"group"], Dictionary(uniqueKeysWithValues: (0..<33).map { (String($0), "event") })] {
            var value = view.composition!; value.parts[0].markerAssets = mapping
            do { try CompositionRuntime.validate(value, in: book); XCTFail("invalid mapping accepted") }
            catch let error as ReadingCompositionError { XCTAssertEqual(error.issues.first?.path, "parts[0].markerAssets") }
        }
        var wrong = view.composition!; wrong.parts[0].primitive = .objectList; wrong.parts[0].markerAssets = [:]
        XCTAssertThrowsError(try CompositionRuntime.validate(wrong, in: book))
        XCTAssertNil(view.composition!.parts[0].markerAssets)
    }
    func testPresentationPatchAndRestoreKeepDataBindingsAndOneBackup() throws {
        let (book, view) = fixture(), old = view.composition!
        let changed = try ReadingComponentLayout.changed(view, expectedRevision: ReadingComponentLayout.revision(old), layout: nil, rootID: nil,
            restore: false, markerAssets: ["map": ["校验":"measurement"]], in: book)
        XCTAssertEqual(changed.id, view.id); XCTAssertEqual(changed.composition!.sources, old.sources)
        XCTAssertEqual(changed.composition!.layout, old.layout)
        XCTAssertEqual(changed.composition!.parts[0].markerAssets, ["校验":"measurement"])
        let restored = try ReadingComponentLayout.changed(changed, expectedRevision: ReadingComponentLayout.revision(changed.composition!), layout: nil, rootID: nil, restore: true, in: book)
        XCTAssertEqual(restored.composition, old)
        XCTAssertEqual(restored.previousLayout!.markerAssets, ["map": ["校验":"measurement"]])
        let again = try ReadingComponentLayout.changed(restored, expectedRevision: ReadingComponentLayout.revision(restored.composition!), layout: nil, rootID: nil, restore: true, in: book)
        XCTAssertEqual(again.composition, changed.composition)
        XCTAssertEqual(try JSONDecoder().decode(ViewDefinition.self, from: JSONEncoder().encode(changed)), changed)
    }
    func testRevisionWrongPartAndClosedRequestRejectWithoutMutation() throws {
        let (book, view) = fixture(), old = view.composition!, revision = try ReadingComponentLayout.revision(old)
        let request = ReadingComponentRequest(viewID: "view", layoutRevision: revision, markerAssets: ["map": [:]])
        XCTAssertEqual(try ReadingComponentRequest.decode(JSONEncoder().encode(request)).markerAssets, ["map": [:]])
        for invalid in [ReadingComponentRequest(viewID: "view", markerAssets: ["map": [:]]),
                        ReadingComponentRequest(componentID: "reading.composition", layoutRevision: revision, markerAssets: ["map": [:]]),
                        ReadingComponentRequest(viewID: "view", layoutRevision: revision, restoreLayout: true, markerAssets: ["map": [:]])] {
            XCTAssertThrowsError(try ReadingComponentRequest.decode(JSONEncoder().encode(invalid)))
        }
        XCTAssertThrowsError(try ReadingComponentLayout.changed(view, expectedRevision: "stale", layout: nil, rootID: nil, restore: false, markerAssets: ["map": [:]], in: book))
        XCTAssertThrowsError(try ReadingComponentLayout.changed(view, expectedRevision: revision, layout: nil, rootID: nil, restore: false, markerAssets: ["unknown": [:]], in: book))
        XCTAssertEqual(book.views, [view]); XCTAssertNil(view.previousLayout)
    }
    func testCanonicalStylePatchKeepsConcurrentNoteAndExistingView() async throws {
        let pair = fixture(); var book = pair.0; let view = pair.1
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MapAssets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.txt"); try Data(book.units[0].text.utf8).write(to: source)
        book.id = UUID().uuidString; book.sourceHash = try BookImporter.sha256(Data(contentsOf: source))
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library")); var latest = try await repository.create(book, sourceURL: source)
        let note = DocumentRecord(id: "note", title: "读者笔记"); latest = try await repository.saveDocument(project: latest, document: note, markdown: "保留我的内容。")
        let result = try await repository.updateReadingComponentLayout(bookID: book.id, sourceHash: book.sourceHash, viewID: view.id,
            expectedRevision: ReadingComponentLayout.revision(view.composition!), layout: nil, markerAssets: ["map": ["校验":"measurement"]])
        XCTAssertEqual(result.project.documents, latest.documents); XCTAssertEqual(result.project.units, latest.units)
        XCTAssertEqual(result.project.views.count, 1); XCTAssertFalse(result.created)
        let body = try await repository.readDocument(bookID: book.id, document: note)
        XCTAssertEqual(body, "保留我的内容。")
        let loaded = try await repository.loadAll()
        XCTAssertEqual(loaded.first?.views, result.project.views)
    }
    func testSchemaOffersMaterialIDsButLeavesBookKindsOpen() throws {
        let schema = CompositionSchema.markerAssets
        XCTAssertNil(schema["properties"]); XCTAssertEqual(schema["maxProperties"] as? Int, 32)
        let values = try XCTUnwrap(schema["additionalProperties"] as? [String: Any])
        XCTAssertEqual(Set(values["enum"] as? [String] ?? []), Set(SpatialMarkerAssets.selectable.map(\.id)))
        XCTAssertTrue((values["enum"] as? [String] ?? []).contains("measurement"))
    }
}
