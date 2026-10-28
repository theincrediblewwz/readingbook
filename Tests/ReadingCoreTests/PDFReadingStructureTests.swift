import Foundation
import XCTest
@testable import ReadingCore

final class PDFReadingStructureTests: XCTestCase {
    private func quotes(_ text: String, peers: [String] = []) -> [String] {
        ReadingSentenceAnchors.ranges(in: text, structuralBreaks: PDFReadingStructure.boundaries(in: text, peers: peers))
            .map { (text as NSString).substring(with: $0) }
    }

    func testRepeatedHeaderAndStandalonePageNumberSeparateWithoutRemovingSource() throws {
        let text = "\r\n \t\r\n横排大字本\r\n玄德来到\r\n城中。另一句尚未结束\r\n471\r\n \t\r\n"
        let peers = ["\n横排大字本\n前页正文。\n470\n", "横排大字本\n后页正文。\n472"]
        let cuts = PDFReadingStructure.boundaries(in: text, peers: peers)
        XCTAssertEqual(cuts, [(text as NSString).range(of: "玄德").location, (text as NSString).range(of: "471").location])
        XCTAssertEqual(quotes(text, peers: peers), ["横排大字本", "玄德来到\r\n城中。", "另一句尚未结束", "471"])

        let prepared = try XCTUnwrap(PDFReadingStructure.edgeDescriptor(in: text))
        XCTAssertEqual(PDFReadingStructure.boundaries(in: prepared, peers: peers.compactMap { PDFReadingStructure.edgeDescriptor(in: $0) }), cuts)
    }

    func testEdgesRequireTwoSameSideByteExactPeers() {
        let header = "阅读札记"
        let text = header + "\n正文继续。"
        XCTAssertEqual(PDFReadingStructure.boundaries(in: text, peers: [header + "\n前页正文。"]), [])
        XCTAssertEqual(PDFReadingStructure.boundaries(in: text, peers: ["前页正文。\n" + header, "后页正文。\n" + header]), [])
        XCTAssertEqual(PDFReadingStructure.boundaries(in: text, peers: [header, " \n" + header + "\n\n"]), [])
        XCTAssertEqual(PDFReadingStructure.boundaries(in: "\n" + header + "\n", peers: [text, text]), [])

        let nfd = "Cafe\u{301} 版", nfc = "Café 版"
        XCTAssertEqual(nfd, nfc, "Swift 文本等值不足以证明原字节重复。")
        XCTAssertEqual(PDFReadingStructure.boundaries(in: nfd + "\n正文。", peers: [nfc + "\n甲。", nfc + "\n乙。"]), [])
        XCTAssertEqual(PDFReadingStructure.boundaries(in: "  " + header + "\n正文。", peers: [header + "\n甲。", header + "\n乙。"]), [])
    }

    func testBodySoftWrapsAndPunctuatedOrLongEdgeLinesKeepTheirOriginalMeaning() {
        let text = "玄德来到\n城中，继续说话。"
        XCTAssertEqual(quotes(text, peers: ["贾诩来到\n城中，继续说话。", "曹操来到\n城中，继续说话。"]), [text])
        let punctuated = "玄德来到城中。\n正文继续。"
        XCTAssertEqual(PDFReadingStructure.boundaries(in: punctuated, peers: [punctuated, punctuated]), [])
        let long = String(repeating: "字", count: 121) + "\n正文。"
        XCTAssertEqual(PDFReadingStructure.boundaries(in: long, peers: [long, long]), [])
        let combined = "e" + String(repeating: "\u{301}", count: 1024) + "\n正文。"
        XCTAssertEqual(PDFReadingStructure.boundaries(in: combined, peers: [combined, combined]), [], "短字数不能让大组合字符变成无限大的边缘descriptor。")
    }

    func testRepeatedFooterAndOnlyBoundedArabicPageNumbersCreateCuts() {
        let text = "前句未结束\n阅读札记\n"
        XCTAssertEqual(quotes(text, peers: ["不同正文。\n阅读札记", "另一正文。\n阅读札记\n"]), ["前句未结束", "阅读札记"])
        XCTAssertEqual(quotes("末句尚未结束\n 00471 \n"), ["末句尚未结束", "00471"])
        for tail in ["1234567", "第四七一页", "４７１", "471.", "47 1"] {
            let page = "末句尚未结束\n" + tail
            XCTAssertEqual(PDFReadingStructure.boundaries(in: page, peers: []), [], tail)
        }
        XCTAssertEqual(PDFReadingStructure.boundaries(in: "\n471\n\n", peers: []), [])
    }
}
