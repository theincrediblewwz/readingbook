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
    func testChapterHeadingAndItsCoupletStopBeforeTheFirstBodySentence() throws {
        let title = "第三十八回\n定三分隆中决策\n战长江孙氏报仇"
        let text = title + "\n却说玄德三顾茅庐。下一句不应进入标题。"
        var project = book(text); project.units[0].chapter = "第三十八回"
        let anchors = ReadingSentenceAnchors.anchors(in: project.units[0], project: project)
        XCTAssertEqual(anchors.map(\.quote), [title, "却说玄德三顾茅庐。", "下一句不应进入标题。"])
        let index = ReadingSentenceAnchors.boundaryIndex(in: text, chapterTitle: project.units[0].chapter)
        for anchor in anchors {
            XCTAssertFalse(index.crossesStructuralBoundary(try ReadingExperienceRuntime.resolve(anchor, in: project).range))
        }
        XCTAssertTrue(index.crossesStructuralBoundary(NSRange(location: 0, length: ((title + "\n却说玄德三顾茅庐。") as NSString).length)))
    }
    func testTraditionalNumericAndEnglishHeadingsKeepCRLFOffsets() throws {
        for title in ["第38回\r\n定三分隆中決策\r\n戰長江孫氏報仇", "第十九回 下邳城曹操鏖兵 白門樓呂布殞命", "CHAPTER IV. A New Beginning", "Chapter 1."] {
            let text = "\r\n" + title + "\r\n這是開篇第一句。"
            let values = ReadingSentenceAnchors.ranges(in: text)
            XCTAssertEqual(values.map { (text as NSString).substring(with: $0) }, [title, "這是開篇第一句。"])
            for value in values { XCTAssertNotNil(Range(value, in: text)) }
        }
    }
    func testTitleAndOrdinaryPDFSoftLineBreaksAreDifferentBoundaries() {
        let text = "第38回 定三分隆中决策 战长江孙氏报仇\n贾诩来到\n城中，继续说话。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) },
            ["第38回 定三分隆中决策 战长江孙氏报仇", "贾诩来到\n城中，继续说话。"])
        let titled = "第38回 定三分隆中决策\n玄德闻言大喜道\n这才是正文后半句。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: titled).map { (titled as NSString).substring(with: $0) },
            ["第38回 定三分隆中决策", "玄德闻言大喜道\n这才是正文后半句。"])
        let ordinary = "书名在这一页出现\n但这还是同一句正文。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: ordinary, chapterTitle: "书名").map { (ordinary as NSString).substring(with: $0) }, [ordinary])
        let opening = "第38回\n却说玄德听罢言\n便即引众来相见\n这还是第一句。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: opening).map { (opening as NSString).substring(with: $0) },
            ["第38回", "却说玄德听罢言\n便即引众来相见\n这还是第一句。"])
    }
    func testMarkdownAndExactImportedTitleHaveStructuralBoundaries() {
        for title in ["# 开篇", "开篇\n====", "开篇\n----"] {
            let text = title + "\n正文没有空行，仍要单独成句。"
            XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) }, [title, "正文没有空行，仍要单独成句。"])
        }
        let extracted = "\n另一个标题\n正文第一句。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: extracted, chapterTitle: "另一个标题").map { (extracted as NSString).substring(with: $0) }, ["另一个标题", "正文第一句。"])
    }
    func testHeadingLookingLinesInsideCodeAndMathDoNotBecomeStructuralTitles() {
        for text in ["```text\n第三十八回\n定三分隆中决策\n战长江孙氏报仇\n```", "```\n----\n第三十八回\n```", "~~~text\r\n第38回\r\n~~~", "````\n```\n第38回\n````", "$$\nChapter 1\nx!\n$$", "式子 $$\n----\nChapter 1\n$$", "\\[\r\nChapter 1\r\nx?\r\n\\]", "式子 \\(\n第38回\nx!\n\\) 保留。"] {
            let index = ReadingSentenceAnchors.boundaryIndex(in: text)
            XCTAssertFalse(index.crossesStructuralBoundary(NSRange(location: 0, length: (text as NSString).length)))
            XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) }, [text])
        }
    }
    func testBookNameContentsAndQuotedCRLFProseKeepHonestBoundaries() {
        let text = "三国演义\r\n第38回\r\n定三分隆中决策\r\n战长江孙氏报仇\r\n“玄德说，\r\n我还想再问一句。”下一句。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text, chapterTitle: "三国演义").map { (text as NSString).substring(with: $0) },
            ["三国演义", "第38回\r\n定三分隆中决策\r\n战长江孙氏报仇", "“玄德说，\r\n我还想再问一句。”", "下一句。"])
        let contents = "目录\n第一百二十回\n第一百二十一回\n第一百二十二回"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: contents, chapterTitle: "目录").map { (contents as NSString).substring(with: $0) },
            ["目录", "第一百二十回", "第一百二十一回", "第一百二十二回"])
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
