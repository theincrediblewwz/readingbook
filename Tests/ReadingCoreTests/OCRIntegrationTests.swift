import Foundation
import XCTest
@testable import ReadingCore

final class OCRIntegrationTests: XCTestCase {
    private func project() -> BookProject {
        var book = BookProject(title: "扫描示例", originalName: "book.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            SourceUnit(id: "page-1", order: 0, chapter: "原书", page: 1, text: "第一页已有可读文本。"),
            SourceUnit(id: "page-2", order: 1, chapter: "原书", page: 2, text: "", warning: "扫描页尚无文本"),
            SourceUnit(id: "page-3", order: 2, chapter: "原书", page: 3, text: "第三页原文。")
        ])
        var completed = CoverageEntry(); completed.status = .completed; completed.attempts = 1
        var failed = CoverageEntry(); failed.status = .failed; failed.attempts = 2; failed.message = "先前连接失败"
        book.coverage = ["page-1": completed, "page-2": CoverageEntry(), "page-3": failed]
        book.bookmarks = ["page-1", "page-2"]
        book.lastUnitID = "page-2"
        book.plan = ReadingPlan(methodIDs: ["close-reading"], rationale: "旧提取层的预读方案")
        return book
    }

    private func snapshot(_ project: BookProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(project)
    }

    func testApplyingOneOCRPagePreservesOtherPagesAndRequiresReview() throws {
        let before = project()
        let markdown = String(repeating: "识", count: 6_500) + "\n\n$E=mc^2$\n"
        let result = OCRPageResult(page: 2, markdown: markdown, issues: ["脚注字迹模糊"], model: "fixture-vision")
        let updated = try OCRIntegration.applying(result, to: before)
        let replacements = updated.units.filter { $0.page == 2 }

        XCTAssertEqual(updated.id, before.id)
        XCTAssertEqual(updated.sourceHash, before.sourceHash, "OCR must never redefine the original PDF hash")
        XCTAssertEqual(updated.importedAt, before.importedAt)
        XCTAssertEqual(updated.units.filter { $0.page != 2 }.map(\.id), ["page-1", "page-3"])
        XCTAssertEqual(updated.units.first, before.units.first)
        XCTAssertEqual(updated.units.last?.text, before.units.last?.text)
        XCTAssertEqual(updated.units.map(\.order), Array(0..<updated.units.count))
        XCTAssertEqual(replacements.count, 2)
        XCTAssertEqual(replacements.map(\.text).joined(), markdown)
        XCTAssertTrue(replacements.allSatisfy { $0.text.count <= 5_000 && $0.warning?.contains("尚未人工核对") == true && $0.warning?.contains("脚注字迹模糊") == true })
        XCTAssertFalse(updated.units.contains { $0.id == "page-2" })
        XCTAssertNil(updated.coverage["page-2"])
        XCTAssertTrue(replacements.allSatisfy { updated.coverage[$0.id]?.status == .pending && updated.coverage[$0.id]?.attempts == 0 })
        XCTAssertEqual(updated.coverage["page-1"]?.status, .completed)
        XCTAssertEqual(updated.coverage["page-3"]?.status, .failed)
        XCTAssertEqual(updated.coverage["page-3"]?.attempts, 2)
        XCTAssertEqual(updated.completedCount, before.completedCount, "OCR alone does not advance reading coverage")
        XCTAssertNil(updated.plan)
        XCTAssertNil(updated.lastUnitID)
        XCTAssertEqual(updated.bookmarks, ["page-1", replacements[0].id])
        XCTAssertEqual(updated.ocrPages?.first?.unitIDs, replacements.map(\.id))
        XCTAssertEqual(updated.ocrPages?.first?.model, "fixture-vision")
        XCTAssertEqual(updated.audit.last?.name, "pdf_ocr")
        XCTAssertFalse(updated.isFullyProcessed)
    }

    func testExistingAnalysisAndMarkdownEvidencePreventReplacement() throws {
        let result = OCRPageResult(page: 2, markdown: "新转录文本", issues: [], model: "fixture-vision")
        var analysis = project()
        analysis.insights.append(ReadingInsight(id: "analysis", unitIDs: ["page-2"], markdown: "已经使用原文的分析"))
        var document = project()
        document.documents.append(DocumentRecord(id: "user-note", title: "用户 Markdown",
                                                  evidence: [Evidence(unitID: "page-2", quote: "原页依据")]))
        var linkedDocument = project()
        linkedDocument.documents.append(DocumentRecord(id: "linked-note", title: "关联原页的理解", linkedIDs: ["page-2"]))
        var completed = project()
        var entry = CoverageEntry(); entry.status = .completed
        completed.coverage["page-2"] = entry

        for protected in [analysis, document, linkedDocument, completed] {
            let unchanged = try snapshot(protected)
            XCTAssertNotNil(OCRIntegration.unavailableReason(project: protected, page: 2))
            XCTAssertThrowsError(try OCRIntegration.applying(result, to: protected))
            XCTAssertEqual(try snapshot(protected), unchanged, "Rejected replacement must leave old evidence untouched")
        }
    }

    func testVisionBudgetExcludesBase64AndHonorsCompletionParameterAndContext() throws {
        func messages(base64: String) -> [[String: Any]] {
            [["role": "user", "content": [
                ["type": "text", "text": "忠实转录这一页。"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + base64, "detail": "high"]]
            ] as [[String: Any]]]]
        }
        let settings = ProviderSettings(baseURL: "https://provider.example/v1", model: "fixture-vision",
                                        maxOutputTokens: 8_000, contextWindowTokens: 20_000,
                                        tokenLimitParameter: "max_completion_tokens")
        let small = try ProviderClient.prepare(messages: messages(base64: String(repeating: "A", count: 128)),
                                               tools: [], settings: settings, apiKey: "", remainingTokens: 30_000)
        let large = try ProviderClient.prepare(messages: messages(base64: String(repeating: "A", count: 2_000_000)),
                                               tools: [], settings: settings, apiKey: "", remainingTokens: 30_000)
        XCTAssertEqual(large.estimatedInputTokens, small.estimatedInputTokens,
                       "Base64 is transport data; changing its length must not count as millions of text tokens")
        XCTAssertGreaterThan(large.request.httpBody?.count ?? 0, 1_000_000, "The real page image must remain in the outgoing request")
        let bodyData = try XCTUnwrap(large.request.httpBody)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual((body["max_completion_tokens"] as? NSNumber)?.intValue, 20_000 - large.estimatedInputTokens)

        let runLimited = try ProviderClient.prepare(messages: messages(base64: "AAAA"), tools: [], settings: settings,
                                                    apiKey: "", remainingTokens: 18_000)
        let limitedData = try XCTUnwrap(runLimited.request.httpBody)
        let limitedBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: limitedData) as? [String: Any])
        XCTAssertEqual((limitedBody["max_completion_tokens"] as? NSNumber)?.intValue,
                       18_000 - runLimited.estimatedInputTokens, "Use the smaller of context capacity and remaining run budget")
        XCTAssertThrowsError(try ProviderClient.prepare(messages: messages(base64: "AAAA"), tools: [], settings: settings,
                                                        apiKey: "", remainingTokens: runLimited.estimatedInputTokens + 63))
    }
}
