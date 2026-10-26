import Foundation
import XCTest
@testable import ReadingCore

final class ReadingMarkdownStructureTests: XCTestCase {
    private func project(_ text: String, name: String = "source.md") -> BookProject {
        BookProject(title: "结构句界", originalName: name, sourceHash: "original-source",
            units: [SourceUnit(id: "u1", order: 0, chapter: "开篇", page: 1, text: text)])
    }
    private func quotes(_ text: String) -> [String] {
        ReadingSentenceAnchors.ranges(in: text, syntax: .markdown).map { (text as NSString).substring(with: $0) }
    }

    func testRepeatedUnclosedEscapedMathDoesNotHideFollowingSentences() {
        let text = String(repeating: "\\(x \\[y ", count: 10_000) + "结束。下一句。"
        let ranges = ReadingSentenceAnchors.ranges(in: text)
        XCTAssertEqual((text as NSString).substring(with: ranges.last!), "下一句。")
        XCTAssertTrue(ranges.allSatisfy { $0.length > 0 })
        let valid = "前文 \\(x?\\) 仍是同一句。下一句。"
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: valid).map { (valid as NSString).substring(with: $0) },
                       ["前文 \\(x?\\) 仍是同一句。", "下一句。"])
    }

    func testSyntaxRequiresMarkdownSourceOrTheActualRecognizedPage() {
        let text = "正文 `未闭合\n> 引用?`继续。"
        var pdf = project(text, name: "source.pdf")
        XCTAssertEqual(ReadingSentenceAnchors.syntax(for: pdf.units[0], in: pdf), .plainText)
        XCTAssertEqual(ReadingSentenceAnchors.ranges(in: text), ReadingSentenceAnchors.ranges(in: text, syntax: .plainText))
        pdf.ocrPages = [OCRPageProvenance(page: 2, model: "offline", createdAt: Date(), issues: [], unitIDs: ["other"])]
        XCTAssertEqual(ReadingSentenceAnchors.syntax(for: pdf.units[0], in: pdf), .plainText)
        pdf.ocrPages = [OCRPageProvenance(page: 1, model: "offline", createdAt: Date(), issues: [], unitIDs: ["u1"])]
        XCTAssertEqual(ReadingSentenceAnchors.syntax(for: pdf.units[0], in: pdf), .markdown)
        for name in ["source.md", "source.MARKDOWN"] {
            let book = project(text, name: name)
            XCTAssertEqual(ReadingSentenceAnchors.syntax(for: book.units[0], in: book), .markdown)
        }
        XCTAssertTrue(ReadingMarkdownStructure.needsStructure("- 第一项\n- 第二项"))
        XCTAssertTrue(ReadingMarkdownStructure.needsStructure("**强调**\n> 后面的引用"), "非列表的星号不能使后续结构漏检。")
        XCTAssertFalse(ReadingMarkdownStructure.needsStructure("普通原文同一句\n继续软换行。"))
    }

    #if os(macOS)
    // Temporary CI diagnostics for Foundation's source positions on multiline
    // inline code. Only hard-coded failing fixtures are printed, never books.
    private func diagnoseFoundation(_ text: String) {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .throwError
        options.appliesSourcePositionAttributes = true
        print("READING_MD_DIAG_SOURCE", text.debugDescription)
        guard let value = try? AttributedString(markdown: text, options: options) else {
            print("READING_MD_DIAG_PARSE_FAILED"); return
        }
        for run in value.runs {
            let content = String(value.characters[run.range])
            let range = run.markdownSourcePosition.flatMap { Range($0, in: text) }
            let mapped = range.map { String(text[$0]) }
            let utf16 = range.map { NSRange($0, in: text) }
            print("READING_MD_DIAG_RUN", content.debugDescription,
                  "intent", String(describing: run.presentationIntent),
                  "inline", String(describing: run.inlinePresentationIntent),
                  "position", String(describing: run.markdownSourcePosition),
                  "officialUTF16", String(describing: utf16),
                  "officialSource", String(describing: mapped))
        }
        print("READING_MD_DIAG_BLOCKS", String(describing: ReadingMarkdownStructure.blocks(in: text, displayMath: { _ in [] })?.map(\.range)))
    }

    func testIndependentQuoteAndListParagraphsCannotShareACodeSpan() {
        let quote = "正文 `未闭合\n> 引用?`下一句。"
        XCTAssertEqual(quotes(quote), ["正文 `未闭合", "> 引用?", "`下一句。"])
        let list = "- 列表 `未闭合\n- 第二项?`结束。"
        XCTAssertEqual(quotes(list), ["- 列表 `未闭合", "- 第二项?", "`结束。"])
        for text in [quote, list] {
            let index = ReadingSentenceAnchors.boundaryIndex(in: text, syntax: .markdown)
            XCTAssertTrue(index.crossesStructuralBoundary(NSRange(location: 0, length: (text as NSString).length)))
            for range in ReadingSentenceAnchors.ranges(in: text, syntax: .markdown) { XCTAssertFalse(index.crossesStructuralBoundary(range)) }
        }
    }

    func testQuoteLazyContinuationAndNestedListKeepTheirRealParagraph() {
        for first in [
            "> 引用 `跨行\n> 继续?`结束。",
            "> 引用 `惰性\n续行?`结束。",
            "- 列表 `跨行\n  继续?`结束。"
        ] {
            let text = first + "下一句。"
            let actual = quotes(text), expected = [first, "下一句。"]
            if actual != expected { diagnoseFoundation(text) }
            XCTAssertEqual(actual, expected, text)
        }
        let nested = "- 外层尚无标点\n  - 嵌套 `跨行\n    继续?`结束。"
        let actualNested = quotes(nested), expectedNested = ["- 外层尚无标点", "- 嵌套 `跨行\n    继续?`结束。"]
        if actualNested != expectedNested { diagnoseFoundation(nested) }
        XCTAssertEqual(actualNested, expectedNested)
        let index = ReadingSentenceAnchors.boundaryIndex(in: nested, syntax: .markdown)
        XCTAssertTrue(index.crossesStructuralBoundary(NSRange(location: 0, length: (nested as NSString).length)))
    }

    func testContainerCodeIsNotTurnedIntoSentenceButtonsOrFakeMath() {
        let quotedCode = "> ```swift\n> let cash = \"$$?\"\n> ```\n>\n> 后文。"
        XCTAssertEqual(quotes(quotedCode), ["> 后文。"])
        let indented = "- 项目。\n\n      print(\"what?\")\n\n- 下一项。"
        XCTAssertEqual(quotes(indented), ["- 项目。", "- 下一项。"])
        for text in ["- `$$?` 保留代码。\n- 第二项。", "- `\\[not math?\\]` 保留。\n- 后文。"] {
            let result = quotes(text)
            XCTAssertEqual(result.count, 2)
            XCTAssertTrue(result[0].contains("?`" ) || result[0].contains("?\\]`"))
        }
    }

    func testCustomDisplayMathKeepsItsBlankLinesAndListLookingContentAtomic() {
        let dollar = "- 开始。\n\n  $$\n  x?\n\n  - y!\n  $$\n\n- 结束。"
        let dollarMath = "$$\n  x?\n\n  - y!\n  $$"
        XCTAssertEqual(quotes(dollar), ["- 开始。", dollarMath, "- 结束。"])
        let escaped = "> \\[\n> a? + b\n>\n> - c!\n> \\]\n>\n> 结束。"
        let escapedMath = "> \\[\n> a? + b\n>\n> - c!\n> \\]"
        XCTAssertEqual(quotes(escaped), [escapedMath, "> 结束。"])
        for (text, math) in [(dollar, dollarMath), (escaped, escapedMath)] {
            let source = text as NSString, range = source.range(of: math, options: .literal)
            XCTAssertNotEqual(range.location, NSNotFound)
            XCTAssertFalse(ReadingSentenceAnchors.boundaryIndex(in: text, syntax: .markdown).crossesStructuralBoundary(range))
        }
        let separate = "- $$未闭合\n- 第二项 $$结束。"
        XCTAssertTrue(ReadingSentenceAnchors.boundaryIndex(in: separate, syntax: .markdown)
            .crossesStructuralBoundary(NSRange(location: 0, length: (separate as NSString).length)), "不同列表项不能用美元符号跨块强行合并。")
    }

    func testCurrencyAndUnrelatedUnmatchedCodeDoNotHideRealDisplayMath() {
        let math = "$$\n  x?\n\n  - y!\n  $$"
        let currency = "- 价格 $5。\n\n  " + math + "\n\n- 结束。"
        XCTAssertEqual(quotes(currency), ["- 价格 $5。", math, "- 结束。"])
        let escapedMath = "> \\[\n> a?\n>\n> b!\n> \\]"
        let inlineOpener = "前文 \\(未闭合。\n\n" + escapedMath + "\n>\n> 后文。"
        XCTAssertEqual(quotes(inlineOpener), ["前文 \\(未闭合。", escapedMath, "> 后文。"])
        let independentCode = "- 前文 `未闭合\n\n- " + math + "\n\n- 后文 `。"
        XCTAssertEqual(quotes(independentCode), ["- 前文 `未闭合", "- " + math, "- 后文 `。"],
            "不同段落的反引号不能拼成代码跨度，进而遮住真实公式。")
        let sameParagraphCode = "> `$$\n> a?\n> $$`保留代码。\n>\n> 后文。"
        let actualCode = quotes(sameParagraphCode), expectedCode = ["> `$$\n> a?\n> $$`保留代码。", "> 后文。"]
        if actualCode != expectedCode { diagnoseFoundation(sameParagraphCode) }
        XCTAssertEqual(actualCode, expectedCode)
    }

    func testExactSourceLinesPreserveCRLFEmojiCombiningBytesAndOldIdentity() throws {
        let text = "- 😀e\u{301}仍是原字节。\r\n- 第二项。"
        let book = project(text)
        let anchors = ReadingSentenceAnchors.anchors(in: book.units[0], project: book)
        XCTAssertEqual(anchors.map(\.quote), ["- 😀e\u{301}仍是原字节。", "- 第二项。"])
        for anchor in anchors {
            let old = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: anchor.quote, in: book)
            XCTAssertEqual(anchor, old, "块解析不能把剥除markup后的正文用于改造稳定锚。")
            let resolved = try ReadingExperienceRuntime.resolve(anchor, in: book)
            XCTAssertTrue((text as NSString).substring(with: resolved.range).utf8.elementsEqual(anchor.quote.utf8))
        }
        XCTAssertTrue(anchors[0].quote.unicodeScalars.contains { $0.value == 0x301 })
        XCTAssertFalse(anchors[0].quote.unicodeScalars.contains { $0.value == 0xe9 })
    }

    func testUnknownTableMappingIsLocalAndCannotAuthorizeCrossBlockCache() {
        let text = "- 前文。\n\n| a | b |\n| --- | --- |\n| c | d |\n\n- 后文。"
        let result = quotes(text)
        XCTAssertEqual(result.first, "- 前文。")
        XCTAssertEqual(result.last, "- 后文。")
        XCTAssertFalse(result.contains { $0.contains("|") })
        let table = (text as NSString).range(of: "| c | d |", options: .literal)
        XCTAssertTrue(ReadingSentenceAnchors.boundaryIndex(in: text, syntax: .markdown).crossesStructuralBoundary(table))
    }

    func testValidOldParagraphCacheKeepsIdentityWhileMixedItemsAreRejected() throws {
        let text = "- 第一项。\n- 第二项。"
        var book = project(text)
        let exact = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "- 第一项。", in: book)
        let request = try SentenceTranslationRequest.freeze(anchor: exact, in: book)
        var legacy = exact; legacy.utf16Location = nil; legacy.utf16Length = nil
        let layer = ReadingLayer(id: request.cacheID, kind: "translation", title: "旧译文", markdown: "第一项的已有解释。", sourceAnchorIDs: [legacy.id],
            provenance: ReadingProvenance(label: "sentence-translation", workTitle: "简体中文"))
        let mixed = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: text, in: book)
        book.readingExperience = ReadingExperienceState(anchors: [legacy, mixed], layers: [layer])
        let saved = book.readingExperience
        XCTAssertEqual(request.cachedLayer(in: book), layer)
        XCTAssertEqual(try SentenceTranslationRequest.freeze(anchor: legacy, in: book).cacheID, request.cacheID)
        XCTAssertThrowsError(try SentenceTranslationRequest.freeze(anchor: mixed, in: book))
        XCTAssertEqual(book.readingExperience, saved, "显示门禁不得迁移或删除旧记录。")
        XCTAssertEqual(book.units[0].text, text)
    }

    func testCancelledStructuredScanCannotBecomeAnEmptyBoundaryGrant() async {
        let text = "- 第一项。\n- 第二项。"
        let cancelled = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            let index = ReadingSentenceAnchors.boundaryIndex(in: text, syntax: .markdown)
            return (ReadingSentenceAnchors.ranges(in: text, syntax: .markdown).isEmpty,
                    index.crossesStructuralBoundary(NSRange(location: 0, length: 1)),
                    index.crossesStructuralBoundary(NSRange(location: 0, length: (text as NSString).length)))
        }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertTrue(result.0); XCTAssertTrue(result.1); XCTAssertTrue(result.2)
    }
    #endif
}
