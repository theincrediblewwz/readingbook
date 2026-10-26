import Foundation
import XCTest
@testable import ReadingCore

final class ChapterKnowledgeScopeTests: XCTestCase {
    private func sharedUnitBook() throws -> (BookProject, SourceAnchor, SourceAnchor, SourceAnchor) {
        let first = "甲章\n共用词\n甲事实。\n", second = "乙章\n共用词\n乙秘密。"
        var book = BookProject(id: "chapter-knowledge", title: "测试书", originalName: "book.pdf", sourceHash: "source",
            units: [SourceUnit(id: "u", order: 0, chapter: "测试书", page: 1, text: first + second)])
        PluginEngine.seed(&book)
        book.entities = [KnowledgeEntity(id: "person", typeID: "person", name: "共用词", evidence: [Evidence(unitID: "u", quote: "共用词")])]
        func anchor(_ quote: String, prefix: String) throws -> SourceAnchor {
            try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u", quote: quote, prefix: prefix, in: book)
        }
        let firstAnchor = try anchor("共用词", prefix: "甲章\n")
        let secondAnchor = try anchor("共用词", prefix: "乙章\n")
        let scope = try anchor(first, prefix: "")
        book.readingExperience = ReadingExperienceState(anchors: [firstAnchor, secondAnchor], layers: [
            ReadingLayer(id: "first-layer", kind: "explanation", title: "本章解释", markdown: "甲章原有解释。", sourceAnchorIDs: [firstAnchor.id]),
            ReadingLayer(id: "second-layer", kind: "explanation", title: "后章解释", markdown: "乙章尚未获准的秘密。", sourceAnchorIDs: [secondAnchor.id])
        ])
        book.temporalKnowledge = TemporalKnowledgeState(anchors: [firstAnchor, secondAnchor], presences: [
            EntityPresence(id: "first-presence", entityID: "person", action: "甲章出现", sourceAnchorIDs: [firstAnchor.id]),
            EntityPresence(id: "second-presence", entityID: "person", action: "乙章出现", sourceAnchorIDs: [secondAnchor.id])
        ])
        return (book, firstAnchor, secondAnchor, scope)
    }

    func testQueryAnchorScopeUsesOccurrenceInsteadOfRepeatedQuote() throws {
        let (book, first, second, scope) = try sharedUnitBook()
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: book,
            context: ReadingContext(sourceHash: book.sourceHash, unitID: "u", selectedText: scope.quote, page: 1, selectedSourceAnchor: scope))
        XCTAssertTrue(snapshot.admits(Evidence(unitID: "u", quote: second.quote)), "引文字面相同，必须再检查锚的实际位置")
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let cropped = try XCTUnwrap(session.scopedKnowledgeProject())
        XCTAssertEqual(Set(cropped.readingExperience?.anchors.map(\.id) ?? []), [first.id])
        XCTAssertEqual(cropped.readingExperience?.layers.map(\.id), ["first-layer"])
        XCTAssertEqual(Set(cropped.temporalKnowledge?.anchors.map(\.id) ?? []), [first.id])
        XCTAssertEqual(cropped.temporalKnowledge?.presences.map(\.id), ["first-presence"])
        XCTAssertEqual(book.readingExperience?.layers.count, 2, "只裁查询投影，不改原数据")
    }

    func testAnalysisExcerptResolvesAnchorsAgainstCanonicalUnit() throws {
        let (book, first, second, scope) = try sharedUnitBook()
        let length = scope.quote.utf16.count
        let ranges = [ReadingSourceRange(unitID: "u", startUTF16: 0, endUTF16: length)]
        let grant = ReadingEnrichmentAuthority.Grant(bookID: book.id, sourceHash: book.sourceHash, unitID: "u",
            unitHash: try BookImporter.sha256(Data(book.units[0].text.utf8)), ranges: ranges)
        let cropped = try ReadingEnrichmentAuthority.$current.withValue(grant) {
            try PluginEngine.analysisContextProject(book, allowedUnitIDs: ["u"])
        }
        XCTAssertEqual(cropped.units.first?.text, scope.quote)
        XCTAssertEqual(Set(cropped.readingExperience?.anchors.map(\.id) ?? []), [first.id], "合法锚不能拿片段的hash误拒")
        XCTAssertFalse(cropped.readingExperience?.anchors.contains(where: { $0.id == second.id }) ?? true)
        XCTAssertEqual(cropped.readingExperience?.layers.map(\.id), ["first-layer"])
        XCTAssertEqual(cropped.temporalKnowledge?.presences.map(\.id), ["first-presence"])
    }

    func testOrdinaryKnowledgeLookupIgnoresUnrelatedAnalysisSessionRange() throws {
        var book = BookProject(id: "independent-scope", title: "测试书", originalName: "book.pdf", sourceHash: "source", units: [
            SourceUnit(id: "a", order: 0, chapter: "甲章", page: 1, text: "甲章记刘备。"),
            SourceUnit(id: "b", order: 1, chapter: "乙章", page: 2, text: "赵云在乙章出现。")
        ])
        PluginEngine.seed(&book)
        book.entities = [KnowledgeEntity(id: "zhao", typeID: "person", name: "赵云", summary: "乙章已有简介。",
            evidence: [Evidence(unitID: "b", quote: "赵云在乙章出现。")])]
        var session = SmartReadingSession(selection: SmartReadingSelection(scope: .currentChapter, execution: .init()), scopeTitle: "甲章",
            unitIDs: ["a"], unitHashes: ["a": try BookImporter.sha256(Data(book.units[0].text.utf8))], sourceHash: book.sourceHash)
        session.sourceRanges = [ReadingSourceRange(unitID: "a", startUTF16: 0, endUTF16: book.units[0].text.utf16.count)]
        book.smartReading = session
        let lookup = try PluginEngine.analysisContextProject(book, allowedUnitIDs: ["b"])
        XCTAssertEqual(lookup.units.map(\.id), ["b"])
        XCTAssertEqual(lookup.entities.first?.id, "zhao")
        XCTAssertEqual(lookup.entities.first?.summary, "乙章已有简介。")
        XCTAssertEqual(PluginEngine.analysisIdentityCandidates(book, allowedUnitIDs: ["b"]).map(\.id), ["zhao"])
        XCTAssertEqual(book.smartReading?.sourceRanges, session.sourceRanges)
    }

    func testRepeatedLegacyEvidenceKeepsIdentityWithoutBorrowingLaterSummary() throws {
        let first = "第一章\n贾诩初到城中。\n", second = "第二章\n贾诩后来另有身份。"
        var book = BookProject(id: "repeated-evidence", title: "测试书", originalName: "book.pdf",
            sourceHash: try BookImporter.sha256(Data((first + second).utf8)),
            units: [SourceUnit(id: "u", order: 0, chapter: "测试书", page: 1, text: first + second)])
        PluginEngine.seed(&book)
        let evidence = Evidence(unitID: "u", quote: "贾诩")
        book.entities = [KnowledgeEntity(id: "jia", typeID: "person", name: "贾诩", summary: "第二章才揭示的秘密。",
            properties: ["role": "后文身份"], evidence: [evidence]),
            KnowledgeEntity(id: "city", typeID: "place", name: "城中", evidence: [Evidence(unitID: "u", quote: "贾诩初到城中。")])]
        book.relations = [KnowledgeRelation(id: "later-relation", fromID: "jia", toID: "city", label: "后章关系", evidence: [evidence])]
        let scope = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u", quote: first, in: book)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: book,
            context: ReadingContext(sourceHash: book.sourceHash, unitID: "u", selectedText: first, page: 1, selectedSourceAnchor: scope))
        let ranges = try snapshot.sourceRanges(in: book)
        XCTAssertTrue(snapshot.admits(evidence), "新的所选原文引用仍获准，不能因重复名字一并禁掉")
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let cropped = try XCTUnwrap(session.scopedKnowledgeProject())
        XCTAssertEqual(cropped.entities.first?.name, "贾诩")
        XCTAssertEqual(cropped.entities.first?.summary, "")
        XCTAssertTrue(cropped.entities.first?.properties.isEmpty == true)
        XCTAssertTrue(cropped.relations.isEmpty)
        XCTAssertTrue(session.isIdentityStub("jia"))
        XCTAssertNil(SavedKnowledgeReuse(project: book, currentUnitIDs: ["u"], currentSlices: ["u": first], currentRanges: ranges)?.record(id: "jia"))
        let grant = ReadingEnrichmentAuthority.Grant(bookID: book.id, sourceHash: book.sourceHash, unitID: "u",
            unitHash: try BookImporter.sha256(Data(book.units[0].text.utf8)), ranges: ranges)
        let analysis = try ReadingEnrichmentAuthority.$current.withValue(grant) {
            try PluginEngine.analysisContextProject(book, allowedUnitIDs: ["u"])
        }
        XCTAssertEqual(analysis.entities.first?.summary, "", "片段投影不能把裁剪后的文本冒充完整canonical源")
        XCTAssertEqual(book.entities.first?.summary, "第二章才揭示的秘密。", "保留完整原记录")
    }

    func testOlderUnambiguousVersionSurvivesNewerRepeatedEvidence() throws {
        let first = "第一章\n贾诩初到城中。\n", second = "第二章\n贾诩后来另有身份。"
        var earlier = BookProject(id: "versioned-evidence", title: "测试书", originalName: "book.pdf",
            sourceHash: try BookImporter.sha256(Data((first + second).utf8)),
            units: [SourceUnit(id: "u", order: 0, chapter: "测试书", page: 1, text: first + second)])
        PluginEngine.seed(&earlier)
        earlier.entities = [KnowledgeEntity(id: "jia", typeID: "person", name: "贾诩", summary: "第一章已保存的简介。",
            evidence: [Evidence(unitID: "u", quote: "贾诩初到城中。")])]
        var later = earlier
        later.entities[0].summary = "第二章的秘密介绍。"
        later.entities[0].evidence = [Evidence(unitID: "u", quote: "贾诩")]
        try ReadingKnowledgeRuntime.captureVersions(before: earlier, in: &later)
        let range = ReadingSourceRange(unitID: "u", startUTF16: 0, endUTF16: first.utf16.count)
        let reuse = try XCTUnwrap(SavedKnowledgeReuse(project: later, currentUnitIDs: ["u"], currentSlices: ["u": first], currentRanges: [range]))
        XCTAssertEqual(reuse.entity(later.entities[0])?.summary, "第一章已保存的简介。", "拒绝最新不明确版本后仍须继续找安全旧版")
        let full = ReadingSourceRange(unitID: "u", startUTF16: 0, endUTF16: later.units[0].text.utf16.count)
        let complete = try XCTUnwrap(SavedKnowledgeReuse(project: later, currentUnitIDs: ["u"], currentSlices: ["u": later.units[0].text], currentRanges: [full]))
        XCTAssertEqual(complete.entity(later.entities[0])?.summary, "第二章的秘密介绍。", "全单元已获准时保留原有复用能力")
        XCTAssertEqual(later.readingKnowledge?.versions.count, 2)
    }

    func testChapterSliceStillReusesSafeEarlierUnits() throws {
        var book = BookProject(id: "earlier-unit-evidence", title: "测试书", originalName: "book.pdf", sourceHash: "source", units: [
            SourceUnit(id: "past", order: 0, chapter: "前章", page: 1, text: "贾诩初到城中。"),
            SourceUnit(id: "current", order: 1, chapter: "当前章", page: 2, text: "贾诩又出现。下一章秘密。")
        ])
        PluginEngine.seed(&book)
        book.entities = [KnowledgeEntity(id: "jia", typeID: "person", name: "贾诩", summary: "前章已保存的简介。",
            evidence: [Evidence(unitID: "past", quote: "贾诩初到城中。")])]
        let range = ReadingSourceRange(unitID: "current", startUTF16: 0, endUTF16: "贾诩又出现。".utf16.count)
        let reuse = try XCTUnwrap(SavedKnowledgeReuse(project: book, currentUnitIDs: ["current"], currentSlices: ["current": "贾诩又出现。"], currentRanges: [range]))
        XCTAssertEqual(reuse.entity(book.entities[0])?.summary, "前章已保存的简介。")
    }
}
