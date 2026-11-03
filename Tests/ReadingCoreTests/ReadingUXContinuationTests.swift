import Foundation
import XCTest
@testable import ReadingCore

final class ReadingUXContinuationTests: XCTestCase {
    private func project() -> BookProject {
        var book = BookProject(id: "preview-project", title: "复核", originalName: "source.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            .init(id: "u1", order: 0, chapter: "第一章", page: 1, text: "原文一"),
            .init(id: "u2", order: 1, chapter: "第二章", page: 2, text: "原文二")])
        book.documents = [.init(id: "n1", title: "普通笔记"), .init(id: "n2", title: "另一篇笔记")]
        for i in 0..<8 {
            let source = i.isMultiple(of: 2) ? "u1" : "u2"
            book.chats.append(.init(id: "q\(i)", role: "user", content: "问题\(i)", evidence: [.init(unitID: source, quote: "原文")]))
            book.chats.append(.init(id: "a\(i)", role: "assistant", content: "**回答\(i)**，见[unit:\(source)]。", evidence: [.init(unitID: source, quote: "原文")]))
        }
        return book
    }
    private func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testFoldedHintConvertsHostReferencesAndStrongFormattingWithoutExposingIDs() {
        let source = "**王允在试探**，见[unit:unit-000104][doc:secret-note]和[message:private-answer]。"
        let hint = FoldedReadingPreview.make(source)
        XCTAssertEqual(hint, "王允在试探，见原文笔记和历史对话。")
        XCTAssertFalse(hint.contains("secret-note")); XCTAssertFalse(hint.contains("private-answer"))
        XCTAssertFalse(hint.contains("folded-preview")); XCTAssertTrue(source.contains("unit-000104"))
    }
    func testFoldedHintRetainsCitationLiteralsInCodeMathAndEscapedText() {
        let source = "`[unit:code]` $[unit:math]$ \\[unit:escaped] [unit:actual]"
        let hint = FoldedReadingPreview.make(source)
        XCTAssertTrue(hint.contains("[unit:code]")); XCTAssertTrue(hint.contains("[unit:math]"))
        XCTAssertTrue(hint.contains("[unit:escaped]")); XCTAssertTrue(hint.hasSuffix(" 原文"))
        XCTAssertFalse(hint.contains("[unit:actual]"))
    }
    func testFoldedHintKeepsVariableUnderscoresMathAndWholeUnicodeGraphemes() {
        let source = "__要点__ 与 ~~旧说~~ $a_b + x*y$ e\u{301} 👩🏽‍💻"
        XCTAssertEqual(FoldedReadingPreview.make(source), "要点 与 旧说 $a_b + x*y$ e\u{301} 👩🏽‍💻")
        XCTAssertEqual(FoldedReadingPreview.make("**标题**\n\n正文", title: "标题"), "正文")
    }
    func testConcurrentFoldedHintsNeverMixRowContent() async {
        let results = await withTaskGroup(of: (Int, String).self, returning: [Int: String].self) { group in
            for i in 0..<80 {
                group.addTask { (i, FoldedReadingPreview.make("**标题\(i)**\n\n第\(i)条解释 [unit:unit-\(i)] e\u{301} 👩🏽‍💻", title: "标题\(i)")) }
            }
            var values: [Int: String] = [:]
            for await (i, text) in group { values[i] = text }
            return values
        }
        XCTAssertEqual(results.count, 80)
        for i in 0..<80 { XCTAssertEqual(results[i], "第\(i)条解释 原文 e\u{301} 👩🏽‍💻") }
    }
    func testScopedCatalogMatchesFullProjectionForEveryGroupingAndCallerOrder() throws {
        let book = project(), ids = ["chat:a5", "note:n1", "chat:q0", "chat:a0", "missing", "chat:a5"]
        let full = try ReadingRecordCatalog.prepare(in: book)
        let scoped = try ReadingRecordCatalog.prepare(in: book, recordIDs: Set(ids))
        XCTAssertEqual(scoped.records.count, 4)
        for mode in ReadingRecordGrouping.allCases {
            XCTAssertEqual(scoped.groups(ids: ids, by: mode), full.groups(ids: ids, by: mode))
        }
    }
    func testScopedCatalogKeepsQuestionFromAnUnofferedEarlierTurn() throws {
        let book = project()
        let row = try ReadingRecordCatalog.prepare(in: book, recordIDs: ["chat:a7"]).records["chat:a7"]
        XCTAssertEqual(row?.title, "回答：问题7")
        XCTAssertEqual(row?.chapterTitle, "第 2 页")
        XCTAssertEqual(row?.preview, "回答7，见原文。")
    }
    func testDeferredBrowserRowsMaterializeExactHintsWithoutChangingMetadataOrSource() throws {
        let book = project(), before = try data(book), ids: Set<String> = ["chat:a7", "chat:a0", "note:n1"]
        let full = try ReadingRecordCatalog.prepare(in: book, recordIDs: ids)
        let deferred = try ReadingRecordCatalog.prepare(in: book, recordIDs: ids, deferredPreviews: true)
        XCTAssertEqual(Set(deferred.records.keys), ids)
        for (id, row) in deferred.records {
            XCTAssertTrue(row.preview.isEmpty)
            var realized = row
            realized.preview = row.deferredPreview?.make() ?? row.preview
            realized.deferredPreview = nil
            XCTAssertEqual(realized, full.records[id])
        }
        XCTAssertEqual(try data(book), before)
    }
    func testScopedCatalogRejectsDuplicateEvenWhenThatIdentityWasNotRequested() throws {
        var book = project(); book.chats.append(book.chats[0])
        XCTAssertThrowsError(try ReadingRecordCatalog.prepare(in: book, recordIDs: ["note:n1"]))
        XCTAssertThrowsError(try ReadingRecordCatalog.prepare(in: book, recordIDs: []))
        XCTAssertThrowsError(try ReadingRecordCatalog.prepare(in: book))
    }
    func testScopedCatalogDoesNotInventUnknownOrTrashedNotes() throws {
        var book = project(); book.documents[0].trashedAt = Date()
        let catalog = try ReadingRecordCatalog.prepare(in: book, recordIDs: ["note:n1", "missing"])
        XCTAssertTrue(catalog.records.isEmpty)
    }
    func testScopedCatalogPreservesEverySavedFieldAndDoesNotChangeAutomaticHistory() throws {
        var book = project()
        book.readerCollections = ReaderCollectionState()
        let before = try data(book)
        _ = try ReadingRecordCatalog.prepare(in: book, recordIDs: ["note:n1", "chat:a1"])
        XCTAssertEqual(try data(book), before)
        XCTAssertEqual(book.readerCollections?.archivedChatIDs, [])
        XCTAssertEqual(book.chats.count, 16)
    }
    func testScopedAndFullCatalogHonorTaskCancellation() async {
        let book = project()
        for scoped in [false, true] {
            let task = Task { () throws -> ReadingRecordCatalog in
                withUnsafeCurrentTask { $0?.cancel() }
                if scoped { return try ReadingRecordCatalog.prepare(in: book, recordIDs: ["chat:a1"]) }
                return try ReadingRecordCatalog.prepare(in: book)
            }
            do { _ = try await task.value; XCTFail("Canceled projection must not publish a result") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }
    func testNativePDFQueryIncludesBothChineseScriptsAndKeepsOriginalFirst() {
        let simple = NativePDFSearchQuery.terms(for: "貂蝉")
        XCTAssertEqual(simple.first, "貂蝉"); XCTAssertTrue(simple.contains("貂蟬"))
        let traditional = NativePDFSearchQuery.terms(for: "貂蟬")
        XCTAssertEqual(traditional.first, "貂蟬"); XCTAssertTrue(traditional.contains("貂蝉"))
        XCTAssertEqual(simple.count, Set(simple).count)
    }
    func testNativePDFQueryKeepsMixedTextAndDoesNotInventTranslationOrCorrection() {
        let terms = NativePDFSearchQuery.terms(for: "  Hero 貂蝉 e\u{301} 👩🏽‍💻  ")
        XCTAssertEqual(terms.first, "Hero 貂蝉 e\u{301} 👩🏽‍💻")
        XCTAssertTrue(terms.contains("Hero 貂蟬 e\u{301} 👩🏽‍💻"))
        XCTAssertEqual(NativePDFSearchQuery.terms(for: "Diao Chan"), ["Diao Chan"])
        XCTAssertFalse(NativePDFSearchQuery.terms(for: "貂禅").contains("貂蝉"))
    }
    func testNativePDFQueryBoundsInputAndAvoidsDuplicateEquivalentSpellings() {
        XCTAssertTrue(NativePDFSearchQuery.terms(for: " \n").isEmpty)
        XCTAssertTrue(NativePDFSearchQuery.terms(for: String(repeating: "字", count: 501)).isEmpty)
        XCTAssertEqual(NativePDFSearchQuery.terms(for: "三国"), ["三国", "三國"])
        XCTAssertEqual(NativePDFSearchQuery.terms(for: "王允"), ["王允"])
        XCTAssertEqual(NativePDFSearchQuery.terms(for: "A é"), ["A é"])
    }
}
