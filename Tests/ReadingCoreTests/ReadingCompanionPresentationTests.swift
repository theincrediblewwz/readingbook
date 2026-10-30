import Foundation
import XCTest
@testable import ReadingCore

final class ReadingCompanionPresentationTests: XCTestCase {
    func testSourcePresentationPreservesLiveIndexPriorityOrderAndMissingFallbacks() throws {
        let unit = SourceUnit(id: "unit", order: 0, chapter: "一", page: 3, text: "原文")
        let indexed = SourceAnchor(id: "a", sourceHash: "s", unitID: "unit", quote: "索引原句")
        var stored = indexed; stored.quote = "持久化旧句"
        let missing = SourceAnchor(id: "missing-unit", sourceHash: "s", unitID: "absent", quote: "旧原句")
        let result = ReadingCompanionPresentation.sources(["missing-unit", "a", "absent", "a"],
            indexedAnchors: [indexed], storedAnchors: [stored, missing], units: [unit])
        XCTAssertEqual(result.map(\.id), ["missing-unit", "a"])
        XCTAssertEqual(result.map(\.quote), ["旧原句", "索引原句"])
        XCTAssertEqual(result.map(\.locator), ["原文片段", unit.locator])
        XCTAssertTrue(ReadingCompanionPresentation.sources([], indexedAnchors: [indexed], storedAnchors: [stored], units: [unit]).isEmpty)
    }

    func testManySourcePresentationRetainsFirstAnchorAndUnitWithoutChangingInputBytes() throws {
        let units = (0..<200).map { SourceUnit(id: "u\($0)", order: $0, chapter: "章", page: $0+1, text: "原文 e\u{301} 😀") }
        let anchors = (0..<150).map { SourceAnchor(id: "a\($0)", sourceHash: "s", unitID: "u\($0)", quote: "第\($0)处 e\u{301}") }
        var duplicate = anchors[12]; duplicate.quote = "不得覆盖首个同ID锚点"
        var duplicateUnit = units[12]; duplicateUnit.page = 999
        let indexed = Array(anchors.prefix(75)) + [duplicate]
        let stored = [duplicate] + Array(anchors.suffix(100))
        let allUnits = units + [duplicateUnit]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(indexed) + encoder.encode(stored) + encoder.encode(allUnits)
        for count in [1, 8, 32, 64, 65, 128, 150] {
            let ids = (0..<count).reversed().map { "a\($0)" } + ["absent", "a12"]
            var seen: Set<String> = []
            let expected = ids.compactMap { id -> ReadingCompanionSource? in
                guard seen.insert(id).inserted, let anchor = indexed.first(where: { $0.id == id }) ?? stored.first(where: { $0.id == id }) else { return nil }
                return ReadingCompanionSource(id: anchor.id, quote: anchor.quote, locator: allUnits.first(where: { $0.id == anchor.unitID })?.locator ?? "原文片段")
            }
            let actual = ReadingCompanionPresentation.sources(ids, indexedAnchors: indexed, storedAnchors: stored, units: allUnits)
            XCTAssertEqual(sourceBytes(actual), sourceBytes(expected), "\(count)处原文的顺序、完整引文和位置必须保持。")
        }
        XCTAssertEqual(try encoder.encode(indexed) + encoder.encode(stored) + encoder.encode(allUnits), before)
    }

    func testManySourcePresentationKeepsExactUTF8OfCanonicalEquivalentIDsAndQuotes() {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let unit = SourceUnit(id: decomposed, order: 0, chapter: "原始 e\u{301}", text: "原句")
        let first = SourceAnchor(id: decomposed, sourceHash: "s", unitID: composed, quote: "原始 e\u{301} 😀")
        var duplicate = first; duplicate.id = composed; duplicate.quote = "不应覆盖"
        let more = (0..<80).map { SourceAnchor(id: "a\($0)", sourceHash: "s", unitID: decomposed, quote: "\($0)") }
        let ids = [composed, decomposed] + more.reversed().map(\.id)
        let result = ReadingCompanionPresentation.sources(ids, indexedAnchors: [first, duplicate] + more, storedAnchors: [duplicate], units: [unit])
        XCTAssertEqual(result.count, 81)
        XCTAssertEqual(Data(result[0].id.utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(result[0].quote.utf8), Data(first.quote.utf8))
        XCTAssertEqual(Data(result[0].locator.utf8), Data(unit.locator.utf8))
        XCTAssertEqual(result.dropFirst().map(\.id), more.reversed().map(\.id))
    }

    private func sourceBytes(_ values: [ReadingCompanionSource]) -> [[Data]] {
        values.map { [Data($0.id.utf8), Data($0.quote.utf8), Data($0.locator.utf8)] }
    }

    func testNewestStoredAnswerLeadsWithoutSortingArbitraryIDsOrEditingRecords() {
        let old = layer("z-old", anchors: ["a"])
        let middle = layer("m-middle", anchors: ["b"])
        let translation = layer("a-newest", kind: "translation", anchors: ["b"])
        let stored = [old, middle, translation]
        let plan = ReadingCompanionPresentation.layers(stored)
        XCTAssertEqual(plan.primaryID, translation.id)
        XCTAssertEqual(plan.orderedIDs, [translation.id, middle.id, old.id])
        XCTAssertEqual(plan.historyIDs, [middle.id, old.id])
        XCTAssertEqual(stored, [old, middle, translation], "展示排序不能重写原来的记录或生成时间。")
    }

    func testFocusedSentenceKeepsItsNewestExactExplanationAheadOfUnrelatedNewerAnswers() {
        let previous = layer("old-exact", anchors: ["focus"])
        let current = layer("new-exact", anchors: ["focus"])
        let other = layer("other-page", anchors: ["other"])
        let translation = layer("translation", kind: "translation", anchors: ["focus"])
        let broad = layer("broad", anchors: ["focus", "other"])
        let plan = ReadingCompanionPresentation.layers([previous, current, other, translation, broad], focusedAnchorID: "focus")
        XCTAssertEqual(plan.primaryID, current.id)
        XCTAssertEqual(plan.historyIDs, [broad.id, translation.id, other.id, previous.id])
    }

    func testBroadOrForeignExplanationCannotBecomeFocusedSentenceCore() {
        let stored = [layer("whole-page", anchors: ["paragraph"]), layer("two-quotes", anchors: ["sentence", "other"])]
        let plan = ReadingCompanionPresentation.layers(stored, focusedAnchorID: "sentence")
        XCTAssertNil(plan.primaryID)
        XCTAssertEqual(plan.historyIDs, ["two-quotes", "whole-page"])
        XCTAssertEqual(ReadingCompanionPresentation.layers([], focusedAnchorID: "sentence"), .init())
    }

    func testAlignmentHistoryIsNewestFirstButFocusStillChoosesItsRelevantRecord() {
        let first = ReferenceAlignment(id: "old", sourceAnchorIDs: ["a", "b"], title: "旧对读", markdown: "旧")
        let second = ReferenceAlignment(id: "new", sourceAnchorIDs: ["c", "d"], title: "新对读", markdown: "新")
        let latest = ReadingCompanionPresentation.alignments([first, second])
        XCTAssertEqual(latest.primaryID, second.id)
        XCTAssertEqual(latest.historyIDs, [first.id])
        let focused = ReadingCompanionPresentation.alignments([first, second], focusedAnchorID: "a")
        XCTAssertEqual(focused.primaryID, first.id)
        XCTAssertEqual(focused.historyIDs, [second.id])
        XCTAssertNil(ReadingCompanionPresentation.alignments([first, second], focusedAnchorID: "missing").primaryID)
    }

    func testGenerationReviewDoesNotWarnForOnlyIndexedSourceOrAnotherPage() throws {
        var book = project()
        let here = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "one", quote: "甲句。", in: book)
        let elsewhere = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "two", quote: "乙句。", in: book)
        book.readingExperience = ReadingExperienceState(anchors: [here, elsewhere])
        XCTAssertFalse(ReadingCompanionGenerationReview(project: book, unitIDs: ["one"]).requiresConfirmation,
                       "仅仅读取或索引原句不能使首次生成多一次确认。")
        book.readingExperience?.layers.append(layer("elsewhere", anchors: [elsewhere.id]))
        XCTAssertFalse(ReadingCompanionGenerationReview(project: book, unitIDs: ["one"]).requiresConfirmation)
        book.readingExperience?.layers.append(layer("existing", anchors: [here.id]))
        let before = book.readingExperience
        XCTAssertTrue(ReadingCompanionGenerationReview(project: book, unitIDs: ["one"]).requiresConfirmation)
        XCTAssertEqual(book.readingExperience, before, "确认检查不移除或改写已有AI内容。")
    }

    func testGenerationReviewIncludesExistingScopedObjectsAndProjectedReferences() {
        var book = project()
        book.entities = [KnowledgeEntity(id: "person", typeID: "person", name: "甲", evidence: [Evidence(unitID: "one", quote: "甲句。")])]
        XCTAssertTrue(ReadingCompanionGenerationReview(project: book, unitIDs: ["one"]).requiresConfirmation)
        XCTAssertFalse(ReadingCompanionGenerationReview(project: book, unitIDs: ["two"]).requiresConfirmation)
        let alignment = ReferenceAlignment(sourceAnchorIDs: ["a", "b"], title: "对读", markdown: "内容")
        XCTAssertTrue(ReadingCompanionGenerationReview(items: ReadingContextItems(alignments: [alignment])).requiresConfirmation)
        XCTAssertFalse(ReadingCompanionGenerationReview(items: ReadingContextItems()).requiresConfirmation)
    }

    private func layer(_ id: String, kind: String = "explanation", anchors: [String]) -> ReadingLayer {
        ReadingLayer(id: id, kind: kind, title: id, markdown: "已保存内容：" + id, sourceAnchorIDs: anchors)
    }
    private func project() -> BookProject {
        BookProject(title: "伴读记录测试", originalName: "source.pdf", sourceHash: "source", units: [
            SourceUnit(id: "one", order: 0, chapter: "甲", page: 1, text: "甲句。"),
            SourceUnit(id: "two", order: 1, chapter: "乙", page: 2, text: "乙句。")
        ])
    }
}
