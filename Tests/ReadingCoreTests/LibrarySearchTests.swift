import Foundation
import XCTest
@testable import ReadingCore

final class LibrarySearchTests: XCTestCase {
    private func book(id: String = "book-a", text: String = "😀曹操屯兵。阿瞒归来。", name: String = "曹操") -> BookProject {
        var value = BookProject(id: id, title: "原书 \(id)", originalName: "source.md", sourceHash: "source-\(id)",
                                units: [SourceUnit(id: "unit-1", order: 0, chapter: "第一章", text: text)])
        value.entities = [KnowledgeEntity(id: "same-id-in-independent-books", typeID: "person", name: name, aliases: ["阿瞒"], evidence: [Evidence(unitID: "unit-1", quote: "曹操")])]
        return value
    }

    func testUnicodeMatchUsesOriginalQuoteAndUTF16Range() throws {
        let project = book(text: "😀曹操屯兵。CAFÉ 与 e\u{301} 并列。")
        let snapshot = LibrarySourceSnapshot(project: project)
        let response = try LibraryTextSearch.search(query: "曹操", snapshots: [snapshot])
        let match = try XCTUnwrap(response.matches.first)
        XCTAssertEqual(match.utf16Location, 2, "UTF16范围须计算前方emoji的代理对。")
        XCTAssertEqual(match.utf16Length, 2)
        XCTAssertEqual(match.quote, "曹操")
        XCTAssertEqual(match.bookID, project.id)
        XCTAssertEqual(match.unitID, "unit-1")
        XCTAssertNoThrow(try match.validate(in: project))
        let folded = try LibraryTextSearch.search(query: "café", snapshots: [snapshot])
        XCTAssertEqual(folded.matches.first?.quote, "CAFÉ", "返回原书大小写，不能以查询文本伪造引文。")
        let combined = try LibraryTextSearch.search(query: "e\u{301} 并列", snapshots: [snapshot])
        let composedMatch = try XCTUnwrap(combined.matches.first)
        XCTAssertTrue(composedMatch.quote.utf8.elementsEqual("e\u{301} 并列".utf8))
        XCTAssertNoThrow(try composedMatch.validate(in: project))
    }

    func testRepeatedWordReturnsSeparateExactAnchorsWithAdjacentContext() throws {
        let project = book(text: "春记：曹操在北。\n秋记：曹操在南。")
        let response = try LibraryTextSearch.search(query: "曹操", snapshots: [LibrarySourceSnapshot(project: project)])
        XCTAssertEqual(response.matches.count, 2)
        XCTAssertNotEqual(response.matches[0].id, response.matches[1].id)
        let anchors = try response.matches.map { match in
            try ReadingExperienceRuntime.createAnchor(sourceHash: match.sourceHash, unitID: match.unitID, quote: match.quote,
                                                       prefix: match.prefix, suffix: match.suffix, in: project)
        }
        XCTAssertNotEqual(anchors[0].id, anchors[1].id)
        for (match, anchor) in zip(response.matches, anchors) {
            XCTAssertEqual(try ReadingExperienceRuntime.resolve(anchor, in: project).range, match.range)
        }
    }

    func testBookScopeAndCrossBookAliasCardsNeverMergeIdentity() throws {
        let first = book(id: "one")
        let second = book(id: "two", text: "另书说曹操。", name: "另书中的曹操")
        let snapshots = [first, second].map { LibrarySourceSnapshot(project: $0) }
        let all = try LibraryTextSearch.search(query: "曹操", snapshots: snapshots)
        XCTAssertEqual(all.matches.map(\.bookID), ["one", "two"])
        XCTAssertEqual(all.entityMatches.count, 2)
        XCTAssertNotEqual(all.entityMatches[0].id, all.entityMatches[1].id)
        XCTAssertEqual(all.entityMatches[0].entity.id, all.entityMatches[1].entity.id)
        let scoped = try LibraryTextSearch.search(query: "曹操", snapshots: snapshots, bookID: "two")
        XCTAssertEqual(scoped.matches.map(\.bookID), ["two"])
        XCTAssertEqual(scoped.entityMatches.map(\.bookID), ["two"])
        let alias = try LibraryTextSearch.search(query: "阿瞒", snapshots: snapshots)
        XCTAssertEqual(alias.matches.map(\.bookID), ["one"], "名称索引不能凭别名给另一原书捏造文字命中。")
        XCTAssertEqual(alias.entityMatches.count, 2)
        XCTAssertEqual(alias.entityMatches.map(\.matchedName), ["阿瞒", "阿瞒"])
    }

    func testResultBoundStopsScanAndEmptyQueryDoesNotScan() throws {
        let first = book(text: String(repeating: "曹操出行。", count: 100))
        let second = book(id: "later", text: "曹操到此。")
        let snapshots = [first, second].map { LibrarySourceSnapshot(project: $0) }
        let result = try LibraryTextSearch.search(query: "曹操", snapshots: snapshots, resultLimit: 3, entityLimit: 0)
        XCTAssertEqual(result.matches.count, 3)
        XCTAssertEqual(result.scannedUnitCount, 1)
        XCTAssertTrue(result.bounded)
        XCTAssertTrue(result.entityMatches.isEmpty)
        let empty = try LibraryTextSearch.search(query: "  \n", snapshots: snapshots)
        XCTAssertTrue(empty.matches.isEmpty)
        XCTAssertEqual(empty.scannedUnitCount, 0)
        XCTAssertFalse(empty.bounded)
    }

    func testStaleOCRTextAndDifferentBookCannotReuseSearchOffset() throws {
        let original = book()
        let match = try XCTUnwrap(LibraryTextSearch.search(query: "曹操", snapshots: [LibrarySourceSnapshot(project: original)]).matches.first)
        var changed = original
        changed.units[0].text += "末尾OCR修订。"
        XCTAssertEqual(changed.sourceHash, original.sourceHash)
        XCTAssertThrowsError(try match.validate(in: changed), "PDF原文件哈希不变也须识别OCR文本版本变化。")
        changed = original; changed.id = "different-book"
        XCTAssertThrowsError(try match.validate(in: changed))
        changed = original; changed.sourceHash = "different-source"
        XCTAssertThrowsError(try match.validate(in: changed))
    }

    func testQueryAndBudgetsAreBounded() throws {
        let snapshots = [LibrarySourceSnapshot(project: book())]
        XCTAssertThrowsError(try LibraryTextSearch.search(query: String(repeating: "字", count: 401), snapshots: snapshots))
        XCTAssertThrowsError(try LibraryTextSearch.search(query: "曹操", snapshots: snapshots, resultLimit: 0))
        XCTAssertThrowsError(try LibraryTextSearch.search(query: "曹操", snapshots: snapshots, entityLimit: 101))
    }

    func testCancelledBackgroundSearchStopsBeforeScanning() async throws {
        let snapshots = [LibrarySourceSnapshot(project: book())]
        let task = Task.detached { () throws -> LibrarySearchResponse in
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibraryTextSearch.search(query: "曹操", snapshots: snapshots)
        }
        do { _ = try await task.value; XCTFail("已取消的查询不应产生结果。") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSimplifiedAndTraditionalSearchKeepOriginalRangesAndRepeatedAnchors() throws {
        let project = book(text: "😀e\u{301} Ａß貂蟬𠀀貂蝉", name: "貂蟬")
        let snapshots = [LibrarySourceSnapshot(project: project)]
        for query in ["貂蝉", "貂蟬"] {
            let result = try LibraryTextSearch.search(query: query, snapshots: snapshots)
            XCTAssertEqual(result.matches.map(\.quote), ["貂蟬", "貂蝉"])
            XCTAssertEqual(result.matches.map(\.utf16Location), [7, 11])
            XCTAssertEqual(result.matches.map(\.utf16Length), [2, 2])
            XCTAssertEqual(result.matches.map(\.matchedQuery), [query, query])
            XCTAssertEqual(result.entityMatches.first?.matchedName, "貂蟬")
            var anchorIDs = Set<String>()
            for match in result.matches {
                try match.validate(in: project)
                let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: match.sourceHash, unitID: match.unitID,
                    quote: match.quote, prefix: match.prefix, suffix: match.suffix, in: project)
                XCTAssertEqual(try ReadingExperienceRuntime.resolve(anchor, in: project).range, match.range)
                anchorIDs.insert(anchor.id)
            }
            XCTAssertEqual(anchorIDs.count, 2)
        }
    }

    func testManyToOneChineseVariantsMatchWithoutRewritingQuotes() throws {
        let project = book(text: "臺灣、檯面、台上；裏面、裡面、里面。")
        let snapshots = [LibrarySourceSnapshot(project: project)]
        for query in ["臺", "檯", "台"] {
            let result = try LibraryTextSearch.search(query: query, snapshots: snapshots)
            XCTAssertEqual(result.matches.map(\.quote), ["臺", "檯", "台"])
            for match in result.matches { try match.validate(in: project) }
        }
        for query in ["裏面", "裡面", "里面"] {
            let result = try LibraryTextSearch.search(query: query, snapshots: snapshots)
            XCTAssertEqual(result.matches.map(\.quote), ["裏面", "裡面", "里面"])
        }
    }

    func testCharacterMapRejectsPartialExpandedFoldAndPreservesEmojiAndNFD() throws {
        var canonicalizer = LibrarySearchCanonicalizer()
        let mapped = try LibrarySearchMappedText("😀ß貂蟬", canonicalizer: &canonicalizer)
        let doubled = try XCTUnwrap(mapped.text.range(of: "ss"))
        let range = NSRange(doubled, in: mapped.text)
        XCTAssertEqual(mapped.originalRange(range), NSRange(location: 2, length: 1))
        XCTAssertNil(mapped.originalRange(NSRange(location: range.location, length: 1)), "折叠展开的半个字不能成为原文定位。")
        let project = book(text: "😀e\u{301} 貂蟬")
        let match = try XCTUnwrap(LibraryTextSearch.search(query: "é 貂蝉", snapshots: [LibrarySourceSnapshot(project: project)]).matches.first)
        XCTAssertTrue(match.quote.utf8.elementsEqual("e\u{301} 貂蟬".utf8))
        XCTAssertEqual(match.range, NSRange(location: 2, length: 5))
        try match.validate(in: project)
    }

    func testLatinFastPathFoldsWidthAndCaseButDoesNotEraseAccentsOrSeparators() throws {
        let project = book(text: "😀ＣＡＦÉ Café；貂 蟬、貂\n蟬。")
        let snapshots = [LibrarySourceSnapshot(project: project)]
        let result = try LibraryTextSearch.search(query: "café", snapshots: snapshots)
        XCTAssertEqual(result.matches.map(\.quote), ["ＣＡＦÉ", "Café"])
        XCTAssertEqual(result.matches.first?.utf16Location, 2)
        for match in result.matches { try match.validate(in: project) }
        XCTAssertTrue(try LibraryTextSearch.search(query: "cafe", snapshots: snapshots).matches.isEmpty)
        XCTAssertTrue(try LibraryTextSearch.search(query: "貂蝉", snapshots: snapshots).matches.isEmpty)
    }

    func testWholeQueryPhraseVariantSupplementHasActualSourceQuote() throws {
        // This direction uses a contextual whole-query conversion. The system's
        // chosen reverse form is 什麼, so not every alternate phrase is inferred.
        let project = book(text: "你說什么？")
        let result = try LibraryTextSearch.search(query: "甚麼", snapshots: [LibrarySourceSnapshot(project: project)])
        let match = try XCTUnwrap(result.matches.first)
        XCTAssertEqual(match.quote, "什么")
        XCTAssertEqual(match.range, NSRange(location: 2, length: 2))
        try match.validate(in: project)
    }

    func testExpandedKeywordsStayInScopeDeduplicateAndKeepSearchOrigin() throws {
        let first = book(id: "one", text: "😀貂蟬到此；貂禅是另一个写法。", name: "貂蟬")
        let second = book(id: "two", text: "貂蟬只在另书。", name: "貂蟬")
        let result = try LibraryTextSearch.search(query: "貂禅", snapshots: [first, second].map { LibrarySourceSnapshot(project: $0) },
            bookID: "one", additionalQueries: ["貂蝉", "貂蟬", "不存在的词"])
        XCTAssertEqual(result.query, "貂禅")
        XCTAssertEqual(result.searchedQueries, ["貂禅", "貂蝉", "貂蟬", "不存在的词"])
        XCTAssertEqual(result.matches.map(\.quote), ["貂蟬", "貂禅"])
        XCTAssertEqual(result.matches.map(\.matchedQuery), ["貂蝉", "貂禅"])
        XCTAssertEqual(result.matches.map(\.bookID), ["one", "one"])
        XCTAssertEqual(result.searchedBookCount, 1)
        XCTAssertEqual(result.entityMatches.map(\.bookID), ["one"])
        for match in result.matches { try match.validate(in: first) }
    }

    func testDefaultResultBoundStillStopsBeforeLaterChineseUnitsOrBooks() throws {
        var first = book(text: String(repeating: "貂蟬。", count: 160))
        first.units.append(SourceUnit(id: "later-unit", order: 1, chapter: "后文", text: "貂蟬"))
        let result = try LibraryTextSearch.search(query: "貂蝉", snapshots: [first, book(id: "later", text: "貂蟬")].map { LibrarySourceSnapshot(project: $0) }, entityLimit: 0)
        XCTAssertEqual(result.matches.count, 150)
        XCTAssertEqual(result.scannedUnitCount, 1)
        XCTAssertTrue(result.bounded)
        XCTAssertEqual(Set(result.matches.map(\.unitID)), ["unit-1"])
        XCTAssertEqual(Set(result.matches.map(\.bookID)), [first.id])
    }

    func testExpandedQueryBudgetsAreValidatedBeforeScanning() throws {
        let snapshots = [LibrarySourceSnapshot(project: book())]
        XCTAssertThrowsError(try LibraryTextSearch.search(query: "词", snapshots: snapshots, additionalQueries: Array(repeating: "词", count: 9)))
        XCTAssertThrowsError(try LibraryTextSearch.search(query: "词", snapshots: snapshots, additionalQueries: [String(repeating: "词", count: 81)]))
        XCTAssertThrowsError(try LibraryTextSearch.search(query: "词", snapshots: snapshots, additionalQueries: [" "]))
        let empty = try LibraryTextSearch.search(query: " ", snapshots: snapshots, additionalQueries: ["曹操"])
        XCTAssertTrue(empty.matches.isEmpty)
        XCTAssertEqual(empty.scannedUnitCount, 0)
    }

    func testExpansionPlanOnlyAcceptsBoundedKeywordsAndDeduplicatesWithoutInventingHits() throws {
        let plan = try LibrarySearchExpansionPlan.parse("{\"keywords\":[\" 貂蟬 \",\"DIAOCHAN\",\"diaochan\",\"ＤＩＡＯＣＨＡＮ\",\"Butterfly\"]}")
        XCTAssertEqual(plan.keywords, ["貂蟬", "DIAOCHAN", "Butterfly"])
        let result = try LibraryTextSearch.search(query: "butterfly", snapshots: [LibrarySourceSnapshot(project: book(text: "这里没有模型建议的词。"))], additionalQueries: plan.keywords)
        XCTAssertTrue(result.matches.isEmpty, "模型只建议关键词，不能宣称已找到原文。")
    }

    func testExpansionPlanRejectsForgedResultsInstructionsAndMalformedPayloads() throws {
        for value in ["{\"keywords\":[\"貂蟬\"],\"results\":[{\"quote\":\"伪造\"}]}",
                      "{\"keywords\":[\"貂蟬\"],\"bookID\":\"other-book\"}", "[]", "{\"keywords\":[]}",
                      "{\"keywords\":[1]}", "{\"keywords\":\"貂蟬\"}", "{\"keywords\":[\" \"]}",
                      "{\"keywords\":[\"a\\u0000b\"]}", "```json\n{\"keywords\":[\"x\"]}\n```", "{\"keywords\":[\"x\"]"] {
            XCTAssertThrowsError(try LibrarySearchExpansionPlan.parse(value), value)
        }
        XCTAssertThrowsError(try LibrarySearchExpansionPlan(keywords: Array(repeating: "词", count: 9)))
        XCTAssertThrowsError(try LibrarySearchExpansionPlan(keywords: [String(repeating: "字", count: 81)]))
        XCTAssertThrowsError(try LibrarySearchExpansionPlan.parse(String(repeating: " ", count: 8_193)))
    }

    func testLanguageProfileUsesBoundedScopedSamplesWithoutChangingProject() throws {
        let sentence = "This is a book about reading, libraries, and language. The reader turns a page and studies the story. "
        let english = book(id: "english", text: String(repeating: sentence, count: 40))
        let chinese = book(id: "chinese", text: String(repeating: "這是一本談論閱讀與書庫的繁體中文書籍。", count: 80))
        let snapshots = [english, chinese].map { LibrarySourceSnapshot(project: $0) }
        let profile = try LibrarySearchLanguageProfile.identify(in: snapshots, bookID: "english")
        XCTAssertEqual(profile.languageCodes, ["en"])
        XCTAssertLessThanOrEqual(profile.sampledCharacterCount, 512)
        XCTAssertEqual(profile.summary, "英语")
        XCTAssertFalse(profile.isMixed)
        let absent = try LibrarySearchLanguageProfile.identify(in: snapshots, bookID: "missing")
        XCTAssertTrue(absent.languageCodes.isEmpty)
        XCTAssertEqual(absent.sampledCharacterCount, 0)
        XCTAssertEqual(english.units[0].text, String(repeating: sentence, count: 40))
        let many = Array(repeating: LibrarySourceSnapshot(project: english), count: 40)
        XCTAssertLessThanOrEqual(try LibrarySearchLanguageProfile.identify(in: many).sampledCharacterCount, 16_384)
    }

    func testCancelledExpansionAndLanguageTasksProduceNoResults() async throws {
        let snapshots = [LibrarySourceSnapshot(project: book(text: String(repeating: "貂蟬。", count: 100)))]
        let task = Task.detached { () throws -> LibrarySearchResponse in
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibraryTextSearch.search(query: "貂禅", snapshots: snapshots, additionalQueries: ["貂蝉"])
        }
        do { _ = try await task.value; XCTFail("取消的扩词检索不能留下结果。") }
        catch { XCTAssertTrue(error is CancellationError) }
        let language = Task.detached { () throws -> LibrarySearchLanguageProfile in
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibrarySearchLanguageProfile.identify(in: snapshots)
        }
        do { _ = try await language.value; XCTFail("取消的语言识别不能继续扫描。") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
