import Foundation
import XCTest
@testable import ReadingCore

final class SmartReadingTests: XCTestCase {
    private func project() -> BookProject {
        var value = BookProject(title: "范围测试", originalName: "book.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            SourceUnit(id: "u1", order: 0, chapter: "第一章", page: 1, text: "第一段。\n\n末段。\n"),
            SourceUnit(id: "u2", order: 1, chapter: "第一章", page: 1, text: "同一页的后半部分。\n"),
            SourceUnit(id: "u3", order: 2, chapter: "第二章", page: 2, text: "第二页。\n"),
            SourceUnit(id: "u4", order: 3, chapter: "第二章", page: 3, text: "第三页。\n")
        ])
        PluginEngine.seed(&value)
        value.plan = ReadingPlan(methodIDs: ["genre.history"])
        return value
    }

    func testPageChapterAndRangeFreezeAllMatchingUnitsAndRoundTrip() throws {
        var value = project()
        let page = try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .currentPage), in: value, currentUnitID: "u2")
        XCTAssertEqual(page.unitIDs, ["u1", "u2"], "页码范围包含该页的全部拆分单元。")
        XCTAssertEqual(page.scopeTitle, "第 1 页")
        let chapter = try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .currentChapter), in: value, currentUnitID: "u3")
        XCTAssertEqual(chapter.unitIDs, ["u3", "u4"])
        let range = try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .pageRange, pageStart: 1, pageEnd: 2), in: value, currentUnitID: "u4")
        XCTAssertEqual(range.unitIDs, ["u1", "u2", "u3"])
        value.smartReading = page
        let restored = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.smartReading?.unitIDs, page.unitIDs)
        XCTAssertEqual(restored.smartReading?.selection, page.selection)
        XCTAssertEqual(restored.units, value.units, "冻结范围不能把其他页从项目删除。")
        XCTAssertNoThrow(try SmartReadingRuntime.validateStoredState(in: restored))
    }

    func testInvalidRangeAndUnavailableMethodsFailBeforeRequests() throws {
        var value = project()
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .pageRange, pageStart: 3, pageEnd: 2), in: value, currentUnitID: "u1"))
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .pageRange, pageStart: 1, pageEnd: 4), in: value, currentUnitID: "u1"))
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(SmartReadingSelection(preferredMethodIDs: ["narrative"]), in: value, currentUnitID: "u1"))
        XCTAssertThrowsError(try SmartReadingRuntime.selectedUnits(in: value, allowedUnitIDs: []))
        XCTAssertThrowsError(try SmartReadingRuntime.selectedUnits(in: value, allowedUnitIDs: ["outside"]))
        value.units[0].page = nil
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .currentPage), in: value, currentUnitID: "u1"))
    }

    func testRecommendedGenresKeepLegacyDefinitionsAndHashesUnchanged() throws {
        var value = project()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacy = try XCTUnwrap(value.methods.first { $0.id == "narrative" })
        let before = try encoder.encode(legacy)
        PluginEngine.seed(&value)
        XCTAssertEqual(try encoder.encode(XCTUnwrap(value.methods.first { $0.id == "narrative" })), before)
        XCTAssertTrue(PluginEngine.activeMethods(in: value).contains { $0.id == "narrative" })
        XCTAssertEqual(PluginEngine.recommendedMethods.count, 5)
        XCTAssertTrue(PluginEngine.recommendedMethods(in: value).allSatisfy { !PluginEngine.legacyStarterMethodIDs.contains($0.id) })
        for method in PluginEngine.recommendedMethods { XCTAssertNoThrow(try ReadingWorkflowRuntime.validate(method: method)) }
        value.methods.append(ReadingMethod(id: "custom.user", name: "我的方法", goal: "保留自定义", steps: ["提取本段疑问"]))
        XCTAssertTrue(PluginEngine.recommendedMethods(in: value).contains { $0.id == "custom.user" })
        XCTAssertNoThrow(try SmartReadingRuntime.freeze(SmartReadingSelection(preferredMethodIDs: ["genre.history", "genre.war", "custom.user"]), in: value, currentUnitID: "u1"))
    }

    func testFrozenScopeRejectsChangedTextIDsAndTamperedManifest() throws {
        var value = project()
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .currentPage), in: value, currentUnitID: "u1")
        var changed = value; changed.units[0].text += "新增内容。"
        XCTAssertThrowsError(try SmartReadingRuntime.validateStoredState(in: changed))
        var tampered = value; tampered.smartReading?.unitIDs = ["u1"]; tampered.smartReading?.unitHashes.removeValue(forKey: "u2")
        XCTAssertThrowsError(try SmartReadingRuntime.validateStoredState(in: tampered), "当前页不能只保留该页的一个拆分单元。")
        tampered = value; tampered.smartReading?.unitHashes["u1"] = "bad"
        XCTAssertThrowsError(try SmartReadingRuntime.validateStoredState(in: tampered))
        tampered = value; tampered.smartReading?.lastMessage = String(repeating: "长", count: 4001)
        XCTAssertThrowsError(try SmartReadingRuntime.validateStoredState(in: tampered))
    }

    private func completedUnit() async throws -> BookProject {
        var value = project()
        value.methods = [ReadingMethod(id: "custom", name: "分析", goal: "保存实际执行", steps: ["说明本段内容"], executions: [ReadingStepExecution(stepIndex: 0, actionID: "ai.analyze")])]
        value.plan = ReadingPlan(methodIDs: ["custom"])
        let unit = value.units[0]
        value.paragraphReceipts = try ReadingLedger.paragraphs(for: unit, in: value).map {
            ParagraphReceipt(paragraphID: $0.id, unitID: $0.unitID, unitHash: $0.unitHash, textHash: $0.textHash,
                             utf8Start: $0.utf8Start, utf8End: $0.utf8End, summary: "本段交代起止内容。", startQuote: $0.startQuote, endQuote: $0.endQuote, issues: [], createdAt: Date())
        }
        let task = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: unit, in: value))
        value = try await ReadingWorkflowRuntime.perform(task, in: value, services: ReadingWorkflowServices { task, original in
            var result = original
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID,
                output: ReadingWorkflowOutput(result: "本段包含第一段与末段。", paragraphIDs: task.input.paragraphIDs, evidence: [Evidence(unitID: "u1", quote: "第一段。")]),
                to: &result, allowedUnitIDs: ["u1"])
            return result
        })
        value.insights = [ReadingInsight(id: "analysis-u1", unitIDs: ["u1"], markdown: "已保存分析。")]
        var entry = CoverageEntry(); entry.status = .completed; entry.updatedAt = Date()
        value.coverage["u1"] = entry
        return value
    }

    func testCoverageAndOldMethodResultsCannotSkipANewMethod() async throws {
        var value = project()
        value.coverage["u1"]?.status = .completed
        value.insights = [ReadingInsight(id: "old", unitIDs: ["u1"], markdown: "历史分析")]
        XCTAssertFalse(SmartReadingRuntime.isUnitComplete(value.units[0], in: value))
        value = try await completedUnit()
        XCTAssertTrue(SmartReadingRuntime.isUnitComplete(value.units[0], in: value))
        value.methods[0].steps[0] = "新增的本轮方法步骤"
        XCTAssertFalse(SmartReadingRuntime.isUnitComplete(value.units[0], in: value))
        XCTAssertEqual(try SmartReadingRuntime.nextUnit(in: value, allowedUnitIDs: ["u1"])?.id, "u1")
        value.coverage["u2"]?.status = .pending
        let complete = try await completedUnit()
        XCTAssertNil(try SmartReadingRuntime.nextUnit(in: complete, allowedUnitIDs: ["u1"]), "范围外待处理页不扩大任务。")
    }

    func testNewStepNeedsFinalizationEvenWhenOldCoverageWasCompleted() async throws {
        var value = try await completedUnit()
        value.coverage["u1"]?.updatedAt = .distantPast
        XCTAssertFalse(SmartReadingRuntime.isUnitComplete(value.units[0], in: value), "新步骤刚完成时，不能借用更早的finish记录跳过本轮汇总。")
        value.coverage["u1"]?.updatedAt = Date()
        XCTAssertTrue(SmartReadingRuntime.isUnitComplete(value.units[0], in: value))
    }

    func testDeferredAndConfirmedBlankStayDistinctFromAICompletion() throws {
        var value = project()
        value.units[0].text = ""; value.units[1].text = ""
        value.coverage["u1"]?.status = .needsReview; value.coverage["u1"]?.message = "用户保留本单元为待识别，未读取其中内容。"
        value.insights.append(ReadingInsight(id: "deferred-u1", unitIDs: ["u1"], markdown: "【未读取，待识别】\(value.units[0].locator)。该单元尚无可靠文本，不得推断其中的事实。"))
        value.coverage["u2"]?.status = .completed; value.coverage["u2"]?.message = "用户确认此单元为原书空白。"
        value.insights.append(ReadingInsight(id: "blank-u2", unitIDs: ["u2"], markdown: "用户对照原书确认此单元为空白，无需 AI 提取文字。"))
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(), in: value, currentUnitID: "u1")
        XCTAssertEqual(try SmartReadingRuntime.analysisUnitIDs(in: value, allowedUnitIDs: ["u1", "u2", "u3", "u4"]), ["u3", "u4"])
        XCTAssertEqual(try SmartReadingRuntime.nextUnit(in: value, allowedUnitIDs: ["u1", "u2", "u3", "u4"])?.id, "u3")
        let progress = try XCTUnwrap(SmartReadingRuntime.progress(in: value))
        XCTAssertEqual(progress.excludedCount, 1); XCTAssertEqual(progress.blankCount, 1)
        XCTAssertEqual(progress.completed, 0); XCTAssertEqual(progress.total, 4)
        value.insights.removeAll { $0.id == "blank-u2" }
        XCTAssertFalse(SmartReadingRuntime.isConfirmedBlank(value.units[1], in: value))
        XCTAssertEqual(try SmartReadingRuntime.nextUnit(in: value, allowedUnitIDs: ["u2"])?.id, "u2", "单有空文字与completed标签不能假装已核对空白。")
    }

    func testProgressCacheInvalidatesChangedCheckpointsAndMethods() async throws {
        var value = project()
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(scope: .currentPage), in: value, currentUnitID: "u1")
        var cache = SmartReadingProgressCache()
        let before = try XCTUnwrap(SmartReadingRuntime.progress(in: value, cache: &cache))
        XCTAssertEqual(before.completed, 0); XCTAssertEqual(before.receiptCount, 0)
        let finished = try await completedUnit()
        value.plan = finished.plan; value.methods = finished.methods; value.coverage = finished.coverage
        value.paragraphReceipts = finished.paragraphReceipts; value.readingStepResults = finished.readingStepResults
        value.workflowRuns = finished.workflowRuns; value.insights = finished.insights
        let after = try XCTUnwrap(SmartReadingRuntime.progress(in: value, cache: &cache, validateSource: false))
        XCTAssertEqual(after.completed, 1); XCTAssertGreaterThan(after.receiptCount, 0)
        XCTAssertEqual(after.currentUnitID, "u2")
        value.methods[0].steps[0] = "方法已经变更"
        let changed = try XCTUnwrap(SmartReadingRuntime.progress(in: value, cache: &cache, validateSource: false))
        XCTAssertEqual(changed.completed, 0); XCTAssertEqual(changed.currentUnitID, "u1")
    }

    func testOCRReplacementInvalidatesFrozenScopeWithoutBlockingRecognition() throws {
        var value = project(); value.units[0].text = ""; value.units[1].text = ""
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(), in: value, currentUnitID: "u1")
        let recognized = try OCRIntegration.applying(OCRPageResult(page: 1, markdown: "识别得到的真实原文。", issues: [], model: "test-vision"), to: value)
        XCTAssertNil(recognized.smartReading)
        XCTAssertNil(recognized.plan)
        XCTAssertTrue(recognized.units.contains { $0.page == 2 && $0.id == "u3" })
        XCTAssertNoThrow(try SmartReadingRuntime.validateStoredState(in: recognized))
    }

    func testRepositoryRejectsTamperedSmartReadingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartReadingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.txt")
        try Data("真实原文。\n".utf8).write(to: source)
        var value = try await BookImporter.importFile(at: source)
        PluginEngine.seed(&value)
        value.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(), in: value, currentUnitID: value.units.first?.id)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        try await repository.create(value, sourceURL: source)
        value.smartReading?.unitHashes[value.units[0].id] = String(repeating: "0", count: 64)
        do { try await repository.save(value); XCTFail("损坏范围hash必须在存储边界拒绝。") }
        catch { XCTAssertTrue(error.localizedDescription.contains("原文") || error.localizedDescription.contains("范围")) }
        let loaded = try await repository.loadAll()
        XCTAssertEqual(loaded.first?.smartReading?.unitIDs, value.units.map(\.id))
    }
}
