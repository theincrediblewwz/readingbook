import Foundation
import XCTest
@testable import ReadingCore

final class ReadingCompanionPresentationTests: XCTestCase {
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
