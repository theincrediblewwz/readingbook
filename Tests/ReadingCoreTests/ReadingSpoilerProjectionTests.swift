import Foundation
import XCTest
@testable import ReadingCore

final class ReadingSpoilerProjectionTests: XCTestCase {
    private func book() -> BookProject {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "开篇", text: "190年，神秘人与徐晃入营。"),
                     SourceUnit(id: "u2", order: 1, chapter: "后文", text: "200年，神秘人原来是曹操，另一人是许褚。")]
        var book = BookProject(title: "边界", originalName: "book.txt", sourceHash: "source", units: units)
        book.entities = [
            KnowledgeEntity(id: "hidden", typeID: "person", name: "曹操", summary: "曹操后来的结局。", properties: ["身份": "魏王"], aliases: ["神秘人"], latitude: 30, longitude: 110,
                evidence: [Evidence(unitID: "u1", quote: "神秘人"), Evidence(unitID: "u2", quote: "神秘人原来是曹操")]),
            KnowledgeEntity(id: "known", typeID: "person", name: "徐晃", evidence: [Evidence(unitID: "u1", quote: "徐晃")]),
            KnowledgeEntity(id: "future", typeID: "person", name: "许褚", evidence: [Evidence(unitID: "u2", quote: "许褚")])]
        return book
    }

    private func encoded(_ book: BookProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(book)
    }

    private func versionedBook() throws -> (early: BookProject, current: BookProject) {
        var early = book()
        early.units[0].text = "190年—191年，神秘人与徐晃入营。营在甲地。"
        early.units[1].text = "200年—201年，神秘人原来是曹操，另一人是许褚，曹操称王。"
        early.entities[0] = KnowledgeEntity(id: "hidden", typeID: "person", name: "神秘人", summary: "当时只知他入营。",
            properties: ["所见": "入营"], aliases: ["神秘人"], latitude: 30, longitude: 110, locationNote: "早期位置",
            evidence: [Evidence(unitID: "u1", quote: "神秘人")])
        early.entities.append(KnowledgeEntity(id: "camp", typeID: "place", name: "甲地", summary: "营地位置。",
            latitude: 31, longitude: 111, locationNote: "营在甲地", evidence: [Evidence(unitID: "u1", quote: "营在甲地")]))
        early.events = [KnowledgeEvent(id: "entry", name: "入营", summary: "两人在早期入营。", dateText: "190年—191年",
            startYear: 190, endYear: 191, placeIDs: ["camp", "missing"], participantIDs: ["hidden", "known", "future"],
            evidence: [Evidence(unitID: "u1", quote: early.units[0].text)])]
        var current = early
        current.entities[0].name = "曹操"; current.entities[0].summary = "后文才知其身份和结局。"
        current.entities[0].properties = ["身份": "魏王"]; current.entities[0].latitude = 40
        current.entities[0].longitude = 120; current.entities[0].locationNote = "后来的位置"
        current.entities[0].evidence.append(Evidence(unitID: "u2", quote: current.units[1].text))
        current.events[0].name = "曹操称王"; current.events[0].summary = "后文称王。"
        current.events[0].dateText = "200年—201年"; current.events[0].startYear = 200; current.events[0].endYear = 201
        current.events[0].placeIDs = ["camp"]
        current.events[0].evidence.append(Evidence(unitID: "u2", quote: current.units[1].text))
        try ReadingKnowledgeRuntime.captureVersions(before: early, in: &current)
        return (early, current)
    }

    private func fallbackEntity(in book: BookProject) -> KnowledgeEntity {
        var value = book.entities[0]
        value.name = "神秘人"; value.aliases = ["神秘人"]; value.summary = ""; value.properties = [:]
        value.latitude = nil; value.longitude = nil; value.locationNote = nil
        value.evidence = [Evidence(unitID: "u1", quote: "神秘人")]
        return value
    }

    private func fallbackEvent(in book: BookProject) -> KnowledgeEvent {
        var value = book.events[0]
        value.name = "本段关联事件"; value.summary = ""; value.dateText = "时间待考"
        value.startYear = nil; value.endYear = nil; value.placeIDs = []; value.participantIDs = []
        value.evidence = [Evidence(unitID: "u1", quote: book.units[0].text)]
        return value
    }

    func testCompleteCanonicalOutputsWinOverSavedVersionsAndUnboundedCallsRemainUnchanged() throws {
        let book = try versionedBook().current, before = try encoded(book)
        let bounded = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: ["u1", "u2"])
        XCTAssertEqual(bounded.entity(book.entities[0]), book.entities[0])
        XCTAssertEqual(bounded.event(book.events[0]), book.events[0])
        XCTAssertEqual(bounded.entitySnapshot(book.entities[0]), book.entities[0])
        XCTAssertEqual(bounded.eventSnapshot(book.events[0]), book.events[0])
        let unbounded = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: nil)
        var withoutEntityEvidence = book.entities[0]; withoutEntityEvidence.evidence = []
        var withoutEventEvidence = book.events[0]; withoutEventEvidence.evidence = []
        XCTAssertEqual(unbounded.entity(withoutEntityEvidence), withoutEntityEvidence)
        XCTAssertEqual(unbounded.event(withoutEventEvidence), withoutEventEvidence)
        XCTAssertEqual(try encoded(book), before)
    }

    func testSavedEntityAndEventKeepTheirWholeEarlierOutputsWithOnlyVisibleEndpoints() throws {
        let fixture = try versionedBook(), book = fixture.current, before = try encoded(fixture.current)
        let context = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: ["u1"])
        XCTAssertEqual(context.entity(book.entities[0]), fixture.early.entities[0])
        var expected = fixture.early.events[0]
        expected.placeIDs = ["camp"]; expected.participantIDs = ["hidden", "known"]
        XCTAssertEqual(context.event(book.events[0]), expected,
            "旧事件保留已验证的摘要、日期和两个年份，但不带入后文人物或不存在的地点。")
        XCTAssertEqual(try encoded(book), before, "早期只读投影不能改写版本或 canonical 数据。")
    }

    func testMissingSavedVersionsRetainTheCompleteRedactedCanonicalOutputs() throws {
        var book = try versionedBook().current
        book.readingKnowledge = nil
        let before = try encoded(book)
        let context = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: ["u1"])
        XCTAssertEqual(context.entity(book.entities[0]), fallbackEntity(in: book))
        XCTAssertEqual(context.event(book.events[0]), fallbackEvent(in: book))
        XCTAssertEqual(try encoded(book), before)
    }

    func testSnapshotCallsDoNotReplaceCanonicalWithAnAvailableSavedVersion() throws {
        let book = try versionedBook().current, before = try encoded(book)
        let context = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: ["u1"])
        XCTAssertEqual(context.entitySnapshot(book.entities[0]), fallbackEntity(in: book))
        XCTAssertEqual(context.eventSnapshot(book.events[0]), fallbackEvent(in: book))
        XCTAssertEqual(try encoded(book), before)
    }

    func testSavedEntityAndEventRejectChangedProvenanceAndNonliteralOrDisallowedEvidence() throws {
        let fixture = try versionedBook()
        let saved = try XCTUnwrap(fixture.current.readingKnowledge).versions.filter { $0.evidence.count == 1 }
        XCTAssertEqual(saved.count, 2, "夹具必须包含一个早期实体和一个早期事件版本。")
        for kind in ["sourceHash", "unitHash", "missingQuote", "missingUnit", "disallowedUnit", "unicodeQuote"] {
            var book = fixture.current, invalid = saved
            if kind == "unicodeQuote" {
                book.units[0].text += " Caf\u{00e9}。"
                book.events[0].evidence[0].quote = book.units[0].text
            }
            for index in invalid.indices {
                switch kind {
                case "sourceHash": invalid[index].sourceHash = "other-source"
                case "unitHash": invalid[index].unitHashes["u1"] = String(repeating: "0", count: 64)
                default:
                    let evidence: Evidence
                    if kind == "disallowedUnit" {
                        evidence = Evidence(unitID: "u2", quote: book.units[1].text)
                        invalid[index].unitHashes["u2"] = try BookImporter.sha256(Data(book.units[1].text.utf8))
                    } else if kind == "unicodeQuote" {
                        evidence = Evidence(unitID: "u1", quote: "Cafe\u{0301}")
                        invalid[index].unitHashes["u1"] = try BookImporter.sha256(Data(book.units[0].text.utf8))
                    } else {
                        evidence = Evidence(unitID: kind == "missingUnit" ? "missing" : "u1", quote: "原文中不存在的引文")
                    }
                    if invalid[index].entity != nil { invalid[index].entity?.evidence = [evidence] }
                    else { invalid[index].event?.evidence = [evidence] }
                }
            }
            book.readingKnowledge?.versions = invalid
            let before = try encoded(book)
            let context = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: ["u1"])
            XCTAssertEqual(context.entity(book.entities[0]), fallbackEntity(in: book), kind)
            XCTAssertEqual(context.event(book.events[0]), fallbackEvent(in: book), kind)
            XCTAssertEqual(try encoded(book), before, kind + " 只能拒绝旧版，不能删除或重写它。")
        }
    }

    func testUnicodeEquivalentEvidenceNeverCountsAsLiteralSourceOrRevivesSavedOutputs() throws {
        let nfc = "Caf\u{00e9}", nfd = "Cafe\u{0301}"
        XCTAssertEqual(nfc, nfd, "Swift 字符串相等不代表 UTF-8 原文字节相同。")
        XCTAssertNotEqual(Data(nfc.utf8), Data(nfd.utf8))
        var early = BookProject(title: "字节边界", originalName: "book.txt", sourceHash: "source",
            units: [SourceUnit(id: "u1", order: 0, chapter: "当前", text: nfc + " 在190年入营。")])
        early.entities = [KnowledgeEntity(id: "cafe", typeID: "place", name: nfc, summary: "旧地点说明。",
            properties: ["位置": "营地"], latitude: 30, longitude: 110, evidence: [Evidence(unitID: "u1", quote: nfc)])]
        early.events = [KnowledgeEvent(id: "entry", name: "入营", summary: "旧事件说明。", dateText: "190年", startYear: 190,
            placeIDs: ["cafe"], evidence: [Evidence(unitID: "u1", quote: early.units[0].text)])]
        var book = early
        book.entities[0].summary = "更新后的地点说明。"; book.events[0].summary = "更新后的事件说明。"
        book.entities[0].evidence = [Evidence(unitID: "u1", quote: nfd)]
        book.events[0].evidence = [Evidence(unitID: "u1", quote: nfd + " 在190年入营。")]
        try ReadingKnowledgeRuntime.captureVersions(before: early, in: &book)
        XCTAssertEqual(book.readingKnowledge?.versions.count, 2, "有效的早期版本仍存在，不能用来救活无当前原文证据的对象。")
        let before = try encoded(book)
        let context = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: ["u1"])
        XCTAssertNil(context.entity(book.entities[0])); XCTAssertNil(context.event(book.events[0]))
        XCTAssertNil(context.entitySnapshot(book.entities[0])); XCTAssertNil(context.eventSnapshot(book.events[0]))
        var changed = early
        changed.units[0].text = nfd + " 在190年入营。"
        let reverse = ReadingSpoilerProjection.Context(project: changed, allowedUnitIDs: ["u1"])
        XCTAssertNil(reverse.entity(changed.entities[0])); XCTAssertNil(reverse.event(changed.events[0]))
        XCTAssertEqual(try encoded(book), before)
    }

    func testSelectionWithRepeatedEvidenceOutsideItsSliceKeepsOnlyIdentityAndNoSavedProse() throws {
        let selected = "190年，徐晃入营。"
        var book = BookProject(title: "重复证据", originalName: "book.txt", sourceHash: "source",
            units: [SourceUnit(id: "u1", order: 0, chapter: "当前", text: selected + "此处无关。徐晃后来任将军。")])
        book.entities = [KnowledgeEntity(id: "xu", typeID: "person", name: "徐晃", summary: "后来任将军。",
            properties: ["官职": "将军"], aliases: ["徐晃"], latitude: 30, longitude: 110, locationNote: "后来的位置",
            evidence: [Evidence(unitID: "u1", quote: "徐晃")])]
        book.events = [KnowledgeEvent(id: "entry", name: "入营", summary: "混有后文的解释。", dateText: "190年", startYear: 190,
            participantIDs: ["xu"], evidence: [Evidence(unitID: "u1", quote: "徐晃")])]
        let before = try encoded(book)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: book,
            context: ReadingContext(unitID: "u1", selectedText: selected))
        let admitsSaved = try snapshot.savedEvidenceAdmitter(in: book)
        XCTAssertTrue(snapshot.admits(book.entities[0].evidence[0]))
        XCTAssertFalse(admitsSaved(book.entities[0].evidence[0]), "选段内的一次出现不能授权选段外的同字引文。")
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let projected = try XCTUnwrap(session.scopedKnowledgeProject())
        let expectedEntity = KnowledgeEntity(id: "xu", typeID: "person", name: "徐晃", aliases: ["徐晃"],
            evidence: [Evidence(unitID: "u1", quote: "徐晃")])
        let expectedEvent = KnowledgeEvent(id: "entry", name: "本段关联事件", evidence: [Evidence(unitID: "u1", quote: "徐晃")])
        XCTAssertEqual(projected.entities, [expectedEntity]); XCTAssertEqual(projected.events, [expectedEvent])
        XCTAssertNil(SavedKnowledgeReuse(project: book, currentUnitIDs: ["u1"], currentRanges: try snapshot.sourceRanges(in: book))?.entity(book.entities[0]))
        XCTAssertNil(SavedKnowledgeReuse(project: book, currentUnitIDs: ["u1"], currentRanges: try snapshot.sourceRanges(in: book))?.event(book.events[0]))
        XCTAssertEqual(try encoded(book), before)
    }

    func testEarlierReadingShowsOnlyLiteralAliasAndNeverFutureIdentityOrFields() throws {
        let book = book(), original = book.entities[0]
        let view = try XCTUnwrap(ReadingSpoilerProjection.entity(original, in: book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(view.id, original.id); XCTAssertEqual(view.name, "神秘人")
        XCTAssertFalse(view.aliases.contains("曹操")); XCTAssertEqual(view.summary, ""); XCTAssertTrue(view.properties.isEmpty)
        XCTAssertNil(view.latitude); XCTAssertNil(view.longitude)
        XCTAssertNil(ReadingSpoilerProjection.entity(book.entities[2], in: book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(book.entities[0], original, "只读投影不能改写完整本地卡片。")
        XCTAssertEqual(ReadingSpoilerProjection.entity(original, in: book, allowedUnitIDs: nil), original)
    }
    func testEventHidesFutureDateAndParticipantsAndRetainsVerbatimCurrentYear() throws {
        let book = book()
        let current = KnowledgeEvent(id: "entry", name: "入营", summary: "本地事件", dateText: "190年", startYear: 190,
            participantIDs: ["known", "future"], evidence: [Evidence(unitID: "u1", quote: book.units[0].text)])
        let view = try XCTUnwrap(ReadingSpoilerProjection.event(current, in: book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(view.name, "入营"); XCTAssertEqual(view.dateText, "190年"); XCTAssertEqual(view.startYear, 190)
        XCTAssertEqual(view.participantIDs, ["known"])
        var future = current; future.name = "曹操称王"; future.dateText = "200年"; future.startYear = 200
        future.evidence.append(Evidence(unitID: "u2", quote: book.units[1].text))
        let hidden = try XCTUnwrap(ReadingSpoilerProjection.event(future, in: book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(hidden.name, "本段关联事件"); XCTAssertEqual(hidden.dateText, "时间待考")
        XCTAssertNil(hidden.startYear); XCTAssertNil(hidden.endYear); XCTAssertTrue(hidden.participantIDs.isEmpty); XCTAssertTrue(hidden.summary.isEmpty)
        var unsupportedConversion = current; unsupportedConversion.dateText = "初平元年"
        XCTAssertNil(ReadingSpoilerProjection.event(unsupportedConversion, in: book, allowedUnitIDs: ["u1"])?.startYear)
    }

    func testOneContextKeepsEventDetailAndRelatedNamesInsideTheSameBoundary() throws {
        var book = book()
        book.entities.append(KnowledgeEntity(id: "camp", typeID: "place", name: "后文都城", summary: "后文才揭晓的地点。", aliases: ["营"],
            evidence: [Evidence(unitID: "u1", quote: "入营"), Evidence(unitID: "u2", quote: "200年")]))
        book.events = [KnowledgeEvent(id: "entry", name: "入营", summary: "人物进入营地。", dateText: "190年", startYear: 190,
            placeIDs: ["camp"], participantIDs: ["hidden", "known", "future"], evidence: [Evidence(unitID: "u1", quote: book.units[0].text)])]
        book.documents = [DocumentRecord(id: "my-note", title: "我主动保存的笔记", linkedIDs: ["hidden"])]
        let originals = book.entities, notes = book.documents
        let context = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: ["u1"])
        let event = try XCTUnwrap(context.event(book.events[0]))
        let related = Set(event.placeIDs + event.participantIDs)
        let names = book.entities.filter { related.contains($0.id) }.compactMap { context.entity($0)?.name }
        XCTAssertEqual(Set(names), ["营", "神秘人", "徐晃"])
        XCTAssertFalse(names.contains("曹操")); XCTAssertFalse(names.contains("许褚")); XCTAssertFalse(names.contains("后文都城"))
        XCTAssertEqual(context.entity(book.entities[0])?.summary, "")
        XCTAssertTrue(context.entity(book.entities[0])?.properties.isEmpty == true)
        XCTAssertEqual(book.entities, originals); XCTAssertEqual(book.documents, notes, "派生详情不改变用户主动保存的笔记路径。")
        let open = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: nil)
        XCTAssertEqual(open.event(book.events[0]), book.events[0])
        XCTAssertEqual(open.entity(book.entities[0])?.name, "曹操")
    }
    func testQueryAndEmbeddedCompositionProjectionDoNotRestoreHiddenCanonicalValues() throws {
        var book = book()
        book.events = [KnowledgeEvent(id: "event", name: "曹操称王", summary: "曹操后来称王。", dateText: "200年", startYear: 200,
            participantIDs: ["hidden", "future"], evidence: [Evidence(unitID: "u1", quote: book.units[0].text)])]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: ReadingContext(unitID: "u1", selectedText: book.units[0].text))
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let projected = try XCTUnwrap(session.scopedKnowledgeProject())
        XCTAssertEqual(projected.entities.first(where: { $0.id == "hidden" })?.name, "神秘人")
        XCTAssertEqual(projected.events.first?.name, "本段关联事件"); XCTAssertNil(projected.events.first?.startYear)
        XCTAssertEqual(projected.events.first?.summary, "", "不能从摘要把被隐藏的事件身份重新带回。")
        XCTAssertEqual(projected.events.first?.dateText, "时间待考"); XCTAssertFalse(projected.events.first?.participantIDs.contains("future") == true)
    }
}
