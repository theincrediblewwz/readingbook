import Foundation
import XCTest
@testable import ReadingCore

final class ManualTrashBoundaryTests: XCTestCase {
    private func fixture() -> BookProject {
        var book = BookProject(title: "恢复边界", originalName: "book.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            SourceUnit(id: "u1", order: 0, chapter: "原书", page: 1, text: "甲于此处出场。"),
            SourceUnit(id: "u2", order: 1, chapter: "原书", page: 2, text: "另一页没有已用证据。")
        ])
        PluginEngine.seed(&book)
        book.entities = [KnowledgeEntity(id: "person-a", typeID: "person", name: "甲", evidence: [Evidence(unitID: "u1", quote: "甲于此处出场。")])]
        return book
    }
    private func snapshot(_ book: BookProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(book)
    }
    private func tool(_ name: String, execute: @escaping @Sendable (Data, inout BookProject, Set<String>) throws -> String) throws -> RegisteredReadingTool {
        try RegisteredReadingTool(pluginID: "test.manual-trash", schema: ["type": "function", "function": [
            "name": name, "description": "回收边界测试", "parameters": ["type": "object", "properties": [:]]
        ]], phases: Set(PluginToolPhase.allCases), execute: execute)
    }
    func testPluginCannotEraseRecycleHistoryOrRecreateReservedIdentity() throws {
        let original = fixture(), entity = original.entities[0]
        let removed = try ManualTrashRuntime.trashing(kind: .entity, id: entity.id, in: original)
        for mode in 0..<3 {
            let probe = try tool("revive_deleted") { _, book, _ in
                if mode == 0 { book.manualTrash = nil }
                else if mode == 1 { book.entities.append(entity) }
                else { book.events.append(KnowledgeEvent(id: entity.id, name: "不能跨类型占用已删身份")) }
                return "不能提交"
            }
            var registry = PluginToolRegistry(); try registry.register(probe)
            for phase in PluginToolPhase.allCases {
                var value = removed
                XCTAssertThrowsError(try registry.apply(name: "revive_deleted", arguments: Data("{}".utf8), to: &value, allowedUnitIDs: ["u1"], phase: phase))
                XCTAssertEqual(try snapshot(value), try snapshot(removed))
            }
        }
    }
    func testDeletedEvidenceStillProtectsOCRWithoutBlockingUnrelatedPage() throws {
        let removed = try ManualTrashRuntime.trashing(kind: .entity, id: "person-a", in: fixture())
        XCTAssertTrue(removed.entities.isEmpty)
        XCTAssertNotNil(OCRIntegration.unavailableReason(project: removed, page: 1))
        XCTAssertNil(OCRIntegration.unavailableReason(project: removed, page: 2))
        let before = try snapshot(removed)
        XCTAssertThrowsError(try OCRIntegration.applying(OCRPageResult(page: 1, markdown: "改写后的文本", issues: [], model: "fixture"), to: removed))
        XCTAssertEqual(try snapshot(removed), before)
        let restored = try ManualTrashRuntime.restoring(itemID: XCTUnwrap(removed.manualTrash?.items.first?.id),
            expectedItemIDs: ManualTrashRuntime.restorePlan(in: removed, itemID: XCTUnwrap(removed.manualTrash?.items.first?.id)).itemIDs, in: removed)
        XCTAssertEqual(restored.entities, fixture().entities)
    }
}
