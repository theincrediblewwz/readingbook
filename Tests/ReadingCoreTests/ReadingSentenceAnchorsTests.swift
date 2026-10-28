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
    func testCodeSpansUseEqualLengthRunsWithoutSwallowingUnmatchedOrEscapedTicks() {
        let protected = [
            "调用 ``f?()`` 完成。",
            "调用 ``f`?()`` 完成。",
            "调用 ```f``?()` ``` 完成。",
            "调用 ``😀f?()\r\n第38回\r\nx!`` 完成。",
            "调用 `f?\\` 完成。", // Inside code, a backslash does not escape its closing tick.
            "调用 \\\\`f?()` 完成。", // An escaped backslash does not escape the following tick.
            "调用 \\``f?()` 完成。", // Only the first tick was escaped; the remaining one opens code.
            "调用 `f?\\``x!` 完成。"
        ]
        for first in protected {
            let text = first + "下一句。"
            XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) }, [first, "下一句。"], first)
            XCTAssertFalse(ReadingSentenceAnchors.boundaryIndex(in: first).crossesStructuralBoundary(NSRange(location: 0, length: (first as NSString).length)), first)
        }
        let literalCases: [(String, [String])] = [
            ("调用 \\`f?()\\` 完成。下一句。", ["调用 \\`f?", "()\\` 完成。", "下一句。"]),
            ("未闭合 `字。下一句。", ["未闭合 `字。", "下一句。"]),
            ("未闭合 ``字?`。下一句。", ["未闭合 ``字?", "`。", "下一句。"]),
            ("未闭合 `字。\n \t\n第二段`继续。", ["未闭合 `字。", "第二段`继续。"]),
            ("未闭合 `字。\n~~~txt\n第二段`?\n~~~\n结束。", ["未闭合 `字。", "~~~txt\n第二段`?\n~~~\n结束。"])
        ]
        for (text, expected) in literalCases {
            XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) }, expected, text)
            for range in ReadingSentenceAnchors.ranges(in: text) { XCTAssertNotNil(Range(range, in: text)) }
        }
        // Escaped longer runs inside code must not shadow its real opener in
        // the precomputed next-delimiter index.
        let first = "调用 `" + String(repeating: "\\``? ", count: 1000) + "` 完成。"
        let text = first + "下一句。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text, maximumUTF16Length: (text as NSString).length + 1).map { (text as NSString).substring(with: $0) }, [first, "下一句。"])
    }
    func testWhitespaceBlankLinesAndATXBlocksDoNotJoinIndependentSentences() {
        for newline in ["\n", "\r\n", "\u{2028}"] {
            let text = "前段尚无标点" + newline + " \t " + newline + "后段才结束。"
            XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) }, ["前段尚无标点", "后段才结束。"])
            let soft = "原文同一句" + newline + "依然没有换段。"
            XCTAssertEqual(ReadingSentenceAnchors.ranges(in: soft).map { (soft as NSString).substring(with: $0) }, [soft])
        }
        let text = "未闭合 `字。\n# 标题\n第二段`继续。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text).map { (text as NSString).substring(with: $0) }, ["未闭合 `字。", "# 标题", "第二段`继续。"])
        let heading = "# 标题 `未闭合\n第二段`继续。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: heading).map { (heading as NSString).substring(with: $0) }, ["# 标题 `未闭合", "第二段`继续。"])
        // Four-space indentation cannot interrupt an existing paragraph as
        // an ATX block; its code span still crosses this ordinary soft wrap.
        let continuation = "调用 `前半?\n    # 后半!`完成。下一句。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: continuation).map { (continuation as NSString).substring(with: $0) }, ["调用 `前半?\n    # 后半!`完成。", "下一句。"])
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
    func testEverySentenceOfAValidDenseUnitIncludingItsTailIsRepresented() throws {
        // A legal source unit holds up to 5,000 Characters. The former 2,000
        // range prefix silently discarded this unit's final sentence.
        let sentences = (0..<2001).map { String(UnicodeScalar(0x4E00 + $0)!) + "。" }
        let project = book(sentences.joined())
        XCTAssertLessThanOrEqual(project.units[0].text.count, 5_000)
        let anchors = ReadingSentenceAnchors.anchors(in: project.units[0], project: project)
        XCTAssertEqual(anchors.count, sentences.count)
        let last = try XCTUnwrap(anchors.last)
        XCTAssertEqual(last.quote, sentences.last)
        XCTAssertEqual(NSMaxRange(try ReadingExperienceRuntime.resolve(last, in: project).range), project.units[0].text.utf16.count)
        XCTAssertEqual(ReadingSentenceAnchors.anchors(in: project.units[0], project: project, maximum: 3).count, 3)
    }
    func testVisiblePagesWinBeforeNeighborsAndWorkIsBounded() {
        let pages = Set(1...1484)
        XCTAssertEqual(ReadingSentenceAnchors.pageWindow(current: 740, visible: [739, 740, 741], available: pages, maximum: 5), [740, 739, 741, 738, 742])
        XCTAssertEqual(ReadingSentenceAnchors.pageWindow(current: 1, visible: [-1, 0, 1, 1, 1485], available: pages), [1, 2])
        let bounded = ReadingSentenceAnchors.pageWindow(current: 700, visible: Array(1...1484), available: pages)
        XCTAssertEqual(bounded.count, 12)
        XCTAssertEqual(bounded.first, 700)
    }
    func testHardStructureCutsKeepAnchorsExactAndRejectOldMixedPassagesWithoutDeletingThem() throws {
        let text = "横排大字本\n😀e\u{301}玄德来到\n城中。末句尚未结束\n471"
        var project = book(text)
        let old = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1",
            quote: "横排大字本\n😀e\u{301}玄德来到\n城中。", in: project)
        project.readingExperience = ReadingExperienceState(anchors: [old])
        let originalBytes = Data(project.units[0].text.utf8)
        let cuts = PDFReadingStructure.boundaries(in: text, peers: ["横排大字本\n前页正文。", "横排大字本\n后页正文。"])
        let anchors = ReadingSentenceAnchors.anchors(in: project.units[0], project: project, structuralBreaks: cuts)
        XCTAssertEqual(anchors.map(\.quote), ["横排大字本", "😀e\u{301}玄德来到\n城中。", "末句尚未结束", "471"])
        let index = ReadingSentenceAnchors.boundaryIndex(in: text, structuralBreaks: cuts)
        XCTAssertTrue(index.crossesStructuralBoundary(try ReadingExperienceRuntime.resolve(old, in: project).range))
        for anchor in anchors {
            let resolved = try ReadingExperienceRuntime.resolve(anchor, in: project)
            XCTAssertFalse(index.crossesStructuralBoundary(resolved.range))
            XCTAssertTrue((text as NSString).substring(with: resolved.range).utf8.elementsEqual(anchor.quote.utf8))
            XCTAssertEqual(anchor.id, try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1",
                quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix, in: project).id)
        }
        XCTAssertEqual(project.readingExperience?.anchors, [old])
        XCTAssertEqual(Data(project.units[0].text.utf8), originalBytes)
    }
    func testHardCutsIgnoreOutOfBoundsSurrogatesAndCombiningSequenceOffsets() {
        let text = "😀甲e\u{301}乙。下一句没有句号"
        let invalid = [-1, 0, 1, 4, (text as NSString).length, Int.max]
        let ordinary = ReadingSentenceAnchors.ranges(in: text)
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text, structuralBreaks: invalid), ordinary)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertFalse(ReadingSentenceAnchors.boundaryIndex(in: text, structuralBreaks: invalid).crossesStructuralBoundary(whole))
        let first = (text as NSString).range(of: "下一句").location
        let withCut = ReadingSentenceAnchors.ranges(in: text, structuralBreaks: invalid + [first, first])
        XCTAssertEqual(withCut, ordinary)
        XCTAssertTrue(ReadingSentenceAnchors.boundaryIndex(in: text, structuralBreaks: invalid + [first]).crossesStructuralBoundary(whole))
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: "无句号的前半后半", structuralBreaks: [6]).map {
            ("无句号的前半后半" as NSString).substring(with: $0)
        }, ["无句号的前半", "后半"])
    }
}
