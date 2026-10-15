import Foundation
import XCTest
@testable import ReadingCore

final class ReadingExperienceTests: XCTestCase {
    private func project() -> BookProject {
        BookProject(title: "测试书", originalName: "source.pdf", sourceHash: "source-v1", units: [
            SourceUnit(id: "u1", order: 0, chapter: "甲", page: 1, text: "甲地，刘备入城。乙地，刘备离城。"),
            SourceUnit(id: "u2", order: 1, chapter: "乙", page: 2, text: "孙权守江东，约定盟约。"),
            SourceUnit(id: "u3", order: 2, chapter: "丙", page: 3, text: "线性映射保持加法。")
        ])
    }

    func testAmbiguousQuoteRequiresExactAdjacentContextAndStableHostIdentity() throws {
        let book = project()
        XCTAssertThrowsError(try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "刘备", in: book))
        let first = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "刘备", prefix: "甲地，", in: book)
        let replay = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "刘备", suffix: "入城。", in: book)
        let second = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "刘备", prefix: "乙地，", in: book)
        XCTAssertEqual(first, replay, "请求别名和用于消歧的上下文长度不得改变宿主记录。")
        XCTAssertNotEqual(first.id, second.id, "同名词在不同位置必须保留不同锚点。")
        XCTAssertEqual(try ReadingExperienceRuntime.resolve(first, in: book).range, NSRange(location: 3, length: 2))
        var forged = first; forged.utf16Location = second.utf16Location
        XCTAssertThrowsError(try ReadingExperienceRuntime.resolve(forged, in: book), "不能用数字偏移跳到另一个同名位置。")
    }

    func testUnicodeRangesSeparateUTF8AndUTF16AndRejectNormalizedSubstitution() throws {
        var book = project()
        book.units = [SourceUnit(id: "unicode", order: 0, chapter: "Unicode", text: "前😀e\u{301}后")]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "unicode", quote: "😀e\u{301}", in: book)
        let resolved = try ReadingExperienceRuntime.resolve(anchor, in: book)
        XCTAssertEqual(resolved.utf16Location, 1)
        XCTAssertEqual(resolved.utf16Length, 4)
        XCTAssertEqual(resolved.utf8Start, 3)
        XCTAssertEqual(resolved.utf8End, 10)
        XCTAssertEqual((book.units[0].text as NSString).substring(with: resolved.range), anchor.quote)
        XCTAssertThrowsError(try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "unicode", quote: "é", in: book), "原文匹配必须保留精确字节，不能悄悄归一化。")
    }

    func testEmptyForeignHashChangedOCRTextAndCrossPageQuotesAreRejected() throws {
        var book = project()
        for (unit, quote) in [("u1", "  \n"), ("missing", "刘备"), ("u1", "离城。孙权")] {
            XCTAssertThrowsError(try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: unit, quote: quote, in: book))
        }
        XCTAssertThrowsError(try ReadingExperienceRuntime.createAnchor(sourceHash: "old", unitID: "u2", quote: "孙权", in: book))
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u2", quote: "孙权", in: book)
        book.units[1].text += "修订"
        XCTAssertThrowsError(try ReadingExperienceRuntime.resolve(anchor, in: book), "原PDF hash不变也不能复用旧OCR文本锚点。")
        book = project(); book.sourceHash = "source-v2"
        XCTAssertThrowsError(try ReadingExperienceRuntime.resolve(anchor, in: book))
    }

    func testEvidenceIndexUsesOnlyCitedExactNamesAndSkipsAmbiguousEvidence() throws {
        var book = project()
        book.entities = [
            KnowledgeEntity(id: "liu", typeID: "person", name: "刘备", aliases: ["不存在的别称"], evidence: [Evidence(unitID: "u1", quote: "甲地，刘备入城。")]),
            KnowledgeEntity(id: "sun", typeID: "person", name: "孙权", evidence: [Evidence(unitID: "u2", quote: "孙权守江东，约定盟约。")]),
            KnowledgeEntity(id: "uncertain", typeID: "person", name: "刘备", evidence: [Evidence(unitID: "u1", quote: "刘备")]),
            KnowledgeEntity(id: "title-only", typeID: "concept", name: "加法")
        ]
        let indexed = ReadingExperienceRuntime.indexEvidence(in: book, unitIDs: ["u1"])
        XCTAssertEqual(indexed.mentions.map(\.targetID), ["liu"])
        XCTAssertEqual(indexed.anchors.first?.quote, "刘备")
        XCTAssertEqual(indexed.anchors.first?.unitID, "u1")
        XCTAssertTrue(book.coverage.isEmpty)
        XCTAssertNil(book.readingExperience, "旧书索引是派生结果，不静默写入原项目。")
        let replay = ReadingExperienceRuntime.indexEvidence(in: book, state: indexed, unitIDs: ["u1"])
        XCTAssertEqual(indexed, replay)
        try ReadingExperienceRuntime.validate(indexed, in: book)
    }

    func testStateRoundTripKeepsUnknownLayerKindAndOldProjectOptionalNil() throws {
        var book = project()
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u3", quote: "线性映射保持加法。", in: book)
        let layer = ReadingLayer(id: "layer-proof", kind: "proof-dependency", title: "定义依赖", markdown: "依赖 $T(x+y)=T(x)+T(y)$。", sourceAnchorIDs: [anchor.id])
        let state = ReadingExperienceState(anchors: [anchor], layers: [layer])
        try ReadingExperienceRuntime.validate(state, in: book)
        XCTAssertEqual(try JSONDecoder().decode(ReadingExperienceState.self, from: JSONEncoder().encode(state)), state)
        let oldData = try JSONEncoder().encode(book)
        let oldBook = try JSONDecoder().decode(BookProject.self, from: oldData)
        XCTAssertNil(oldBook.readingExperience)
        book.readingExperience = state
        let decoded = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded.readingExperience, state)
    }

    func testDanglingReferencesDuplicateIDsAndFakeAttributionAreRejected() throws {
        let book = project()
        let a = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u2", quote: "孙权", in: book)
        let layer = ReadingLayer(id: "glossary", kind: "glossary", title: "释义", markdown: "正文", sourceAnchorIDs: [a.id])
        var state = ReadingExperienceState(anchors: [a], layers: [layer])
        try ReadingExperienceRuntime.validate(state, in: book)
        state.mentions = [SourceMention(targetID: "deleted", anchorID: a.id)]
        XCTAssertThrowsError(try ReadingExperienceRuntime.validate(state, in: book))
        state.mentions = []; state.anchors.append(a)
        XCTAssertThrowsError(try ReadingExperienceRuntime.validate(state, in: book))
        state.anchors = [a]; state.layers[0].sourceAnchorIDs = ["missing"]
        XCTAssertThrowsError(try ReadingExperienceRuntime.validate(state, in: book))
        state.layers = [layer]; state.layers[0].provenance = ReadingProvenance(label: "资料", url: "javascript:alert(1)")
        XCTAssertThrowsError(try ReadingExperienceRuntime.validate(state, in: book))
        state.layers[0].provenance = ReadingProvenance(label: "资料", url: "https://reader:secret@example.com/")
        XCTAssertThrowsError(try ReadingExperienceRuntime.validate(state, in: book))
    }

    func testRemovalCleansDependentRecordsButPreservesUnrelatedLayerAndSource() throws {
        var book = project()
        book.entities = [KnowledgeEntity(id: "sun", typeID: "person", name: "孙权")]
        let a = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u2", quote: "孙权", in: book)
        let b = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u3", quote: "加法", in: book)
        let layer = ReadingLayer(id: "keep-layer", kind: "glossary", title: "术语", markdown: "术语含义", sourceAnchorIDs: [b.id])
        let alignment = ReferenceAlignment(id: "compare", sourceAnchorIDs: [a.id, b.id], title: "对照", markdown: "对比")
        let decision = DecisionCard(id: "choice", title: "思考", contextMarkdown: "背景", options: [DecisionOption(id: "a", title: "甲", markdown: "理由"), DecisionOption(id: "b", title: "乙", markdown: "理由")], sourceAnchorIDs: [a.id])
        let state = ReadingExperienceState(anchors: [a, b], mentions: [SourceMention(targetID: "sun", anchorID: a.id)], layers: [layer], alignments: [alignment], decisions: [decision])
        try ReadingExperienceRuntime.validate(state, in: book)
        let removed = ReadingExperienceRuntime.removeAnchor(a.id, from: state)
        XCTAssertEqual(removed.anchors, [b]); XCTAssertTrue(removed.mentions.isEmpty)
        XCTAssertTrue(removed.alignments.isEmpty); XCTAssertTrue(removed.decisions.isEmpty); XCTAssertEqual(removed.layers, [layer])
        try ReadingExperienceRuntime.validate(removed, in: book)
        let targetRemoved = ReadingExperienceRuntime.removeTarget("sun", from: state)
        XCTAssertTrue(targetRemoved.mentions.isEmpty)
        XCTAssertEqual(targetRemoved.layers, [layer]); XCTAssertEqual(targetRemoved.decisions, [decision], "删除卡片不应删除引用同一句的独立分析。")
        XCTAssertEqual(book.units[1].text, "孙权守江东，约定盟约。")
        XCTAssertEqual(state.anchors.count, 2)
    }

    func testContextFiltersSourceObjectsAndTimeWithoutReturningWholeBook() throws {
        var book = project()
        book.entities = [KnowledgeEntity(id: "sun", typeID: "person", name: "孙权", evidence: [Evidence(unitID: "u2", quote: "孙权守江东，约定盟约。")]), KnowledgeEntity(id: "liu", typeID: "person", name: "刘备", evidence: [Evidence(unitID: "u1", quote: "甲地，刘备入城。")])]
        book.events = [
            KnowledgeEvent(id: "alliance", name: "盟约", startYear: 208, participantIDs: ["sun"], evidence: [Evidence(unitID: "u2", quote: "约定盟约。")]),
            KnowledgeEvent(id: "later", name: "后续", startYear: 220, participantIDs: ["sun"]),
            KnowledgeEvent(id: "other", name: "他地", startYear: 208, participantIDs: ["liu"], evidence: [Evidence(unitID: "u1", quote: "甲地，刘备入城。")])
        ]
        let state = ReadingExperienceRuntime.indexEvidence(in: book)
        let page = ReadingExperienceRuntime.contextualItems(in: book, context: ReadingContext(unitID: "u2"), state: state)
        XCTAssertEqual(page.entityIDs, ["sun"]); XCTAssertEqual(page.eventIDs, ["alliance"])
        let object = ReadingExperienceRuntime.contextualItems(in: book, context: ReadingContext(objectID: "sun", startYear: 208, endYear: 208), state: state)
        XCTAssertEqual(object.eventIDs, ["alliance"])
        XCTAssertFalse(object.anchors.isEmpty, "对象上下文应复用其真实提及位置。")
        let empty = ReadingExperienceRuntime.contextualItems(in: book, context: ReadingContext(), state: state)
        XCTAssertTrue(empty.entities.isEmpty); XCTAssertTrue(empty.events.isEmpty)
        XCTAssertThrowsError(try ReadingExperienceRuntime.validatedContext(ReadingContext(unitID: "u2", page: 1), in: book, state: state))
        XCTAssertThrowsError(try ReadingExperienceRuntime.validatedContext(ReadingContext(timeFrom: .nan), in: book))
        XCTAssertTrue(ReadingExperienceRuntime.contextualItems(in: book, context: ReadingContext(sourceHash: "old", unitID: "u2"), state: state).entities.isEmpty)
    }

    func testContextBudgetIsUTF8BoundedValidJSONAndDoesNotIncludeDocumentBody() throws {
        var book = project()
        book.entities = (0..<40).map { KnowledgeEntity(id: "entity-\($0)", typeID: "concept", name: String(repeating: "术语", count: 100), summary: String(repeating: "解释", count: 300), evidence: [Evidence(unitID: "u3", quote: "线性映射保持加法。")]) }
        let text = try ReadingExperienceRuntime.contextJSON(ReadingContext(unitID: "u3"), in: book, maximumUTF8Bytes: 2_048)
        XCTAssertLessThanOrEqual(text.utf8.count, 2_048)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(json["bounded"] as? Bool, true)
        XCTAssertEqual(json["unitID"] as? String, "u3")
        XCTAssertNil(json["markdownBody"])
        XCTAssertThrowsError(try ReadingExperienceRuntime.contextJSON(ReadingContext(), in: book, maximumUTF8Bytes: 100))
    }

    func testTrashedDocumentLinksRemainRestorableButCannotBecomeCurrentContext() throws {
        var book = project()
        var document = DocumentRecord(id: "doc", title: "用户理解"); document.trashedAt = Date()
        book.documents = [document]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u3", quote: "加法", in: book)
        let state = ReadingExperienceState(anchors: [anchor], mentions: [SourceMention(targetID: "doc", anchorID: anchor.id)])
        try ReadingExperienceRuntime.validateStoredState(state, in: book)
        XCTAssertThrowsError(try ReadingExperienceRuntime.validatedContext(ReadingContext(documentID: "doc"), in: book, state: state))
        book.documents[0].trashedAt = nil
        XCTAssertNoThrow(try ReadingExperienceRuntime.validatedContext(ReadingContext(documentID: "doc"), in: book, state: state))
        XCTAssertEqual(ReadingExperienceRuntime.contextualItems(in: book, context: ReadingContext(documentID: "doc"), state: state).anchors, [anchor])
    }

    func testRepeatedExactSelectionUsesAdjacentContextWithoutInventingSavedData() throws {
        var book = project()
        book.entities = [KnowledgeEntity(id: "liu", typeID: "person", name: "刘备")]
        let first = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "刘备", suffix: "入城。", in: book)
        let second = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "刘备", suffix: "离城。", in: book)
        let state = ReadingExperienceState(anchors: [first, second], mentions: [SourceMention(targetID: "liu", anchorID: first.id), SourceMention(targetID: "liu", anchorID: second.id)])
        let context = ReadingContext(unitID: "u1", selectedText: "刘备", selectedPrefix: second.prefix, selectedSuffix: second.suffix)
        let validated = try ReadingExperienceRuntime.validatedContext(context, in: book, state: state)
        XCTAssertNil(validated.selectedAnchorID)
        XCTAssertEqual(ReadingExperienceRuntime.contextualItems(in: book, context: validated, state: state).anchors, [second])
        let json = try ReadingExperienceRuntime.contextJSON(context, in: book, state: state)
        XCTAssertTrue(json.contains("selectedPrefix"))
        XCTAssertThrowsError(try ReadingExperienceRuntime.validatedContext(ReadingContext(unitID: "u1", selectedText: "刘备", selectedPrefix: "不存在"), in: book, state: state))
        XCTAssertNil(book.readingExperience); XCTAssertTrue(book.coverage.isEmpty)
    }

    func testGeneratedLayerTrashSurvivesRoundTripAndRestoresExactDependencies() throws {
        let book = project()
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u3", quote: "加法", in: book)
        let layer = ReadingLayer(id: "term", kind: "glossary", title: "加法", markdown: "术语说明", sourceAnchorIDs: [anchor.id])
        let original = ReadingExperienceState(anchors: [anchor], layers: [layer])
        let deleted = try ReadingExperienceRuntime.trashItem(id: layer.id, kind: "layer", state: original)
        XCTAssertTrue(deleted.layers.isEmpty); XCTAssertTrue(deleted.anchors.isEmpty)
        let item = try XCTUnwrap(deleted.trash?.first)
        XCTAssertEqual(item.layer, layer); XCTAssertEqual(item.anchors, [anchor])
        try ReadingExperienceRuntime.validateStoredState(deleted, in: book)
        let decoded = try JSONDecoder().decode(ReadingExperienceState.self, from: JSONEncoder().encode(deleted))
        let restored = try ReadingExperienceRuntime.restoreTrashedItem(id: item.id, state: decoded, in: book)
        XCTAssertEqual(restored.layers, original.layers); XCTAssertEqual(restored.anchors, original.anchors)
        XCTAssertTrue(restored.trash?.isEmpty == true)
        XCTAssertEqual(original.layers, [layer], "纯函数不应提前修改调用方。")
    }

    func testTrashRestorationRejectsConflictsAndChangedSourceWithoutOverwriting() throws {
        var book = project()
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u3", quote: "加法", in: book)
        let layer = ReadingLayer(id: "term", kind: "glossary", title: "加法", markdown: "旧说明", sourceAnchorIDs: [anchor.id])
        let deleted = try ReadingExperienceRuntime.trashItem(id: layer.id, kind: "layer", state: ReadingExperienceState(anchors: [anchor], layers: [layer]))
        let itemID = try XCTUnwrap(deleted.trash?.first?.id)
        var conflict = deleted
        var replacement = layer; replacement.markdown = "用户新内容"
        conflict.layers = [replacement]; conflict.anchors = [anchor]
        XCTAssertThrowsError(try ReadingExperienceRuntime.restoreTrashedItem(id: itemID, state: conflict, in: book))
        XCTAssertEqual(conflict.layers[0].markdown, "用户新内容")
        book.units[2].text += "修订"
        XCTAssertThrowsError(try ReadingExperienceRuntime.restoreTrashedItem(id: itemID, state: deleted, in: book))
        XCTAssertEqual(deleted.trash?.count, 1)
    }

    func testTrashLimitMalformedSnapshotAndLegacyNilAreSafe() throws {
        let book = project()
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u3", quote: "加法", in: book)
        let layer = ReadingLayer(id: "term", kind: "glossary", title: "加法", markdown: "说明", sourceAnchorIDs: [anchor.id])
        var full = ReadingExperienceState(anchors: [anchor], layers: [layer])
        XCTAssertNil(full.trash)
        full.trash = (0..<200).map { ReadingExperienceTrashItem(id: "trash-\($0)", kind: "layer", title: layer.title, anchors: [anchor], layer: layer) }
        XCTAssertThrowsError(try ReadingExperienceRuntime.trashItem(id: layer.id, kind: "layer", state: full))
        XCTAssertEqual(full.layers, [layer]); XCTAssertEqual(full.trash?.count, 200)
        var malformed = ReadingExperienceState()
        malformed.trash = [ReadingExperienceTrashItem(kind: "decision", title: "错位", anchors: [anchor], layer: layer)]
        XCTAssertThrowsError(try ReadingExperienceRuntime.validateStoredState(malformed, in: book))
        let legacyData = try JSONEncoder().encode(ReadingExperienceState())
        XCTAssertNil(try JSONDecoder().decode(ReadingExperienceState.self, from: legacyData).trash)
    }
}
