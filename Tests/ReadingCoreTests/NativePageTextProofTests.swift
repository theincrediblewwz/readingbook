import Foundation
import XCTest
@testable import ReadingCore

final class NativePageTextProofTests: XCTestCase {
    func testWholePageProofMapsChineseAndEmojiWithoutNormalizedEquality() throws {
        let text = "前😀董卓后。"
        let source = try PDFPageSourceText(page: 2, text: text)
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 2, nativeText: text, source: source))
        XCTAssertEqual(proof.range(of: "董卓", location: 3, length: 2), NSRange(location: 3, length: 2))
        XCTAssertEqual(proof.range(of: "😀", location: 1, length: 2), NSRange(location: 1, length: 2))
        XCTAssertEqual(proof.byteCount, text.utf16.count * 2)

        let nfd = "e\u{301}", nfc = "é"
        let decomposed = try PDFPageSourceText(page: 1, text: nfd)
        let composed = try PDFPageSourceText(page: 1, text: nfc)
        XCTAssertNotEqual(decomposed.identity, composed.identity, "视觉等价不能复用整页证明。")
        XCTAssertNil(NativePageTextProof.prove(page: 1, nativeText: nfc, source: decomposed))
        let exact = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: nfd, source: decomposed))
        XCTAssertNil(exact.range(of: nfc, location: 0, length: 2))
    }

    func testSplitUnitsAndRepeatedQuotesUseOnlyHostValidatedLocations() throws {
        let first = "甲。刘备在城。", second = "乙。刘备在城。", native = first + second
        let book = BookProject(title: "分割页", originalName: "source.pdf", sourceHash: "exact-source", units: [
            SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: first),
            SourceUnit(id: "u2", order: 1, chapter: "一", page: 1, text: second)
        ])
        let source = try PDFPageSourceText(page: 1, text: native)
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: native, source: source))
        let a = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "刘备", in: book)
        let b = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u2", quote: "刘备", in: book)
        let left = try ReadingExperienceRuntime.resolve(a, in: book), right = try ReadingExperienceRuntime.resolve(b, in: book)
        XCTAssertEqual(proof.range(of: a.quote, location: left.range.location, length: left.range.length), NSRange(location: 2, length: 2))
        XCTAssertEqual(proof.range(of: b.quote, location: first.utf16.count + right.range.location, length: right.range.length),
                       NSRange(location: first.utf16.count + 2, length: 2))
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: "刘备", in: native as NSString), "证明失败时，原搜索仍不得猜重复词的位置。")
        var forged = b; forged.utf16Location = 0
        XCTAssertThrowsError(try ReadingExperienceRuntime.resolve(forged, in: book), "数字范围不能绕过上游相邻原文/身份核对。")
        var partial = b; partial.utf16Location = nil
        XCTAssertThrowsError(try ReadingExperienceRuntime.resolve(partial, in: book))
        var legacy = b; legacy.utf16Location = nil; legacy.utf16Length = nil
        XCTAssertEqual(try ReadingExperienceRuntime.resolve(legacy, in: book).range, right.range)
    }

    func testMissingUnitsOCRAndWrongPageCannotProveMapping() throws {
        let source = try PDFPageSourceText(page: 1, text: "甲。\n乙。")
        XCTAssertNil(NativePageTextProof.prove(page: 2, nativeText: source.text, source: source))
        XCTAssertNil(NativePageTextProof.prove(page: 1, nativeText: "甲。", source: source))
        XCTAssertNil(NativePageTextProof.prove(page: 1, nativeText: "甲。\n新的OCR正文。", source: source))
        XCTAssertNotEqual(source.identity, try PDFPageSourceText(page: 2, text: source.text).identity)
        XCTAssertThrowsError(try PDFPageSourceText(page: 0, text: "甲"))
    }

    func testImportedLineEndingsMapCrossLineFirstAndLastSentencesWithCanonicalContext() throws {
        let native = "首😀句，\r\n仍是首句。\r\n中句。\r末😀句。\r\n"
        let units = try BookImporter.splitText(native, chapter: "一", page: 1)
        let book = BookProject(title: "换行页", originalName: "source.pdf", sourceHash: "line-endings", units: units)
        let canonical = units.map(\.text).joined()
        XCTAssertEqual(canonical, "首😀句，\n仍是首句。\n中句。\n末😀句。\n")
        let source = try PDFPageSourceText(page: 1, text: canonical)
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: native, source: source))
        XCTAssertEqual(proof.identity, source.identity)
        let unit = try XCTUnwrap(units.first)
        for (quote, nativeQuote) in [("首😀句，\n仍是首句。", "首😀句，\r\n仍是首句。"), ("中句。", "中句。"), ("末😀句。", "末😀句。")] {
            let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: unit.id, quote: quote, in: book)
            let resolved = try ReadingExperienceRuntime.resolve(anchor, in: book)
            let range = try XCTUnwrap(proof.range(of: anchor.quote, location: resolved.range.location, length: resolved.range.length))
            XCTAssertEqual(range, (native as NSString).range(of: nativeQuote))
            XCTAssertEqual((native as NSString).substring(with: range), nativeQuote)
            if quote.hasPrefix("首") { XCTAssertTrue(anchor.prefix.isEmpty); XCTAssertTrue(anchor.suffix.hasPrefix("\n中句。")) }
            if quote.hasPrefix("末") { XCTAssertTrue(anchor.prefix.hasSuffix("中句。\n")); XCTAssertEqual(anchor.suffix, "\n") }
        }
        XCTAssertEqual(proof.range(of: canonical, location: 0, length: canonical.utf16.count), NSRange(location: 0, length: native.utf16.count))
        XCTAssertEqual(proof.byteCount, canonical.utf16.count * 2 + 3 * MemoryLayout<Int>.stride)
    }

    func testLineEndingMappingKeepsEmojiAndEndBoundariesExact() throws {
        let native = "😀\r\n甲\r乙😀\r\n", canonical = "😀\n甲\n乙😀\n"
        let source = try PDFPageSourceText(page: 1, text: canonical)
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: native, source: source))
        XCTAssertEqual(proof.range(of: "😀", location: 0, length: 2), NSRange(location: 0, length: 2))
        XCTAssertEqual(proof.range(of: "😀", location: 6, length: 2), NSRange(location: 7, length: 2))
        XCTAssertEqual(proof.range(of: "\n", location: 2, length: 1), NSRange(location: 2, length: 2))
        XCTAssertEqual(proof.range(of: "\n", location: 4, length: 1), NSRange(location: 5, length: 1))
        XCTAssertEqual(proof.range(of: "\n", location: 8, length: 1), NSRange(location: 9, length: 2))
        XCTAssertEqual(proof.range(of: "甲\n乙😀\n", location: 3, length: 6), NSRange(location: 4, length: 7))
        XCTAssertNil(proof.range(of: "�", location: 1, length: 1))
        XCTAssertNil(proof.range(of: "�", location: 7, length: 1))
        XCTAssertNil(proof.range(of: "\r\n", location: 2, length: 2), "只验证canonical quote，不因原生换行匹配而接受错误原句。")
        XCTAssertNil(proof.range(of: "甲", location: 4, length: 1))
        XCTAssertEqual(proof.byteCount, canonical.utf16.count * 2 + 2 * MemoryLayout<Int>.stride)

        let bareCRSource = try PDFPageSourceText(page: 1, text: "甲\n乙\n")
        let bareCR = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: "甲\r乙\r", source: bareCRSource))
        XCTAssertEqual(bareCR.range(of: "乙\n", location: 2, length: 2), NSRange(location: 2, length: 2))
        XCTAssertEqual(bareCR.byteCount, bareCRSource.text.utf16.count * 2, "裸CR替换不改变UTF16长度，不保留偏移表。")
    }

    func testLineEndingConversionDoesNotAdmitOtherTextOrWhitespaceChanges() throws {
        let canonical = "甲 e\u{301}\n乙😀\n", source = try PDFPageSourceText(page: 1, text: canonical)
        for native in ["甲 é\r\n乙😀\r\n", "甲\te\u{301}\r\n乙😀\r\n", "甲 e\u{301} \r\n乙😀\r\n",
                       "甲 e\u{301}\r\n乙😀", "甲 e\u{301}\r\n乙😀\r\n丙", "甲 e\u{301}\r\n丙😀\r\n"] {
            XCTAssertNil(NativePageTextProof.prove(page: 1, nativeText: native, source: source))
        }
    }

    func testRawIdenticalCRPagesKeepExistingProofWithoutMapping() throws {
        for text in ["首😀句。\r\n末句。\r\n", "首😀句。\r末句。\r", "甲\re\u{301}\r\n乙😀"] {
            let source = try PDFPageSourceText(page: 1, text: text)
            let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: text, source: source))
            XCTAssertEqual(proof.identity, source.identity)
            XCTAssertEqual(proof.range(of: text, location: 0, length: text.utf16.count), NSRange(location: 0, length: text.utf16.count))
            XCTAssertEqual(proof.byteCount, text.utf16.count * 2, "字节原样相等仍使用原有proof，不分配换行映射。")
            let rawBreak = text.contains("\r\n") ? "\r\n" : "\r"
            let range = (text as NSString).range(of: rawBreak)
            XCTAssertEqual(proof.range(of: rawBreak, location: range.location, length: range.length), range)
        }
    }

    func testRepeatedIdenticalUnitsAndAdjacentContextKeepTheirOwnValidatedOffsets() throws {
        let repeated = "刘备入城。", native = repeated + repeated
        let book = BookProject(title: "同文同页", originalName: "source.pdf", sourceHash: "same-source", units: [
            SourceUnit(id: "a", order: 0, chapter: "一", page: 1, text: repeated),
            SourceUnit(id: "b", order: 1, chapter: "一", page: 1, text: repeated)
        ])
        let a = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "a", quote: "刘备", in: book)
        let b = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "b", quote: "刘备", in: book)
        XCTAssertEqual(a.prefix, b.prefix); XCTAssertEqual(a.suffix, b.suffix)
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: native, source: try PDFPageSourceText(page: 1, text: native)))
        let left = try ReadingExperienceRuntime.resolve(a, in: book), right = try ReadingExperienceRuntime.resolve(b, in: book)
        XCTAssertEqual(proof.range(of: a.quote, location: left.range.location, length: left.range.length)?.location, 0)
        XCTAssertEqual(proof.range(of: b.quote, location: repeated.utf16.count + right.range.location, length: right.range.length)?.location, repeated.utf16.count)
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: a.quote, prefix: a.prefix, suffix: a.suffix, in: native as NSString), "原页唯一缓存不能保存两个不同的已验证 unit offset。")

        let contextual = BookProject(title: "相邻字消歧", originalName: "source.pdf", sourceHash: "context", units: [
            SourceUnit(id: "c", order: 0, chapter: "一", page: 1, text: "甲刘备乙刘备丙")
        ])
        let contextualAnchor = try ReadingExperienceRuntime.createAnchor(sourceHash: contextual.sourceHash, unitID: "c", quote: "刘备", prefix: "乙", suffix: "丙", in: contextual)
        let resolved = try ReadingExperienceRuntime.resolve(contextualAnchor, in: contextual)
        XCTAssertEqual(resolved.range.location, 4)
        let contextText = contextual.units[0].text
        let contextProof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: contextText, source: try PDFPageSourceText(page: 1, text: contextText)))
        XCTAssertEqual(contextProof.range(of: contextualAnchor.quote, location: resolved.range.location, length: resolved.range.length), resolved.range)
        XCTAssertThrowsError(try ReadingExperienceRuntime.createAnchor(sourceHash: contextual.sourceHash, unitID: "c", quote: "刘备", in: contextual), "页证明不能放宽宿主的原文歧义规则。")
    }

    func testWrongRangeQuoteAndSurrogateSplitCannotUseTheFastPath() throws {
        let text = "😀甲乙", source = try PDFPageSourceText(page: 1, text: text)
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: text, source: source))
        for (location, length) in [(-1, 1), (NSNotFound, 1), (0, 0), (0, Int.max), (3, 2), (0, 1), (1, 1)] {
            XCTAssertNil(proof.range(of: "甲", location: location, length: length))
        }
        XCTAssertNil(proof.range(of: "甲", location: nil, length: 1))
        XCTAssertNil(proof.range(of: "甲", location: 2, length: nil))
        XCTAssertNil(proof.range(of: "乙", location: 2, length: 1))
        XCTAssertEqual(proof.range(of: "甲", location: 2, length: 1), NSRange(location: 2, length: 1))
    }

    func testCancelledProofAndLookupNeverReturnPartialPermission() throws {
        let text = String(repeating: "前😀后", count: 2000), source = try PDFPageSourceText(page: 1, text: text)
        XCTAssertNil(NativePageTextProof.prove(page: 1, nativeText: text, source: source, isCancelled: { true }))
        var checks = 0
        XCTAssertNil(NativePageTextProof.prove(page: 1, nativeText: text, source: source, isCancelled: {
            checks += 1; return checks >= 4
        }))
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: text, source: source))
        XCTAssertNil(proof.range(of: "前😀后", location: 0, length: 4, isCancelled: { true }))
        checks = 0
        XCTAssertNil(proof.range(of: "前😀后", location: 0, length: 4, isCancelled: {
            checks += 1; return checks >= 3
        }))
    }

    func testCancelledLineEndingConversionAndMappedLookupDoNotReturnPartialProof() throws {
        let native = String(repeating: "前😀\r\n后\r", count: 1000)
        let canonical = native.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let source = try PDFPageSourceText(page: 1, text: canonical)
        var checks = 0
        XCTAssertNil(NativePageTextProof.prove(page: 1, nativeText: native, source: source, isCancelled: {
            checks += 1; return checks >= 4
        }))
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: native, source: source))
        checks = 0
        XCTAssertNil(proof.range(of: "前😀\n后\n", location: 0, length: 6, isCancelled: {
            checks += 1; return checks >= 3
        }))
    }
}
