import Foundation
import XCTest
@testable import ReadingCore

final class ReadingAtlasTests: XCTestCase {
    private func project() -> BookProject {
        BookProject(title: "阅读总览", originalName: "source.txt", sourceHash: "atlas", units: [
            SourceUnit(id: "u1", order: 0, chapter: "甲章😀", text: "甲段。\n\n乙段。"),
            SourceUnit(id: "u2", order: 1, chapter: "甲章😀", text: "丙段。"),
            SourceUnit(id: "u3", order: 2, chapter: "乙章", text: "其他原文。")
        ])
    }

    func testTranslationCoverageUnionsExactRangesAndSeparatesReceiptsFromOldCompletion() throws {
        var book = project()
        var complete = CoverageEntry(); complete.status = .completed; book.coverage["u1"] = complete
        let first = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "甲段。", in: book)
        let second = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "乙段。", in: book)
        let layer = ReadingLayer(id: "first", kind: "translation", title: "译文", markdown: "甲段译文", sourceAnchorIDs: [first.id])
        book.readingExperience = ReadingExperienceState(anchors: [first, second], layers: [layer])
        let partial = ReadingAtlasRuntime.build(book).chapters[0]
        XCTAssertEqual(partial.title, "甲章😀"); XCTAssertEqual(partial.unitIDs, ["u1", "u2"])
        XCTAssertEqual(partial.completedUnits, 1); XCTAssertEqual(partial.receiptUnits, 0)
        XCTAssertEqual(partial.translationTouchedUnits, 1); XCTAssertEqual(partial.translatedUnits, 0)
        book.readingExperience?.layers.append(ReadingLayer(id: "second", kind: "translation", title: "乙段译文", markdown: "乙段译文", sourceAnchorIDs: [second.id]))
        // Overlapping duplicate sources must not count as additional translated units.
        book.readingExperience?.layers.append(ReadingLayer(id: "overlap", kind: "translation", title: "重叠译文", markdown: "重叠", sourceAnchorIDs: [first.id]))
        let paragraphs = try ReadingLedger.paragraphs(for: book.units[0], in: book)
        book.paragraphReceipts = paragraphs.map { p in
            ParagraphReceipt(paragraphID: p.id, unitID: p.unitID, unitHash: p.unitHash, textHash: p.textHash, utf8Start: p.utf8Start, utf8End: p.utf8End, summary: "实际段落回执", startQuote: p.startQuote, endQuote: p.endQuote, issues: [], createdAt: Date())
        }
        let covered = ReadingAtlasRuntime.build(book).chapters[0]
        XCTAssertEqual(covered.translatedUnits, 1); XCTAssertEqual(covered.translationRatio, 0.5)
        XCTAssertEqual(covered.receiptUnits, 1)
        book.units[0].text += "修订"
        let changed = ReadingAtlasRuntime.build(book).chapters[0]
        XCTAssertEqual(changed.translatedUnits, 0); XCTAssertEqual(changed.receiptUnits, 0)
    }

    func testCooccurrenceRequiresValidSharedEvidenceAndNeverConvertsRelationsIntoCounts() {
        var book = project()
        let u1 = Evidence(unitID: "u1", quote: "甲段。"), u2 = Evidence(unitID: "u2", quote: "丙段。")
        book.entities = [
            KnowledgeEntity(id: "a", typeID: "concept", name: "概念😀", evidence: [u1, u1, u2]),
            KnowledgeEntity(id: "b", typeID: "person", name: "人名", evidence: [u2, u1]),
            KnowledgeEntity(id: "c", typeID: "concept", name: "无效引用", evidence: [Evidence(unitID: "u1", quote: "不存在"), Evidence(unitID: "missing", quote: "甲段。")])
        ]
        book.relations = [KnowledgeRelation(id: "not-cooccurrence", fromID: "a", toID: "c", label: "依赖", evidence: [u1])]
        let snapshot = ReadingAtlasRuntime.build(book)
        XCTAssertEqual(snapshot.cooccurrences.count, 1)
        XCTAssertEqual(snapshot.cooccurrences[0].fromID, "a"); XCTAssertEqual(snapshot.cooccurrences[0].toID, "b")
        XCTAssertEqual(snapshot.cooccurrences[0].unitIDs, ["u1", "u2"])
        XCTAssertEqual(snapshot.cooccurrences[0].count, 2)
        XCTAssertEqual(snapshot.invalidEvidenceCount, 2)
        XCTAssertEqual(snapshot.typeCounts.first?.count, 2, "类型计数是保存对象数，与有效共现引文数不同。")
    }

    func testYearDensityIsBoundedHandlesNegativeAndExtremeYearsAndExcludesUndated() {
        var book = project()
        let evidence = [Evidence(unitID: "u1", quote: "甲段。")]
        book.events = (0..<60).map { index in KnowledgeEvent(id: "event-\(index)", name: "事件", startYear: index * 100 - 3_000, endYear: index * 100 + 4_000, evidence: evidence) }
        book.events.append(KnowledgeEvent(id: "minimum", name: "极小年", startYear: Int.min, evidence: evidence))
        book.events.append(KnowledgeEvent(id: "maximum", name: "极大年", startYear: Int.max, evidence: evidence))
        book.events.append(KnowledgeEvent(id: "undated", name: "待考", evidence: evidence))
        book.events.append(KnowledgeEvent(id: "bad-evidence", name: "排除", startYear: 200, evidence: [Evidence(unitID: "u1", quote: "并非原句")]))
        let snapshot = ReadingAtlasRuntime.build(book)
        XCTAssertLessThanOrEqual(snapshot.yearBuckets.count, 24)
        XCTAssertEqual(snapshot.yearBuckets.reduce(0) { $0 + $1.count }, 62, "跨年事件只按起年计一次，未系年不填成年份0。")
        XCTAssertEqual(snapshot.yearBuckets.first?.start, Int.min); XCTAssertEqual(snapshot.yearBuckets.last?.end, Int.max)
        XCTAssertEqual(snapshot.undatedEventIDs, ["undated"])
        XCTAssertEqual(snapshot.invalidEvidenceCount, 1)
    }

    func testSamplingBoundsAndOrderingAreExplicitAndStable() {
        var book = project()
        book.entities = (0..<129).map { KnowledgeEntity(id: String(format: "entity-%03d", $0), typeID: "concept", name: "名称\($0)", evidence: [Evidence(unitID: "u1", quote: "甲段。")]) }
        let first = ReadingAtlasRuntime.build(book)
        XCTAssertEqual(first.cooccurrences.count, 40); XCTAssertTrue(first.cooccurrencesBounded)
        book.entities.reverse(); book.units.reverse()
        let second = ReadingAtlasRuntime.build(book)
        XCTAssertEqual(first, second, "存储数组顺序不能改变相同数据的总览和共现样本。")
        XCTAssertEqual(first.cooccurrences.first?.fromID, "entity-000")
        XCTAssertEqual(first.cooccurrences.first?.toID, "entity-001")
    }

    func testRepeatedPairUnitContributionsHaveATotalBudget() {
        var book = project()
        book.units = (0..<30).map { SourceUnit(id: "page-\($0)", order: $0, chapter: "密集章节", text: "共同原文。") }
        let evidence = book.units.map { Evidence(unitID: $0.id, quote: "共同原文。") }
        book.entities = (0..<128).map { KnowledgeEntity(id: String(format: "entity-%03d", $0), typeID: "concept", name: "对象\($0)", evidence: evidence) }
        let snapshot = ReadingAtlasRuntime.build(book)
        XCTAssertTrue(snapshot.cooccurrencesBounded)
        XCTAssertEqual(snapshot.cooccurrences.count, 40)
        XCTAssertEqual(snapshot.cooccurrences.first?.count, 25, "200k总组合预算应在第25单元内停止，而不是同一pair继续累积30个单元。")
    }
}
