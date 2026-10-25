import Foundation
import XCTest
@testable import ReadingCore

final class AnalysisContextTests: XCTestCase {
    private func project() throws -> BookProject {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: "神秘人路过，青衣客停下。"),
            SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "神秘人原来是曹操；青衣客原来是许褚。此处揭晓结局。")]
        var book = BookProject(title: "范围", originalName: "scope.txt", sourceHash: try BookImporter.sha256(Data(units.map(\.text).joined().utf8)), units: units)
        PluginEngine.seed(&book)
        let local = Evidence(unitID: "u1", quote: units[0].text), future = Evidence(unitID: "u2", quote: units[1].text)
        book.entities = [KnowledgeEntity(id: "person1", typeID: "person", name: "曹操", summary: "后文结局", properties: ["身份": "隐藏身份"], aliases: ["神秘人"], evidence: [local, future]),
            KnowledgeEntity(id: "person2", typeID: "person", name: "许褚", summary: "未来分析", aliases: ["青衣客"], evidence: [future])]
        book.documents = [DocumentRecord(id: "secret-note", title: "秘密笔记", evidence: [future])]
        book.coverage["u1"]?.status = .completed; book.coverage["u2"]?.status = .completed
        return book
    }

    func testAnalysisSearchKeepsStableIdentityWithoutFutureFactsOrNotes() throws {
        var book = try project()
        func search(_ query: String, allowed: Set<String>) throws -> String {
            try PluginEngine.apply(name: "knowledge_search", arguments: JSONSerialization.data(withJSONObject: ["query": query]), to: &book, allowedUnitIDs: allowed, phase: .reading)
        }
        let local = try search("神秘人", allowed: ["u1"])
        XCTAssertTrue(local.contains("person1")); XCTAssertFalse(local.contains("曹操")); XCTAssertFalse(local.contains("后文结局")); XCTAssertFalse(local.contains("隐藏身份"))
        let candidate = try search("青衣客", allowed: ["u1"])
        XCTAssertTrue(candidate.contains("person2")); XCTAssertTrue(candidate.contains("identityOnly"))
        XCTAssertFalse(candidate.contains("许褚")); XCTAssertFalse(candidate.contains("未来分析"))
        XCTAssertFalse(try search("曹操", allowed: ["u1"]).contains("person1"))
        XCTAssertFalse(try search("秘密笔记", allowed: ["u1"]).contains("secret-note"))
        XCTAssertFalse(try search("神秘人", allowed: []).contains("person1"), "Old completed coverage is not a read grant.")
        XCTAssertThrowsError(try search("神秘人", allowed: ["missing"]))
    }

    func testAnalysisIndexRejectsCrossBoundaryLayersAndAllForeignAnchors() throws {
        var book = try project()
        let anchors = try book.units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.id, quote: $0.text, in: book) }
        book.readingExperience = ReadingExperienceState(anchors: anchors,
            layers: [ReadingLayer(id: "local", kind: "commentary", title: "本地", markdown: "本地解释", sourceAnchorIDs: [anchors[0].id]),
                ReadingLayer(id: "mixed", kind: "commentary", title: "跨页结局", markdown: "范围外完整结局", sourceAnchorIDs: anchors.map(\.id)),
                ReadingLayer(id: "future", kind: "commentary", title: "后页", markdown: "后页分析", sourceAnchorIDs: [anchors[1].id])],
            alignments: [ReferenceAlignment(id: "mixed-alignment", sourceAnchorIDs: anchors.map(\.id), title: "后页资料标题", markdown: "后页资料正文")])
        let scoped = try PluginEngine.analysisContextProject(book, allowedUnitIDs: ["u1"])
        XCTAssertEqual(scoped.units.map(\.id), ["u1"])
        XCTAssertEqual(scoped.entities.first?.name, "神秘人"); XCTAssertEqual(scoped.entities.first?.summary, ""); XCTAssertTrue(scoped.entities.first!.properties.isEmpty)
        XCTAssertTrue(scoped.documents.isEmpty)
        XCTAssertEqual(scoped.readingExperience?.anchors.map(\.unitID), ["u1"])
        XCTAssertEqual(scoped.readingExperience?.layers.map(\.id), ["local"])
        XCTAssertTrue(scoped.readingExperience!.alignments.isEmpty)
    }

    func testRawReuseCannotRestoreCanonicalIdentityMissingFromItsEarlierEvidence() async throws {
        var book = try project()
        book.entities[0].evidence = [Evidence(unitID: "u1", quote: "神秘人")]
        let original = book.entities[0]
        let scoped = try PluginEngine.analysisContextProject(book, allowedUnitIDs: ["u1"])
        let identity = try XCTUnwrap(scoped.entities.first { $0.id == original.id })
        XCTAssertEqual(identity.name, "神秘人"); XCTAssertTrue(identity.summary.isEmpty); XCTAssertTrue(identity.properties.isEmpty)
        let saved = try XCTUnwrap(SavedKnowledgeReuse(project: book, currentUnitIDs: ["u1"])?.record(id: original.id))
        XCTAssertEqual(saved["summary"] as? String, ""); XCTAssertEqual(saved["sourceUnitIDs"] as? [String], ["u1"])
        let result = try PluginEngine.apply(name: "knowledge_search", arguments: Data(#"{"query":"神秘人"}"#.utf8), to: &book, allowedUnitIDs: ["u1"], phase: .reading)
        XCTAssertTrue(result.contains(original.id)); XCTAssertFalse(result.contains("曹操")); XCTAssertFalse(result.contains("后文结局")); XCTAssertFalse(result.contains("隐藏身份"))
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u1", page: 1))
        var query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let lookup = try await query.execute(name: "object_get", arguments: ["id": original.id], maximumBytes: 8000)
        XCTAssertTrue(lookup.contains(original.id)); XCTAssertFalse(lookup.contains("曹操")); XCTAssertFalse(lookup.contains("后文结局"))
        XCTAssertEqual(book.entities[0], original, "候选与previouslySaved均为只读投影，不改完整旧卡片。")
    }

    func testLaterChunkReusesPriorSavedSummaryWithoutGrantingEarlierSourceReads() async throws {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "开篇", page: 1, text: "贾诩善于谋划。"),
                     SourceUnit(id: "u2", order: 1, chapter: "次回", page: 2, text: "贾诩又来到了这里。")]
        var book = BookProject(title: "复用", originalName: "reuse.txt", sourceHash: "source", units: units)
        PluginEngine.seed(&book)
        book.entities = [KnowledgeEntity(id: "jia", typeID: "person", name: "贾诩", summary: "贾诩是一位善于谋划的人。", evidence: [Evidence(unitID: "u1", quote: "贾诩善于谋划。")])]
        let result = try PluginEngine.apply(name: "knowledge_search", arguments: Data(#"{"query":"贾诩"}"#.utf8), to: &book, allowedUnitIDs: ["u2"], phase: .reading)
        XCTAssertTrue(result.contains("jia")); XCTAssertTrue(result.contains("善于谋划的人")); XCTAssertTrue(result.contains("previouslySaved"))
        let scoped = try PluginEngine.analysisContextProject(book, allowedUnitIDs: ["u2"])
        XCTAssertEqual(scoped.units.map(\.id), ["u2"]); XCTAssertEqual(scoped.entities.first?.id, "jia")
        XCTAssertEqual(scoped.entities.first?.evidence.map(\.unitID), ["u1"])
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u2", page: 2))
        var query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let lookup = try await query.execute(name: "object_get", arguments: ["id": "jia"], maximumBytes: 8000)
        XCTAssertTrue(lookup.contains("previouslySaved")); XCTAssertTrue(lookup.contains("善于谋划的人"))
        XCTAssertTrue(query.sourceExcerpts.isEmpty, "旧摘要不会自动成为本轮原文引用许可。")
        do { _ = try await query.execute(name: "source_read", arguments: ["id": "u1"], maximumBytes: 8000); XCTFail("不能因复用简介扩大原文读取范围。") } catch {}
    }

    func testAggregateWithFutureOrInvalidSourceNeverBecomesReusablePastFact() async throws {
        var book = try project()
        book.units.append(SourceUnit(id: "u3", order: 2, chapter: "后续", page: 3, text: "神秘人再次出现。"))
        let mixed = try PluginEngine.analysisContextProject(book, allowedUnitIDs: ["u1"])
        XCTAssertFalse(mixed.entities.contains(where: { !$0.summary.isEmpty }))
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "u1", page: 1))
        var query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let lookup = try await query.execute(name: "object_get", arguments: ["id": "person1"], maximumBytes: 8000)
        XCTAssertFalse(lookup.contains("previouslySaved")); XCTAssertFalse(lookup.contains("后文结局")); XCTAssertFalse(lookup.contains("曹操"))
        book.entities[0].evidence = [Evidence(unitID: "u1", quote: "原文并没有这一句")]
        let invalid = SavedKnowledgeReuse(project: book, currentUnitIDs: ["u3"])
        XCTAssertNil(invalid?.record(id: "person1"), "OCR或来源改变后，旧引文失效就不能复用聚合内容。")
    }

    func testSelectionReuseAdmitsOnlyNamesInsideSliceAndRejectsSameUnitOutsideFacts() async throws {
        let units = [SourceUnit(id: "u0", order: 0, chapter: "此前", page: 1, text: "贾诩善谋。"),
                     SourceUnit(id: "u1", order: 1, chapter: "此处", page: 2, text: "贾诩在此。甲地出现了。贾诩后来统领军队。")]
        var book = BookProject(title: "选段", originalName: "selection.txt", sourceHash: "source", units: units)
        PluginEngine.seed(&book)
        book.entities = [
            KnowledgeEntity(id: "known", typeID: "person", name: "贾诩", summary: "早先是一位善谋的人。", aliases: ["甲地的谋士"], evidence: [Evidence(unitID: "u0", quote: "贾诩善谋。")]),
            KnowledgeEntity(id: "outside", typeID: "place", name: "甲地", summary: "本页选段外的地点。", evidence: [Evidence(unitID: "u1", quote: "甲地出现了。")]),
            KnowledgeEntity(id: "mixed", typeID: "person", name: "贾诩", summary: "本页后面才讲到统领军队。", evidence: [Evidence(unitID: "u0", quote: "贾诩善谋。"), Evidence(unitID: "u1", quote: "贾诩后来统领军队。")])
        ]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: book, context: ReadingContext(unitID: "u1", selectedText: "贾诩在此。", page: 2))
        var query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let found = try await query.execute(name: "objects_search", arguments: ["query": "贾诩"], maximumBytes: 8000)
        XCTAssertTrue(found.contains("known")); XCTAssertTrue(found.contains("早先是一位善谋的人"))
        XCTAssertFalse(found.contains("mixed")); XCTAssertFalse(found.contains("统领军队")); XCTAssertFalse(found.contains("甲地的谋士"))
        let alias = try await query.execute(name: "objects_search", arguments: ["query": "甲地的谋士"], maximumBytes: 8000)
        XCTAssertFalse(alias.contains("known"), "选段外的别名不能成为本次身份命中条件。")
        for id in ["outside", "mixed"] {
            do { _ = try await query.execute(name: "object_get", arguments: ["id": id], maximumBytes: 8000); XCTFail("选段不能读取同unit的范围外知识：\(id)") } catch {}
        }
        let reused = try await query.execute(name: "object_get", arguments: ["id": "known"], maximumBytes: 8000)
        XCTAssertTrue(reused.contains("previouslySaved")); XCTAssertFalse(reused.contains("甲地的谋士"))
        XCTAssertFalse(snapshot.admits(Evidence(unitID: "u0", quote: "贾诩善谋。")))
        XCTAssertTrue(query.sourceExcerpts.isEmpty)
    }
}
