import Foundation
import XCTest
@testable import ReadingCore

final class ReadingSentenceAnchorsTests: XCTestCase {
    private func book(_ text: String) -> BookProject {
        BookProject(title: "句旁阅读", originalName: "source.pdf", sourceHash: "original-source",
            units: [SourceUnit(id: "u1", order: 0, chapter: "开篇", page: 1, text: text)])
    }
    func testChineseEnglishAndDecimalBoundariesPreserveOriginalUnicode() throws {
        let text = "  贾诩说：“再想一想。”😀接着走。 The value is 3.14. Why?\n\n末段没有句号"
        let values = ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(values, ["贾诩说：“再想一想。”", "😀接着走。", "The value is 3.14.", "Why?", "末段没有句号"])
        for range in ReadingSentenceAnchors.ranges(in: text) { XCTAssertNotNil(Range(range, in: text)) }
    }
    func testRepeatedSentencesHaveStableDifferentPositionsAndDoNotSaveAnalysis() throws {
        let project = book("甲地，贾诩入城。乙地，贾诩入城。")
        let anchors = ReadingSentenceAnchors.anchors(in: project.units[0], project: project)
        XCTAssertEqual(anchors.count, 2)
        XCTAssertNotEqual(anchors[0].id, anchors[1].id)
        XCTAssertEqual(anchors, ReadingSentenceAnchors.anchors(in: project.units[0], project: project))
        for anchor in anchors { XCTAssertEqual(try ReadingExperienceRuntime.resolve(anchor, in: project).unitID, "u1") }
        XCTAssertNil(project.readingExperience, "句界只是派生交互，不得伪造已保存译文或覆盖。")
    }
    func testMathAndCodeAreNotSplitAtTheirInternalPunctuation() throws {
        let text = "数值 $x!+3.14$ 很重要。\n\n```swift\nprint(\"what?\")\n```\n结束。"
        let values = ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(values.first, "数值 $x!+3.14$ 很重要。")
        XCTAssertEqual(values.last, "```swift\nprint(\"what?\")\n```\n结束。")
        let display = "等式 $$x! + 3.14$$ 保留。调用 `f?()` 完成。价格$5。下一句。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: display).map { (display as NSString).substring(with: $0) },
            ["等式 $$x! + 3.14$$ 保留。", "调用 `f?()` 完成。", "价格$5。", "下一句。"])
    }
    func testLongPageRangesAreExactAndCombiningBytesDoNotNormalize() throws {
        let text = (0..<700).map { "第\($0)句前😀e\u{301}后。" }.joined()
        let project = book(text)
        let values = ReadingSentenceAnchors.anchors(in: project.units[0], project: project, maximum: 4)
        XCTAssertEqual(values.count, 4)
        for anchor in values {
            let resolved = try ReadingExperienceRuntime.resolve(anchor, in: project)
            XCTAssertTrue((text as NSString).substring(with: resolved.range).utf8.elementsEqual(anchor.quote.utf8))
            // String.contains compares canonically equivalent Characters, so
            // it cannot test whether the original decomposed bytes survived.
            XCTAssertTrue(anchor.quote.unicodeScalars.contains { $0.value == 0x301 })
            XCTAssertFalse(anchor.quote.unicodeScalars.contains { $0.value == 0xE9 })
            var normalized = anchor
            normalized.quote = anchor.quote.precomposedStringWithCanonicalMapping
            XCTAssertThrowsError(try ReadingExperienceRuntime.resolve(normalized, in: project), "规范等价的替换仍不是原文字节。")
        }
    }
    func testVisiblePagesWinBeforeNeighborsAndWorkIsBounded() {
        let pages = Set(1...1484)
        XCTAssertEqual(ReadingSentenceAnchors.pageWindow(current: 740, visible: [739, 740, 741], available: pages, maximum: 5), [740, 739, 741, 738, 742])
        XCTAssertEqual(ReadingSentenceAnchors.pageWindow(current: 1, visible: [-1, 0, 1, 1, 1485], available: pages), [1, 2])
        let bounded = ReadingSentenceAnchors.pageWindow(current: 700, visible: Array(1...1484), available: pages)
        XCTAssertEqual(bounded.count, 12)
        XCTAssertEqual(bounded.first, 700)
    }
}
