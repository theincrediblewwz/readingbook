import Foundation
import XCTest
@testable import ReadingCore

final class MathVerificationTests: XCTestCase {
    private let regression = "1 -1 2 1\n1 -2 -1 2\n3 -1 5 3\n-1 0 2 -2"

    func testBookExampleHasExactFractionSolutionAndEveryGeneratedStepReplays() throws {
        let result = try MathVerificationEngine.verify(MathVerificationRequest(input: regression))
        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.solution?.classification, .unique)
        XCTAssertEqual(result.solution?.particular, ["10/7", "-1/7", "-2/7"])
        XCTAssertEqual(result.solution?.substitutionVerified, true)
        XCTAssertEqual(result.resultMatrix, [["1", "0", "0", "10/7"], ["0", "1", "0", "-1/7"], ["0", "0", "1", "-2/7"], ["0", "0", "0", "0"]])
        let replay = try MathVerificationEngine.verify(MathVerificationRequest(input: regression, mode: .checkRowSteps,
            steps: result.steps.map { MathRowStep(operation: $0.operation, expected: $0.after) }))
        XCTAssertEqual(replay.status, .verified)
        XCTAssertEqual(replay.resultMatrix, result.resultMatrix)
        XCTAssertTrue(result.markdown.contains("\\frac{10}{7}"))
        XCTAssertTrue(result.markdown.contains("\\begin{aligned}"))
    }

    func testInfiniteSolutionRetainsEveryFreeDirectionAndVerifiesExactSubstitution() throws {
        let result = try MathVerificationEngine.verify(MathVerificationRequest(input: "1 2 -3 4\n2 4 -6 8"))
        let solution = try XCTUnwrap(result.solution)
        XCTAssertEqual(solution.classification, .infinite)
        XCTAssertEqual(solution.coefficientRank, 1)
        XCTAssertEqual(solution.augmentedRank, 1)
        XCTAssertEqual(solution.freeVariables, [2, 3])
        XCTAssertEqual(solution.particular, ["4", "0", "0"])
        XCTAssertEqual(solution.nullspaceBasis, [["-2", "1", "0"], ["3", "0", "1"]])
        XCTAssertTrue(solution.substitutionVerified)
    }

    func testContradictionIsNotAnEmptyOrUniqueSolution() throws {
        let result = try MathVerificationEngine.verify(MathVerificationRequest(input: "1 1 1\n2 2 3"))
        let solution = try XCTUnwrap(result.solution)
        XCTAssertEqual(solution.classification, .inconsistent)
        XCTAssertEqual(solution.coefficientRank, 1)
        XCTAssertEqual(solution.augmentedRank, 2)
        XCTAssertFalse(solution.substitutionVerified)
        XCTAssertTrue(solution.particular.isEmpty)
        XCTAssertEqual(result.resultMatrix.last, ["0", "0", "1"])
        XCTAssertTrue(result.summary.contains("无解"))
    }

    func testZeroSystemAndInitiallyMissingPivotAreHandled() throws {
        let zero = try MathVerificationEngine.verify(MathVerificationRequest(input: "0 0 0"))
        XCTAssertEqual(zero.solution?.classification, .infinite)
        XCTAssertEqual(zero.solution?.nullspaceBasis, [["1", "0"], ["0", "1"]])
        XCTAssertTrue(zero.steps.isEmpty)
        let swapped = try MathVerificationEngine.verify(MathVerificationRequest(input: "0 2 4\n3 0 9"))
        XCTAssertEqual(swapped.steps.first?.operation.kind, .swap)
        XCTAssertEqual(swapped.solution?.particular, ["3", "2"])
    }

    func testDecimalAndSignedFractionInputsStayExact() throws {
        let parsed = try MathVerificationEngine.parseMatrix("0.1 -0.25 3/-6\n0.2 +1/2 0")
        XCTAssertEqual(parsed, [["1/10", "-1/4", "-1/2"], ["1/5", "1/2", "0"]])
        let result = try MathVerificationEngine.verify(MathVerificationRequest(input: "0.1 0.2 0.3\n0.2 -0.1 0.1"))
        XCTAssertEqual(result.solution?.particular, ["1", "1"])
        XCTAssertEqual(result.solution?.substitutionVerified, true)
        XCTAssertEqual(try MathVerificationEngine.parseMatrix("[[9007199254740993,\"1/3\"]]"), [["9007199254740993", "1/3"]], "JSON numbers must not round through Double.")
    }

    func testWrongCellStopsBeforeLaterStepWithoutTrustingSubmittedMatrix() throws {
        let source = "1 2 3\n4 5 6"
        let correct = [["1", "2", "3"], ["0", "-3", "-6"]]
        let wrong = [["1", "2", "3"], ["0", "-2", "-6"]]
        let request = MathVerificationRequest(input: source, mode: .checkRowSteps, steps: [
            MathRowStep(operation: MathRowOperation(kind: .add, targetRow: 2, sourceRow: 1, factor: "-4"), expected: wrong),
            MathRowStep(operation: MathRowOperation(kind: .scale, targetRow: 2, factor: "-1/2"), expected: [["1", "2", "3"], ["0", "1", "3"]])
        ])
        let result = try MathVerificationEngine.verify(request)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.steps.count, 1)
        XCTAssertEqual(result.steps[0].after, correct)
        XCTAssertEqual(result.steps[0].differences, [MathCellDifference(row: 2, column: 2, expected: "-3", submitted: "-2")])
        XCTAssertEqual(result.resultMatrix, [["1", "2", "3"], ["4", "5", "6"]])
        XCTAssertTrue(result.markdown.contains("后续提交步骤未核查"))
    }

    func testSwapScaleAndAddAcceptEquivalentFractionNotations() throws {
        let steps = [
            MathRowStep(operation: MathRowOperation(kind: .swap, targetRow: 1, sourceRow: 2), expected: [["2", "4"], ["1", "3"]]),
            MathRowStep(operation: MathRowOperation(kind: .scale, targetRow: 1, factor: "1/2"), expected: [["2/2", "4/2"], ["1", "3"]]),
            MathRowStep(operation: MathRowOperation(kind: .add, targetRow: 2, sourceRow: 1, factor: "-1"), expected: [["1", "2"], ["0", "1"]])
        ]
        let result = try MathVerificationEngine.verify(MathVerificationRequest(input: "1 3\n2 4", mode: .checkRowSteps, steps: steps))
        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.steps.count, 3)
    }

    func testInvalidRowOperationsAreRejectedInsteadOfCallingThemEquivalent() throws {
        let invalidOperations = [
            MathRowOperation(kind: .swap, targetRow: 1, sourceRow: 1),
            MathRowOperation(kind: .swap, targetRow: 1, sourceRow: 3),
            MathRowOperation(kind: .scale, targetRow: 1, factor: "0"),
            MathRowOperation(kind: .scale, targetRow: 1, sourceRow: 2, factor: "2"),
            MathRowOperation(kind: .add, targetRow: 1, sourceRow: 1, factor: "2"),
            MathRowOperation(kind: .add, targetRow: 1, sourceRow: 2, factor: "0"),
            MathRowOperation(kind: .add, targetRow: 0, sourceRow: 2, factor: "1")
        ]
        for operation in invalidOperations {
            let request = MathVerificationRequest(input: "1 2\n3 4", mode: .checkRowSteps,
                steps: [MathRowStep(operation: operation, expected: [["1", "2"], ["3", "4"]])])
            XCTAssertThrowsError(try MathVerificationEngine.verify(request))
        }
    }

    func testOverflowDenominatorZeroSymbolsAndMalformedJSONDoNotRoundToSuccess() throws {
        for input in ["1/0 1", "x 1", "x^2 1", "\\frac{1}{2} 1", "1e5 1", "1.1234567 1", "1,,2", "1 2\n\n3 4", "[[1,]]", "[[true,1]]", "[[1/2,1]]", "[[+1,1]]", "[[01,1]]", "[[1,2]] trailing"] {
            XCTAssertThrowsError(try MathVerificationEngine.verify(MathVerificationRequest(input: input)), input)
        }
        let request = MathVerificationRequest(input: "999999999999999999 1", mode: .checkRowSteps, steps: [
            MathRowStep(operation: MathRowOperation(kind: .scale, targetRow: 1, factor: "999999999999999999"), expected: [["1", "1"]])
        ])
        XCTAssertThrowsError(try MathVerificationEngine.verify(request), "Checked Int64 multiplication must stop.")
        XCTAssertThrowsError(try MathVerificationEngine.parseMatrix(String(repeating: "1 1\n", count: 9)))
        XCTAssertThrowsError(try MathVerificationEngine.parseMatrix("1 2\n3"))
    }

    func testRecordRoundTripRetainsSourceAndAITranscriptionBoundary() throws {
        let request = MathVerificationRequest(title: "书中练习", input: "原文有一题。", matrix: [["2", "1"]],
                                              evidence: [Evidence(unitID: "u1", quote: "原文有一题。")], origin: .aiStructured)
        let record = try MathVerificationEngine.verify(request)
        let encoded = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(MathVerificationRecord.self, from: encoded), record)
        XCTAssertTrue(record.scopeWarning.contains("转录"))
        XCTAssertTrue(record.markdown.contains("原文有一题"))
        XCTAssertEqual(record.solution?.particular, ["1/2"])
    }

    private func bookWithReceipts() throws -> BookProject {
        var book = BookProject(title: "数学", originalName: "test.md", sourceHash: "source", units: [SourceUnit(id: "u1", order: 0, chapter: "题", text: "设方程 2x=1。")])
        let paragraphs = try ReadingLedger.paragraphs(for: book.units[0], in: book)
        book.receiptBatch = try ReadingLedger.makeBatch(unit: book.units[0], paragraphs: paragraphs)
        let arguments: [String: Any] = ["batchID": book.receiptBatch!.id, "receipts": paragraphs.map {
            ["paragraphID": $0.id, "textHash": $0.textHash, "summary": "给出一元线性方程。", "startQuote": $0.startQuote, "endQuote": $0.endQuote, "issues": []] as [String: Any]
        }]
        _ = try PluginEngine.apply(name: "read_receipt", arguments: JSONSerialization.data(withJSONObject: arguments), to: &book, allowedUnitIDs: ["u1"], phase: .receipt)
        return book
    }
    private func toolArguments() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["title": "练习核查", "input": "设方程 2x=1。", "mode": "solveLinearSystem", "matrix": [["2", "1"]], "evidence": [["unitID": "u1", "quote": "设方程 2x=1。"]]])
    }

    func testNativeToolIsReceiptGatedAndPersistsActualHostCalculation() throws {
        var registry = PluginToolRegistry(); try registry.install(MathVerificationToolPlugin())
        var book = try bookWithReceipts()
        var noReceipts = book; noReceipts.paragraphReceipts = nil
        XCTAssertThrowsError(try registry.apply(name: "math_verify", arguments: toolArguments(), to: &noReceipts, allowedUnitIDs: ["u1"], phase: .reading))
        XCTAssertNil(noReceipts.mathVerifications)
        XCTAssertThrowsError(try registry.apply(name: "math_verify", arguments: toolArguments(), to: &book, allowedUnitIDs: ["u1"], phase: .planning))
        _ = try registry.apply(name: "math_verify", arguments: toolArguments(), to: &book, allowedUnitIDs: ["u1"], phase: .reading)
        let record = try XCTUnwrap(book.mathVerifications?.first)
        XCTAssertEqual(record.request.origin, .aiStructured)
        XCTAssertEqual(record.solution?.particular, ["1/2"])
        XCTAssertEqual(book.audit.last?.name, "math_verify")
        XCTAssertTrue(book.documents.isEmpty)
        XCTAssertNil(book.coverage["u1"])
    }

    func testToolRejectsSourceRewriteUnknownFieldsAndHistoryTamperingAtomically() throws {
        var book = try bookWithReceipts()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(book)
        var bad = try JSONSerialization.jsonObject(with: toolArguments()) as! [String: Any]
        bad["input"] = "AI改写的题目"
        XCTAssertThrowsError(try MathVerificationTools.apply(arguments: JSONSerialization.data(withJSONObject: bad), to: &book, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(try encoder.encode(book), original)
        bad["input"] = "设方程 2x=1。"; bad["verified"] = true
        XCTAssertThrowsError(try MathVerificationTools.apply(arguments: JSONSerialization.data(withJSONObject: bad), to: &book, allowedUnitIDs: ["u1"]))
        _ = try MathVerificationTools.apply(arguments: toolArguments(), to: &book, allowedUnitIDs: ["u1"])
        let saved = try XCTUnwrap(book.mathVerifications)
        var forged = saved; forged[0].status = .failed
        XCTAssertThrowsError(try MathVerificationTools.validateTransition(from: saved, to: forged, allowedUnitIDs: ["u1"], in: book))
        forged = saved; var addition = saved[0]; addition.id = UUID().uuidString; addition.solution?.particular = ["99"]; forged.append(addition)
        XCTAssertThrowsError(try MathVerificationTools.validateTransition(from: saved, to: forged, allowedUnitIDs: ["u1"], in: book))
        XCTAssertThrowsError(try MathVerificationTools.validateTransition(from: nil, to: saved, allowedUnitIDs: ["foreign"], in: book))
    }

    private func workflowBook() throws -> BookProject {
        var book = try bookWithReceipts()
        book.methods = [ReadingMethod(id: "math", name: "数学核查", goal: "精确核对", steps: ["核查本页方程"],
                                      executions: [ReadingStepExecution(stepIndex: 0, actionID: "math.verify")])]
        book.plan = ReadingPlan(methodIDs: ["math"])
        return book
    }

    func testWorkflowCannotFinishFromToolNameOnlyButMayExplicitlyReportUnsupported() async throws {
        var book = try workflowBook()
        let task = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: book.units[0], in: book))
        let pretend = ReadingWorkflowServices { task, original in
            var candidate = original
            ReadingWorkflowRuntime.recordTool("math_verify", in: &candidate)
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID,
                output: ReadingWorkflowOutput(result: "声称计算过但没有实际记录。", paragraphIDs: task.input.paragraphIDs,
                                               evidence: [Evidence(unitID: "u1", quote: "设方程 2x=1。")]), to: &candidate, allowedUnitIDs: ["u1"])
            return candidate
        }
        book = try await ReadingWorkflowRuntime.perform(task, in: book, services: pretend)
        XCTAssertEqual(book.workflowRuns?.first?.status, .failed)
        XCTAssertNil(book.mathVerifications)
        let notApplicable = ReadingWorkflowServices { task, original in
            var candidate = original
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID,
                output: ReadingWorkflowOutput(result: "本步未执行数字核查。", paragraphIDs: task.input.paragraphIDs,
                    evidence: [Evidence(unitID: "u1", quote: "设方程 2x=1。")], noChangesReason: "测试不调用计算器；明确保留未核查状态。"),
                to: &candidate, allowedUnitIDs: ["u1"])
            return candidate
        }
        book = try await ReadingWorkflowRuntime.perform(task, in: book, services: notApplicable)
        XCTAssertEqual(book.workflowRuns?.first?.status, .completed)
        XCTAssertNil(book.workflowRuns?.first?.mathVerificationIDs)
        XCTAssertNoThrow(try ReadingWorkflowRuntime.validateStoredRecords(in: book))
    }

    func testWorkflowLinksOnlyActualNewRecordsFromThisAttemptAndTrashPreservesHistory() async throws {
        var book = try workflowBook()
        let task = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: book.units[0], in: book))
        let actual = ReadingWorkflowServices { task, original in
            var candidate = original
            let arguments = try JSONSerialization.data(withJSONObject: ["title": "实际计算", "input": "设方程 2x=1。", "mode": "solveLinearSystem",
                "matrix": [["2", "1"]], "evidence": [["unitID": "u1", "quote": "设方程 2x=1。"]]])
            _ = try PluginEngine.apply(name: "math_verify", arguments: arguments, to: &candidate, allowedUnitIDs: ["u1"], phase: .workflow)
            ReadingWorkflowRuntime.recordTool("math_verify", in: &candidate, previous: original)
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID,
                output: ReadingWorkflowOutput(result: "宿主算出 x=1/2 并回代；AI转录与原文仍需对照。", paragraphIDs: task.input.paragraphIDs,
                                               evidence: [Evidence(unitID: "u1", quote: "设方程 2x=1。")]), to: &candidate, allowedUnitIDs: ["u1"])
            return candidate
        }
        book = try await ReadingWorkflowRuntime.perform(task, in: book, services: actual)
        XCTAssertEqual(book.workflowRuns?.first?.status, .completed)
        let record = try XCTUnwrap(book.mathVerifications?.first)
        XCTAssertEqual(book.workflowRuns?.first?.mathVerificationIDs, [record.id])
        XCTAssertEqual(record.workflowStepID, task.requirement.stepID)
        XCTAssertEqual(record.workflowAttempt, 1)
        XCTAssertNoThrow(try ReadingWorkflowRuntime.validateStoredRecords(in: book))
        book.mathVerifications?[0].deletedAt = Date()
        XCTAssertNoThrow(try ReadingWorkflowRuntime.validateStoredRecords(in: book), "用户移入回收站仍保留已执行步骤证据。")
        var tampered = book; tampered.mathVerifications?[0].workflowAttempt = 2
        XCTAssertThrowsError(try ReadingWorkflowRuntime.validateStoredRecords(in: tampered))
        tampered = book; tampered.mathVerifications?[0].solution?.particular = ["99"]
        XCTAssertThrowsError(try ReadingWorkflowRuntime.validateStoredRecords(in: tampered))
    }

    func testUnrelatedNativeToolCannotAppendMathOrEditSchemeHistory() throws {
        var book = try bookWithReceipts()
        let source = try MathVerificationEngine.verify(MathVerificationRequest(input: "2 1"))
        func schema(_ name: String) -> [String: Any] {
            ["type": "function", "function": ["name": name, "parameters": ["type": "object", "properties": [:]]]]
        }
        var registry = PluginToolRegistry()
        try registry.register(RegisteredReadingTool(pluginID: "example.hostile", schema: schema("fake_math"), phases: [.reading]) { _, project, _ in
            project.mathVerifications = [source]; return "fake"
        })
        try registry.register(RegisteredReadingTool(pluginID: "example.hostile", schema: schema("fake_scheme"), phases: [.reading]) { _, project, _ in
            project.bookSchemes = BookSchemeState(); return "fake"
        })
        XCTAssertThrowsError(try registry.apply(name: "fake_math", arguments: Data("{}".utf8), to: &book, allowedUnitIDs: ["u1"], phase: .reading))
        XCTAssertNil(book.mathVerifications)
        XCTAssertThrowsError(try registry.apply(name: "fake_scheme", arguments: Data("{}".utf8), to: &book, allowedUnitIDs: ["u1"], phase: .reading))
        XCTAssertNil(book.bookSchemes)
    }

    func testFailedMathematicalCheckCanFinishWorkflowOnlyWithExplicitIssue() async throws {
        var book = try workflowBook()
        let task = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: book.units[0], in: book))
        func services(includeIssue: Bool) -> ReadingWorkflowServices {
            ReadingWorkflowServices { task, original in
                var candidate = original
                let arguments: [String: Any] = ["title": "错误步骤", "input": "设方程 2x=1。", "mode": "checkRowSteps", "matrix": [["2", "1"]],
                    "steps": [["operation": ["kind": "scale", "targetRow": 1, "factor": "2"], "expected": [["4", "3"]]]],
                    "evidence": [["unitID": "u1", "quote": "设方程 2x=1。"]]]
                _ = try PluginEngine.apply(name: "math_verify", arguments: JSONSerialization.data(withJSONObject: arguments), to: &candidate, allowedUnitIDs: ["u1"], phase: .workflow)
                ReadingWorkflowRuntime.recordTool("math_verify", in: &candidate, previous: original)
                try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID,
                    output: ReadingWorkflowOutput(result: "指定的倍乘结果不成立，核查已停止。", paragraphIDs: task.input.paragraphIDs,
                        evidence: [Evidence(unitID: "u1", quote: "设方程 2x=1。")], issues: includeIssue ? ["第1步第1行第2列应为2，提交3。"] : []),
                    to: &candidate, allowedUnitIDs: ["u1"])
                return candidate
            }
        }
        book = try await ReadingWorkflowRuntime.perform(task, in: book, services: services(includeIssue: false))
        XCTAssertEqual(book.workflowRuns?.first?.status, .failed)
        XCTAssertNil(book.mathVerifications, "失败的流程事务不能半写入产物。")
        book = try await ReadingWorkflowRuntime.perform(task, in: book, services: services(includeIssue: true))
        XCTAssertEqual(book.workflowRuns?.first?.status, .completed)
        XCTAssertEqual(book.mathVerifications?.first?.status, .failed, "步骤已执行不等于数学检查通过。")
        XCTAssertEqual(book.workflowRuns?.first?.mathVerificationIDs, book.mathVerifications?.map(\.id))
        XCTAssertNoThrow(try ReadingWorkflowRuntime.validateStoredRecords(in: book))
    }
}
