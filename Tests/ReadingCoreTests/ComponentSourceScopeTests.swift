import Foundation
import XCTest
@testable import ReadingCore

final class ComponentSourceScopeTests: XCTestCase {
    private func book() -> BookProject {
        var book = BookProject(id: "scope-book", title: "共享资料", originalName: "fixture.txt", sourceHash: "source", units: [
            .init(id: "u1", order: 0, chapter: "开头", page: 1, text: "刘备结识关羽。"),
            .init(id: "u2", order: 1, chapter: "本页", page: 2, text: "甲方说法。乙方隐情。"),
            .init(id: "u2b", order: 2, chapter: "本页", page: 2, text: "张飞来到这里。"),
            .init(id: "u3", order: 3, chapter: "后文", page: 3, text: "后文人物出现。")])
        PluginEngine.seed(&book)
        book.entities = [
            .init(id: "liu", typeID: "person", name: "刘备", summary: "刘备结识关羽。", evidence: [.init(unitID: "u1", quote: "刘备结识关羽。")]),
            .init(id: "a", typeID: "person", name: "甲方", summary: "甲方说法。", evidence: [.init(unitID: "u2", quote: "甲方说法。")]),
            .init(id: "b", typeID: "person", name: "乙方", summary: "乙方隐情。", evidence: [.init(unitID: "u2", quote: "乙方隐情。")]),
            .init(id: "zhang", typeID: "person", name: "张飞", summary: "张飞来到这里。", evidence: [.init(unitID: "u2b", quote: "张飞来到这里。")]),
            .init(id: "future", typeID: "person", name: "后文人物", summary: "后文人物出现。", evidence: [.init(unitID: "u3", quote: "后文人物出现。")])]
        book.temporalKnowledge = .init(profile: .init(avoidsSpoilers: true))
        return book
    }
    private func definition(_ scope: CompositionScope = .book) -> CompositionDefinition {
        .init(sources: [.init(id: "objects", collection: .objects, scope: scope)],
            parts: [.init(id: "list", primitive: .objectList, sourceID: "objects")],
            layout: [.init(id: "root", kind: .part, partID: "list")], rootID: "root")
    }
    private func ids(_ scope: ReadingQuerySnapshot, in book: BookProject, binding: CompositionScope = .book) throws -> Set<String> {
        let input = try CompositionRuntime.prepare(definition(binding), in: book,
            context: .init(unitID: "u1", page: 1),
            boundary: KnowledgeReadBoundary.throughSourceUnit("u1", in: book), sourceSnapshot: scope)
        return Set(try CompositionRuntime.project(input)["objects"]!.items.map(\.id))
    }

    func testExplicitFullBookComponentUsesAllFrozenSourcesDespiteReaderCutoff() throws {
        let book = book(), scope = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        XCTAssertEqual(try ids(scope, in: book), Set(book.entities.map(\.id)))
        XCTAssertEqual(try ids(scope, in: book, binding: .current), Set(book.entities.map(\.id)))
        XCTAssertEqual(book.temporalKnowledge?.profile?.avoidsSpoilers, true)
    }
    func testPageComponentIncludesWholePDFPageAndNoPreviousOrFuturePage() throws {
        let book = book(), scope = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u2", page: 2))
        XCTAssertEqual(try ids(scope, in: book), ["a", "b", "zhang"])
        let result = try ReadingComponentProjection.project(scope, in: book)
        XCTAssertEqual(result.units.map(\.id), ["u2", "u2b"])
        XCTAssertEqual(Set(result.entities.map(\.id)), ["a", "b", "zhang"])
    }
    func testReadSoFarScopeDoesNotFollowSubsequentCursorOrComponentBinding() throws {
        let book = book(), scope = try ReadingQuerySnapshot.freeze(scope: .readSoFar, in: book, context: .init(unitID: "u2", page: 2))
        XCTAssertEqual(try ids(scope, in: book), ["liu", "a", "b", "zhang"])
        XCTAssertEqual(try ids(scope, in: book, binding: .current), ["liu", "a", "b", "zhang"])
        XCTAssertFalse(try ReadingComponentProjection.project(scope, in: book).entities.contains { $0.id == "future" })
    }
    func testSelectionComponentKeepsExactTextAndDoesNotAcquireOtherHalfOfUnit() throws {
        let book = book(), scope = try ReadingQuerySnapshot.freeze(scope: .selection, in: book,
            context: .init(unitID: "u2", selectedText: "甲方说法。", page: 2))
        let result = try ReadingComponentProjection.project(scope, in: book)
        XCTAssertEqual(result.units.map(\.text), ["甲方说法。"])
        XCTAssertEqual(result.entities.map(\.id), ["a"])
        XCTAssertEqual(try ids(scope, in: book), ["a"])
        XCTAssertEqual(try ids(scope, in: book, binding: .current), ["a"])
    }
    func testDefaultCompositionRetainsItsExistingSpoilerBoundary() throws {
        let book = book(), cutoff = try KnowledgeReadBoundary.throughSourceUnit("u1", in: book)
        let result = try CompositionRuntime.project(definition(), in: book, context: .init(unitID: "u2", page: 2), boundary: cutoff)
        XCTAssertEqual(result["objects"]?.items.map(\.id), ["liu"])
    }
    func testComponentScopeCannotBeReusedAcrossBookSourceOrChangedOriginalText() throws {
        let book = book(), scope = try ReadingQuerySnapshot.freeze(scope: .selection, in: book,
            context: .init(unitID: "u2", selectedText: "甲方说法。", page: 2))
        var other = book; other.id = "other"
        XCTAssertThrowsError(try ReadingComponentProjection.project(scope, in: other))
        XCTAssertThrowsError(try ids(scope, in: other))
        other = book; other.sourceHash = "replacement"
        XCTAssertThrowsError(try ReadingComponentProjection.project(scope, in: other))
        other = book; other.units[1].text = "另一份甲方说法。"
        XCTAssertThrowsError(try ReadingComponentProjection.project(scope, in: other))
        XCTAssertThrowsError(try ids(scope, in: other))
    }
    func testFullBookProjectionRejectsAnIndexExtendedAfterTheQuestion() throws {
        let book = book(), scope = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        var changed = book; changed.units.append(.init(id: "new", order: 4, chapter: "新提取", page: 4, text: "后提取的正文。"))
        XCTAssertThrowsError(try ReadingComponentProjection.project(scope, in: changed))
        XCTAssertThrowsError(try ids(scope, in: changed))
    }
    func testNewAnalysisInFrozenSourcesAppearsWithoutDuplicatingOrChangingCanonicalBook() throws {
        var book = book(); let scope = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u2", page: 2))
        book.entities.append(.init(id: "new-a", typeID: "person", name: "甲方说法", evidence: [.init(unitID: "u2", quote: "甲方说法。")]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(book)
        let result = try ReadingComponentProjection.project(scope, in: book)
        XCTAssertTrue(result.entities.contains { $0.id == "new-a" })
        XCTAssertEqual(try encoder.encode(book), before)
        XCTAssertEqual(Set(result.entities.map(\.id)).count, result.entities.count)
    }
    func testNarrowScopeOmitsUnrelatedNotesAndGlobalSummariesButKeepsOriginalRecords() throws {
        var book = book()
        book.entities.append(.init(id: "masked", typeID: "person", name: "后文身份", summary: "后文说明", aliases: ["甲方"],
            evidence: [.init(unitID: "u2", quote: "甲方说法。"), .init(unitID: "u3", quote: "后文人物出现。")]))
        book.documents = [.init(id: "current-note", title: "本页资料", evidence: [.init(unitID: "u2", quote: "甲方说法。")]),
            .init(id: "future-note", title: "后文资料", evidence: [.init(unitID: "u3", quote: "后文人物出现。")]),
            .init(id: "personal", title: "未附加的私人笔记")]
        book.insights = [.init(id: "whole", unitIDs: ["u1", "u3"], markdown: "跨页总结"),
            .init(id: "local", unitIDs: ["u2"], markdown: "本页总结")]
        let page = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u2", page: 2))
        let result = try ReadingComponentProjection.project(page, in: book)
        XCTAssertEqual(result.documents.map(\.id), ["current-note"])
        XCTAssertEqual(result.insights.map(\.id), ["local"])
        XCTAssertEqual(result.entities.first { $0.id == "masked" }?.name, "甲方")
        XCTAssertEqual(result.entities.first { $0.id == "masked" }?.summary, "")
        XCTAssertEqual(book.entities.first { $0.id == "masked" }?.name, "后文身份")
        let full = try ReadingComponentProjection.project(ReadingQuerySnapshot.freeze(scope: .book, in: book), in: book)
        XCTAssertEqual(full.documents, book.documents)
        XCTAssertEqual(book.documents.count, 3)
    }
    func testPartialUnitSelectionCannotReuseWholeUnitSummaryOrFutureCanvasNodes() throws {
        var book = book(); book.insights = [.init(id: "unit-summary", unitIDs: ["u2"], markdown: "甲乙双方")]
        book.nodes = [.init(id: "a-node", targetID: "a"), .init(id: "b-node", targetID: "b")]
        book.edges = [.init(id: "line", fromID: "a-node", toID: "b-node")]
        let scope = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: .init(unitID: "u2", selectedText: "甲方说法。", page: 2))
        let result = try ReadingComponentProjection.project(scope, in: book)
        XCTAssertTrue(result.insights.isEmpty)
        XCTAssertEqual(result.nodes.map(\.id), ["a-node"])
        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertEqual(book.nodes.count, 2); XCTAssertEqual(book.edges.count, 1)
    }
    func testChapterSharedWithNextChapterUsesExactSliceInBothComponentBindings() throws {
        var book = book()
        book.units = [.init(id: "shared", order: 0, chapter: "章界", page: 1, text: "第一章\n甲方说法。\n第二章\n乙方隐情。")]
        let entries = try ["第一章", "第二章"].map { title -> BookOutlineEntry in
            let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "shared", quote: title, in: book)
            return .init(id: anchor.id, title: title, page: 1, anchor: anchor)
        }
        book.originalBookOutline = .init(sourceHash: book.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: book),
            scannedUnitCount: 1, totalUnitCount: 1, entries: entries)
        book.entities = [.init(id: "a", typeID: "person", name: "甲方", evidence: [.init(unitID: "shared", quote: "甲方说法。")]),
                         .init(id: "b", typeID: "person", name: "乙方", evidence: [.init(unitID: "shared", quote: "乙方隐情。")])]
        let scope = try ReadingQuerySnapshot.freeze(scope: .chapter, in: book,
            context: .init(unitID: "shared", page: 1, selectedSourceAnchor: entries[0].anchor))
        let projected = try ReadingComponentProjection.project(scope, in: book)
        XCTAssertEqual(projected.units.map(\.text), ["第一章\n甲方说法。\n"])
        for binding in [CompositionScope.book, .current] {
            let prepared = try CompositionRuntime.prepare(definition(binding), in: book, sourceSnapshot: scope)
            XCTAssertEqual(try CompositionRuntime.project(prepared)["objects"]?.items.map(\.id), ["a"])
        }
    }
    func testComponentLocalDocumentsDoNotWidenModelSnapshotOrWriteGrant() throws {
        var book = book()
        book.documents = [.init(id: "local", title: "页内资料", evidence: [.init(unitID: "u2", quote: "甲方说法。")])]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u2", page: 2))
        XCTAssertTrue(snapshot.documentIDs.isEmpty)
        XCTAssertEqual(try ReadingComponentProjection.project(snapshot, in: book).documents.map(\.id), ["local"])
        XCTAssertTrue(snapshot.documentIDs.isEmpty)
        XCTAssertTrue(snapshot.authorizedNodeIDs.isEmpty)
        XCTAssertFalse(snapshot.admits(.init(unitID: "u3", quote: "后文人物出现。")))
    }
}
