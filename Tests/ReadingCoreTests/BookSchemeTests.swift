import Foundation
import XCTest
@testable import ReadingCore

final class BookSchemeTests: XCTestCase {
    private func project() -> BookProject {
        var book = BookProject(title: "代数", originalName: "algebra.pdf", sourceHash: "source", units: [SourceUnit(id: "p1", order: 0, chapter: "第一章", page: 1, text: "初等行变换保持线性方程组的解集。")])
        PluginEngine.seed(&book)
        book.plan = ReadingPlan(methodIDs: ["textbook"], rationale: "教材精读", focus: [])
        book.views = [ViewDefinition(id: "notes", title: "我的笔记", kind: .editor)]
        book.documents = [DocumentRecord(id: "user-note", title: "自己的理解")]
        return book
    }
    private func proposed(_ book: BookProject) -> BookProject {
        var next = book
        next.views.append(ViewDefinition(id: "matrix-cards", title: "矩阵", kind: .cards, typeIDs: ["matrix"]))
        next.types.append(EntityType(id: "matrix", name: "矩阵", fields: [TypeField(key: "shape", label: "形状")]))
        next.plan = ReadingPlan(methodIDs: ["textbook", "analytical"], rationale: "理解定义并检视推导", focus: ["行变换"])
        return next
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }

    func testPreviewDoesNotActivateConfigurationOrAlterUserWork() throws {
        let original = project(), next = proposed(original)
        let preview = try BookSchemeRuntime.stageAIProposal(from: original, proposed: next)
        XCTAssertEqual(try BookSchemeConfiguration(project: preview).fingerprint(), try BookSchemeConfiguration(project: original).fingerprint())
        XCTAssertNotNil(preview.bookSchemes?.pending)
        XCTAssertEqual(try encode(preview.documents), try encode(original.documents))
        XCTAssertEqual(try encode(preview.coverage), try encode(original.coverage))
        XCTAssertEqual(preview.units, original.units)
        XCTAssertNil(preview.paragraphReceipts)
    }

    func testSelectionApplyAndUndoPreservesReferencedDefinitionsAndDocuments() throws {
        let original = project()
        var book = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed(original))
        book.views.append(ViewDefinition(id: "manual-book.scheme", title: "书本方案", kind: .workflow, rendererID: "book.scheme"))
        var selection = try XCTUnwrap(book.bookSchemes?.pending?.selection)
        selection.methodIDs = ["analytical"]
        try BookSchemeRuntime.applyPending(selection: selection, in: &book)
        XCTAssertEqual(book.plan?.methodIDs, ["analytical"])
        XCTAssertNil(book.bookSchemes?.pending)
        XCTAssertEqual(book.bookSchemes?.history.count, 1)
        book.entities.append(KnowledgeEntity(id: "a", typeID: "matrix", name: "A"))
        let documents = try encode(book.documents)
        try BookSchemeRuntime.revertLatest(in: &book)
        XCTAssertEqual(book.plan?.methodIDs, original.plan?.methodIDs)
        XCTAssertTrue(book.types.contains { $0.id == "matrix" })
        XCTAssertEqual(book.entities.count, 1)
        XCTAssertEqual(try encode(book.documents), documents)
        XCTAssertTrue(book.views.contains { $0.rendererID == "book.scheme" })
        XCTAssertFalse(book.views.contains { $0.id == "matrix-cards" })
    }

    func testLaterConfigurationEditsBlockApplyAndUndoWithoutMutation() throws {
        let original = project()
        var preview = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed(original))
        preview.views[0].title = "用户后来改的标题"
        let previewBefore = try encode(preview)
        XCTAssertThrowsError(try BookSchemeRuntime.applyPending(in: &preview))
        XCTAssertEqual(try encode(preview), previewBefore)
        var applied = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed(original))
        try BookSchemeRuntime.applyPending(in: &applied)
        applied.plan?.rationale = "用户后来的计划调整"
        let before = try encode(applied)
        XCTAssertThrowsError(try BookSchemeRuntime.revertLatest(in: &applied))
        XCTAssertEqual(try encode(applied), before)
    }

    func testChangedSourceBlocksStaleProposalAndOCRClearsIt() throws {
        var original = project(); original.units[0].text = ""
        var book = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed(original))
        var changed = book; changed.units[0].text = "新的原文"
        XCTAssertThrowsError(try BookSchemeRuntime.applyPending(in: &changed))
        let result = OCRPageResult(page: 1, markdown: "矩阵 A 的行数为 2。", issues: [], model: "fixture")
        book = try OCRIntegration.applying(result, to: book)
        XCTAssertNil(book.bookSchemes?.pending)
        XCTAssertNil(book.plan)
    }

    func testTemplatesRoundTripOnlyConfigurationAndRequireConfirmation() throws {
        var source = project()
        let template = try BookSchemeRuntime.saveTemplate(name: "教材", in: &source)
        let exported = try encode(template)
        XCTAssertFalse(String(data: exported, encoding: .utf8)!.contains("user-note"))
        let imported = try JSONDecoder().decode(BookSchemeTemplate.self, from: exported)
        var target = project(); target.id = "different-book"; target.views = []
        let before = try BookSchemeConfiguration(project: target).fingerprint()
        try BookSchemeRuntime.stageTemplate(imported, in: &target)
        XCTAssertEqual(try BookSchemeConfiguration(project: target).fingerprint(), before)
        try BookSchemeRuntime.applyPending(in: &target)
        XCTAssertEqual(target.views.map(\.id), ["notes"])
        XCTAssertEqual(target.documents.first?.id, "user-note")
        BookSchemeRuntime.removeTemplate(id: template.id, in: &source)
        XCTAssertTrue(source.bookSchemes?.templates.isEmpty == true)
    }

    func testPluginUpgradesVersionImmutableDefinitionsAndKeepOldReferences() throws {
        var book = project()
        func pack(_ version: Int) -> PluginManifest {
            PluginManifest(id: "linear.pack", name: "线性代数", version: version, description: "示例声明",
                types: [EntityType(id: "matrix-card", name: "矩阵 v\(version)")],
                methods: [ReadingMethod(id: "matrix-method", name: "矩阵学习 v\(version)", goal: "检查矩阵", steps: ["核对数值 \(version)"])],
                views: [ViewDefinition(id: "matrix-view", title: "矩阵 v\(version)", kind: .cards, typeIDs: ["matrix-card"])])
        }
        try BookSchemeRuntime.stagePlugin(pack(1), in: &book)
        XCTAssertTrue(book.plugins.isEmpty)
        try BookSchemeRuntime.applyPending(in: &book)
        book.plan = ReadingPlan(methodIDs: ["matrix-method"], rationale: "用户选择", focus: [])
        book.entities = [KnowledgeEntity(id: "existing", typeID: "matrix-card", name: "旧矩阵")]
        try BookSchemeRuntime.stagePlugin(pack(2), in: &book)
        let proposal = try XCTUnwrap(book.bookSchemes?.pending)
        let changedID = try XCTUnwrap(proposal.proposed.plugins.first?.types.first?.id)
        XCTAssertNotEqual(changedID, "matrix-card")
        XCTAssertEqual(book.plugins.first?.version, 1)
        try BookSchemeRuntime.applyPending(in: &book)
        XCTAssertEqual(book.plugins.first?.version, 2)
        XCTAssertTrue(book.types.contains { $0.id == "matrix-card" && $0.name == "矩阵 v1" })
        XCTAssertEqual(book.entities.first?.typeID, "matrix-card")
        XCTAssertNotEqual(book.plan?.methodIDs.first, "matrix-method")
        try BookSchemeRuntime.stagePlugin(pack(3), in: &book)
        try BookSchemeRuntime.applyPending(in: &book)
        XCTAssertEqual(book.plugins.first?.version, 3)
        XCTAssertThrowsError(try BookSchemeRuntime.stagePlugin(pack(3), in: &book))
    }

    func testDeselectingRequiredNewTypeFailsAtomically() throws {
        let original = project()
        var book = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed(original))
        var selection = try XCTUnwrap(book.bookSchemes?.pending?.selection); selection.typeIDs.remove("matrix")
        let before = try encode(book)
        XCTAssertThrowsError(try BookSchemeRuntime.applyPending(selection: selection, in: &book))
        XCTAssertEqual(try encode(book), before)
    }

    func testAcceptedPlanKeepsAIExecutionOrder() throws {
        let original = project()
        var next = proposed(original); next.plan?.methodIDs = ["textbook", "analytical", "active-retelling"]
        var book = try BookSchemeRuntime.stageAIProposal(from: original, proposed: next)
        try BookSchemeRuntime.applyPending(in: &book)
        XCTAssertEqual(book.plan?.methodIDs, ["textbook", "analytical", "active-retelling"])
    }

    func testPendingSchemeBlocksModelCallsBeforeBudgetIsConsumed() async throws {
        let original = project()
        let book = try BookSchemeRuntime.stageAIProposal(from: original, proposed: proposed(original))
        let reader = AIReader()
        do { _ = try await reader.readNext(project: book, settings: ProviderSettings(), apiKey: ""); XCTFail("待确认方案不能开始精读") } catch {}
        do { _ = try await reader.plan(project: book, settings: ProviderSettings(), apiKey: ""); XCTFail("待确认方案不能再次预读") } catch {}
        let used = await reader.requestCount
        XCTAssertEqual(used, 0)
    }
}
