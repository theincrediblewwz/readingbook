import Foundation
import XCTest
@testable import ReadingCore

final class ReadingLedgerTests: XCTestCase {
    private func project(_ text: String = "第一段：设 α > 0。\n\n第二段：因此结论成立。") -> BookProject {
        var project = BookProject(title: "逐段核对", originalName: "fixture.md", sourceHash: "source", units: [SourceUnit(id: "u1", order: 0, chapter: "证明", lineStart: 10, lineEnd: 14, text: text)])
        PluginEngine.seed(&project)
        project.plan = ReadingPlan(methodIDs: ["active-retelling"], rationale: "复述检查", focus: [])
        return project
    }

    @discardableResult
    private func apply(_ name: String, _ args: [String: Any], to project: inout BookProject) throws -> String {
        try PluginEngine.apply(name: name, arguments: JSONSerialization.data(withJSONObject: args), to: &project, allowedUnitIDs: ["u1"])
    }

    private func receiptArguments(_ project: BookProject, _ paragraphs: [ReadingParagraph]) -> [String: Any] {
        ["batchID": project.receiptBatch!.id, "receipts": paragraphs.map { p -> [String: Any] in
            ["paragraphID": p.id, "textHash": p.textHash, "summary": "本段说明设定与相应结论。", "startQuote": p.startQuote, "endQuote": p.endQuote, "issues": []]
        }]
    }

    func testManifestPreservesUnicodeCRLFWhitespaceAndMathWithStableRanges() throws {
        let value = project(" \r\n\r\n\r\n第一段α。\r\n\r\n\r\n\r\n$$\r\nx^2+1=0\r\n$$\r\n\r\n  \r\n尾段😀。\r\n\r\n")
        let paragraphs = try ReadingLedger.paragraphs(for: value.units[0], in: value)
        XCTAssertEqual(paragraphs.map(\.text).joined(), value.units[0].text)
        XCTAssertTrue(paragraphs.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertEqual(paragraphs.first?.utf8Start, 0)
        XCTAssertEqual(paragraphs.last?.utf8End, value.units[0].text.utf8.count)
        XCTAssertTrue(paragraphs.contains { $0.kind == "math" && $0.text.contains("x^2") })
        XCTAssertEqual(paragraphs, try ReadingLedger.paragraphs(for: value.units[0], in: value))
        for pair in zip(paragraphs, paragraphs.dropFirst()) { XCTAssertEqual(pair.0.utf8End, pair.1.utf8Start) }
        let blank = project("\r\n \r\n\r\n")
        XCTAssertTrue(try ReadingLedger.paragraphs(for: blank.units[0], in: blank).isEmpty)
    }

    func testReceiptGateRejectsMissingDuplicateHashAndAnchorWithoutPartialWrites() throws {
        var value = project()
        let paragraphs = try ReadingLedger.paragraphs(for: value.units[0], in: value)
        let card: [String: Any] = ["entities": [["id": "condition", "typeID": "concept", "name": "正数条件", "evidence": [["unitID": "u1", "quote": "α > 0"]]]]]
        XCTAssertThrowsError(try apply("cards_upsert", card, to: &value))
        value.receiptBatch = try ReadingLedger.makeBatch(unit: value.units[0], paragraphs: paragraphs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(value)
        var arguments = receiptArguments(value, paragraphs)
        var rows = arguments["receipts"] as! [[String: Any]]
        let original = rows
        rows.removeLast(); arguments["receipts"] = rows
        XCTAssertThrowsError(try apply("read_receipt", arguments, to: &value))
        arguments["receipts"] = original + [original[0]]
        XCTAssertThrowsError(try apply("read_receipt", arguments, to: &value))
        rows = original; rows[0]["textHash"] = "changed"; arguments["receipts"] = rows
        XCTAssertThrowsError(try apply("read_receipt", arguments, to: &value))
        rows = original; rows[0]["endQuote"] = "不在原文中"; arguments["receipts"] = rows
        XCTAssertThrowsError(try apply("read_receipt", arguments, to: &value))
        XCTAssertEqual(try encoder.encode(value), before)
        arguments = receiptArguments(value, paragraphs)
        try apply("read_receipt", arguments, to: &value)
        try apply("read_receipt", arguments, to: &value)
        XCTAssertEqual(value.paragraphReceipts?.count, paragraphs.count)
        XCTAssertEqual(value.coverage["u1"]?.status, .pending)
        XCTAssertTrue(value.insights.isEmpty)
        try apply("cards_upsert", card, to: &value)
        XCTAssertEqual(value.entities.count, 1)
        value.units[0].text += "变化"
        XCTAssertThrowsError(try ReadingLedger.requireComplete(unitIDs: ["u1"], in: value))
    }

    func testFinishRequiresEveryMethodStepAndPreservesReceiptIssues() throws {
        var value = project()
        let unit = value.units[0], paragraphs = try ReadingLedger.paragraphs(for: unit, in: value)
        value.receiptBatch = try ReadingLedger.makeBatch(unit: unit, paragraphs: paragraphs)
        var args = receiptArguments(value, paragraphs)
        var rows = args["receipts"] as! [[String: Any]]; rows[0]["issues"] = ["符号解释需核对"]
        args["receipts"] = rows
        try apply("read_receipt", args, to: &value)
        let requirements = try ReadingLedger.stepRequirements(for: unit, in: value)
        let outputs: [[String: Any]] = requirements.map { ["stepID": $0.stepID, "result": "已复述条件并列出符号疑问。", "paragraphIDs": paragraphs.map(\.id)] }
        var finish: [String: Any] = ["unitIDs": ["u1"], "markdown": "条件与结论的分析。", "evidence": [["unitID": "u1", "quote": "设 α > 0"]], "stepResults": Array(outputs.dropLast())]
        XCTAssertThrowsError(try apply("reading_finish", finish, to: &value))
        XCTAssertTrue(value.insights.isEmpty)
        XCTAssertNil(value.readingStepResults)
        finish["stepResults"] = outputs
        try apply("reading_finish", finish, to: &value)
        try apply("reading_finish", finish, to: &value)
        XCTAssertEqual(value.readingStepResults?.count, requirements.count)
        XCTAssertEqual(value.coverage["u1"]?.status, .needsReview)
        XCTAssertEqual(value.coverage["u1"]?.attempts, 1)
        XCTAssertNoThrow(try ReadingLedger.validateStoredRecords(in: value))
    }

    func testOldJSONDecodesWithoutInventingLedgerAndDeferredIsNotAnalysis() throws {
        var value = project("")
        value.coverage["u1"]?.status = .needsReview
        value.coverage["u1"]?.message = "用户保留本单元为待识别，未读取其中内容。"
        let unit = value.units[0]
        value.insights = [ReadingInsight(id: "deferred-u1", unitIDs: ["u1"], markdown: "【未读取，待识别】\(unit.locator)。该单元尚无可靠文本，不得推断其中的事实。")]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        object.removeValue(forKey: "paragraphReceipts"); object.removeValue(forKey: "readingStepResults"); object.removeValue(forKey: "receiptBatch")
        let decoded = try JSONDecoder().decode(BookProject.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.paragraphReceipts)
        XCTAssertTrue(ReadingLedger.isDeferred(unitID: "u1", in: decoded))
        XCTAssertFalse(ReadingLedger.hasReadingAnalysis(unitID: "u1", in: decoded))
        XCTAssertThrowsError(try ReadingLedger.requireComplete(unitIDs: ["u1"], in: decoded))
        XCTAssertNoThrow(try ReadingLedger.validateStoredRecords(in: decoded))
    }

    func testReadingPlanMayExtendButCannotDropStepsDuringReading() throws {
        var value = project()
        XCTAssertThrowsError(try apply("reading_plan", ["methodIDs": ["narrative"], "rationale": "不能逃过步骤", "focus": []], to: &value))
        let response = try apply("reading_plan", ["methodIDs": ["active-retelling", "narrative"], "rationale": "补充叙事追踪", "focus": []], to: &value)
        XCTAssertTrue(response.contains("stepID"))
        XCTAssertEqual(value.plan?.methodIDs, ["active-retelling", "narrative"])
    }
}
