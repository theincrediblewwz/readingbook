import Foundation
import XCTest
@testable import ReadingCore

final class ComponentReuseTests: XCTestCase {
    private func project() -> BookProject {
        var value = BookProject(id: "component-test", title: "原书", originalName: "source.txt", sourceHash: "source",
            units: [SourceUnit(id: "u", order: 0, chapter: "第一章", page: 1, text: "原文 e\u{301}。")])
        PluginEngine.seed(&value)
        value.entities = [KnowledgeEntity(id: "person", typeID: "person", name: "原文", evidence: [Evidence(unitID: "u", quote: "原文 e\u{301}。")])]
        value.documents = [DocumentRecord(id: "note", title: "原有笔记")]
        return value
    }
    private func encoded(_ value: BookProject) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func registry(owner: String = "fixture", name: String = "probe", receipts: Bool = false,
                          handler: @escaping @Sendable (Data, inout BookProject, Set<String>) throws -> String = { _, _, _ in "ok" }) throws -> PluginToolRegistry {
        var result = PluginToolRegistry()
        try result.register(RegisteredReadingTool(pluginID: owner, schema: ["type": "function", "function": ["name": name, "parameters": ["type": "object", "properties": [:]]]], phases: [.reading], requiresReceipts: receipts, readOnly: true, execute: handler))
        return result
    }
    func testReadOnlyActualKnowledgeSearchPreservesProjectAndAudit() throws {
        var value = project(); let before = try encoded(value)
        let output = try PluginEngine.registry.apply(name: "knowledge_search", arguments: Data(#"{"query":"原文","limit":8}"#.utf8), to: &value, allowedUnitIDs: ["u"], phase: .reading)
        XCTAssertTrue(output.contains("person")); XCTAssertEqual(try encoded(value), before)
        XCTAssertTrue(value.audit.isEmpty)
    }
    func testReadOnlyChangedFieldsKeepLegacyErrorsAndAtomicity() throws {
        for field in ["title", "type", "source", "document", "coverage", "chat", "bookmark"] {
            let tool = try registry { _, candidate, _ in
                switch field {
                case "title": candidate.title = "changed"
                case "type": candidate.types[0].name = "changed"
                case "source": candidate.sourceHash = "changed"
                case "document": candidate.documents[0].title = "changed"
                case "coverage": candidate.lastUnitID = "changed"
                case "chat": candidate.chats.append(ChatMessage(role: "user", content: "changed"))
                default: candidate.bookmarks.append("u")
                }
                return "cannot publish"
            }
            var value = project(); let before = try encoded(value)
            XCTAssertThrowsError(try tool.apply(name: "probe", arguments: Data("{}".utf8), to: &value, allowedUnitIDs: ["u"], phase: .reading)) { error in
                let text = error.localizedDescription
                XCTAssertTrue(text.contains(field == "source" || field == "document" ? "原书或用户" : field == "chat" || field == "bookmark" ? "批注、会话或书签" : field == "coverage" ? "阅读覆盖" : "只读插件"), text)
            }
            XCTAssertEqual(try encoded(value), before, field)
        }
    }
    func testReadOnlyCanonicalEquivalentSourceBytesCannotBeReplaced() throws {
        var value = project(); let before = try encoded(value)
        let tool = try registry { _, candidate, _ in candidate.units[0].text = "原文 é。"; return "cannot publish" }
        XCTAssertThrowsError(try tool.apply(name: "probe", arguments: Data("{}".utf8), to: &value, allowedUnitIDs: ["u"], phase: .reading))
        XCTAssertEqual(try encoded(value), before)
        XCTAssertTrue(value.units[0].text.utf8.elementsEqual("原文 e\u{301}。".utf8))
    }
    func testReadOnlyUnchangedInvalidTrashAndNonFiniteProjectStillFail() throws {
        let tool = try registry()
        var invalid = project(); invalid.manualTrash = ManualTrashState(); invalid.manualTrash?.version = 999
        let before = try encoded(invalid)
        XCTAssertThrowsError(try tool.apply(name: "probe", arguments: Data("{}".utf8), to: &invalid, allowedUnitIDs: [], phase: .reading))
        XCTAssertEqual(try encoded(invalid), before)
        var nonfinite = project(); nonfinite.importedAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertThrowsError(try tool.apply(name: "probe", arguments: Data("{}".utf8), to: &nonfinite, allowedUnitIDs: [], phase: .reading))
        XCTAssertTrue(nonfinite.importedAt.timeIntervalSince1970.isInfinite); XCTAssertTrue(nonfinite.audit.isEmpty)
    }
    func testReadOnlyStandardCompletionCannotBypassHostAuthority() throws {
        let tool = try registry(owner: "builtin.standard-reading", name: "reading_analysis")
        var value = project(); let before = try encoded(value)
        XCTAssertThrowsError(try tool.apply(name: "reading_analysis", arguments: Data("{}".utf8), to: &value, allowedUnitIDs: ["u"], phase: .reading))
        XCTAssertEqual(try encoded(value), before)
    }
    func testReadOnlyPhaseAndReceiptGatesRemainBeforeHandler() throws {
        let tool = try registry(receipts: true) { _, _, _ in XCTFail("Host gate must run before the handler"); return "unexpected" }
        var value = project(); let before = try encoded(value)
        for phase in [PluginToolPhase.planning, .reading] {
            XCTAssertThrowsError(try tool.apply(name: "probe", arguments: Data("{}".utf8), to: &value, allowedUnitIDs: ["u"], phase: phase))
        }
        XCTAssertEqual(try encoded(value), before)
    }
    func testStoredSourceIndexKeepsFirstDuplicateMissingAndExactQuote() throws {
        let units = [SourceUnit(id: "u", order: 0, chapter: "first", page: 1, text: "原文"), SourceUnit(id: "u", order: 1, chapter: "later", page: 999, text: "后者")]
        let first = SourceAnchor(id: "a", sourceHash: "source", unitID: "u", quote: "e\u{301} 👩🏽‍💻", utf16Location: 3, utf16Length: 11)
        let anchors = [first, SourceAnchor(id: "a", sourceHash: "other", unitID: "missing", quote: "不覆盖"), SourceAnchor(id: "orphan", sourceHash: "source", unitID: "missing", quote: "保留引用")]
        for count in [0, 3, 11, 12, 100] {
            let references = count < 12 ? Array(repeating: "a", count: count) : ["a", "orphan"] + (0..<count).map { "other\($0)" }
            let index = StoredReadingSourceIndex(anchors: anchors, units: units, referencedAnchorIDs: references)
            XCTAssertEqual(index.anchor(id: "a"), first); XCTAssertEqual(index.locator(unitID: "u"), units[0].locator)
            XCTAssertTrue(index.anchor(id: "a")!.quote.utf8.elementsEqual(first.quote.utf8))
            XCTAssertNil(index.anchor(id: "missing")); XCTAssertNotNil(index.anchor(id: "orphan")); XCTAssertNil(index.locator(unitID: "missing"))
        }
    }
    func testStoredSourceIndexRemainsLocalToItsValueSnapshot() throws {
        var units = [SourceUnit(id: "u", order: 0, chapter: "one", page: 1, text: "one")]
        var anchors = [SourceAnchor(id: "a", sourceHash: "one", unitID: "u", quote: "one")]
        let references = ["a"] + (0..<12).map { "other\($0)" }
        let first = StoredReadingSourceIndex(anchors: anchors, units: units, referencedAnchorIDs: references)
        anchors[0].quote = "two"; units[0].page = 2
        let second = StoredReadingSourceIndex(anchors: anchors, units: units, referencedAnchorIDs: references)
        XCTAssertEqual(first.anchor(id: "a")?.quote, "one"); XCTAssertEqual(second.anchor(id: "a")?.quote, "two")
        XCTAssertNotEqual(first.locator(unitID: "u"), second.locator(unitID: "u"))
        let empty = StoredReadingSourceIndex(anchors: [], units: [], referencedAnchorIDs: references)
        XCTAssertNil(empty.anchor(id: "a")); XCTAssertNil(empty.locator(unitID: "u"))
    }
}
