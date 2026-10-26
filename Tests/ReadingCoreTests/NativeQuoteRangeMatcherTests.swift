import Foundation
import XCTest
@testable import ReadingCore

final class NativeQuoteRangeMatcherTests: XCTestCase {
    func testUniqueLiteralRangeUsesNativeUTF16WithChineseAndEmoji() {
        let text = "前😀董卓后" as NSString
        let range = NativeQuoteRangeMatcher.range(of: "董卓", prefix: "😀", suffix: "后", in: text)
        XCTAssertEqual(range, NSRange(location: 3, length: 2))
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: "董卓", prefix: "不存在", in: text))
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: "董卓", suffix: "不存在", in: text))
    }

    func testOverlappingOccurrencesMustStillProveUniqueness() {
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: "aaa", in: "aaaaa" as NSString))
        XCTAssertEqual(NativeQuoteRangeMatcher.range(of: "aaa", prefix: "aa", in: "aaaaa" as NSString), NSRange(location: 2, length: 3))
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: "aaa", prefix: "a", suffix: "a", in: "aaaaaa" as NSString))
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: "", in: "任意正文" as NSString))
    }

    func testCanonicalEquivalentStringsKeepTheirExactNativeBytes() {
        let decomposed = "e\u{301}", composed = "é"
        let text = "\(decomposed)|\(composed)" as NSString
        XCTAssertEqual(NativeQuoteRangeMatcher.range(of: decomposed, in: text), NSRange(location: 0, length: 2))
        XCTAssertEqual(NativeQuoteRangeMatcher.range(of: composed, in: text), NSRange(location: 3, length: 1))
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: "|", prefix: composed, in: text))
        XCTAssertNil(NativeQuoteRangeMatcher.range(of: "|", suffix: decomposed, in: text))
    }

    func testCancellationBeforeFirstCandidateDoesNoScan() {
        var checks = 0
        let range = NativeQuoteRangeMatcher.range(of: "董卓", in: "董卓" as NSString, isCancelled: {
            checks += 1; return true
        })
        XCTAssertNil(range)
        XCTAssertEqual(checks, 1)
    }

    func testCancellationWhileProvingUniquenessNeverReturnsFirstMatch() {
        // This single-character source ends immediately after the first match.
        // The final cancellation check must also guard that exit path.
        var checks = 0
        let range = NativeQuoteRangeMatcher.range(of: "甲", in: "甲" as NSString, isCancelled: {
            checks += 1; return checks >= 3
        })
        XCTAssertNil(range)
        XCTAssertEqual(checks, 3)

        checks = 0
        let repeated = NativeQuoteRangeMatcher.range(of: "甲", in: "甲乙甲" as NSString, isCancelled: {
            checks += 1; return checks >= 3
        })
        XCTAssertNil(repeated, "A canceled uniqueness scan cannot return a partial candidate.")
        XCTAssertEqual(checks, 3)
    }

    func testRepeatedPrefixMissesRespondToCancellationBetweenCandidates() {
        var checks = 0
        let text = (String(repeating: "甲乙", count: 1000) + "丙甲乙") as NSString
        let range = NativeQuoteRangeMatcher.range(of: "甲乙", prefix: "丙", in: text, isCancelled: {
            checks += 1; return checks >= 5
        })
        XCTAssertNil(range)
        XCTAssertEqual(checks, 5, "A canceled old-page scan must not visit all remaining occurrences.")
        XCTAssertEqual(NativeQuoteRangeMatcher.range(of: "甲乙", prefix: "丙", in: text), NSRange(location: 2001, length: 2))
    }
}
