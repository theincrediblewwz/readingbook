import Foundation
import XCTest
@testable import ReadingCore

final class ReadingTypographyTests: XCTestCase {
    func testContextsStayIndependentAndResetDoesNotReapplyLegacyScale() throws {
        var preferences = ReadingTypographyPreferences(legacyCompanionScale: 1.5)
        XCTAssertEqual(preferences.style(for: .companion).pointSize, 27)
        XCTAssertEqual(preferences.style(for: .conversation).pointSize, 27)
        XCTAssertEqual(preferences.style(for: .source).pointSize, 17)
        preferences.set(ReadingTextStyle(family: "PingFang SC", pointSize: 24), for: .conversation)
        XCTAssertEqual(preferences.style(for: .companion).pointSize, 27)
        preferences.reset(.conversation)
        XCTAssertEqual(preferences.style(for: .conversation), ReadingTypographyPreferences.defaultStyle(for: .conversation))
        let saved = try JSONEncoder().encode(preferences)
        let restored = ReadingTypographyPreferences.restored(from: saved, legacyCompanionScale: 1.5)
        XCTAssertEqual(restored.style(for: .conversation).pointSize, 18)
        XCTAssertEqual(restored.style(for: .companion).pointSize, 27)
        preferences.resetAll()
        for context in ReadingTextContext.allCases {
            XCTAssertEqual(preferences.style(for: context), ReadingTypographyPreferences.defaultStyle(for: context))
        }
    }

    func testBoundsFiniteValuesAndInvalidFamilyAreNormalizedBeforeSaving() throws {
        var preferences = ReadingTypographyPreferences()
        preferences.set(ReadingTextStyle(family: "\u{0}bad", pointSize: .nan), for: .notes)
        XCTAssertEqual(preferences.style(for: .notes), ReadingTypographyPreferences.defaultStyle(for: .notes))
        preferences.set(ReadingTextStyle(family: String(repeating: "x", count: 257), pointSize: 999), for: .knowledge)
        XCTAssertEqual(preferences.style(for: .knowledge), ReadingTextStyle(family: "system", pointSize: 36))
        preferences.set(ReadingTextStyle(family: "serif", pointSize: -1), for: .source)
        XCTAssertEqual(preferences.style(for: .source).pointSize, 12)
        preferences.set(ReadingTextStyle(family: "system", pointSize: .infinity), for: .companion)
        XCTAssertEqual(preferences.style(for: .companion).pointSize, 18)
        XCTAssertNoThrow(try JSONEncoder().encode(preferences))
    }

    func testCustomUninstalledFontRoundTripsAndUnknownContextsDoNotReplaceKnownDefaults() throws {
        let input = Data(#"{"version":1,"styles":{"notes":{"family":"  未安装字体  ","pointSize":23},"future":{"family":"system","pointSize":30}}}"#.utf8)
        let preferences = ReadingTypographyPreferences.restored(from: input)
        XCTAssertEqual(preferences.style(for: .notes), ReadingTextStyle(family: "未安装字体", pointSize: 23))
        XCTAssertEqual(preferences.style(for: .source), ReadingTypographyPreferences.defaultStyle(for: .source))
        XCTAssertEqual(ReadingTypographyPreferences.restored(from: try JSONEncoder().encode(preferences)), preferences)
    }

    func testCorruptAndFuturePreferencesFallBackWithoutRetiredScale() {
        for data in [Data("bad".utf8), Data(#"{"version":2,"styles":{}}"#.utf8)] {
            let restored = ReadingTypographyPreferences.restored(from: data, legacyCompanionScale: 2)
            XCTAssertEqual(restored.style(for: .companion).pointSize, 18)
        }
        for invalidScale in [Double.nan, .infinity, -1, 0] {
            XCTAssertEqual(ReadingTypographyPreferences(legacyCompanionScale: invalidScale).style(for: .companion).pointSize, 18)
        }
    }
}
