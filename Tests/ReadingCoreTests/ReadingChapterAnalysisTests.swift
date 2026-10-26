import Foundation
import XCTest
@testable import ReadingCore

final class ReadingChapterAnalysisTests: XCTestCase {
    private func book() throws -> BookProject {
        var value = BookProject(title: "同页分章", originalName: "book.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            SourceUnit(id: "u", order: 0, chapter: "同页分章", page: 1, text: "前言。\n第一章\n甲走进城。\n第二章\n乙留在村。")
        ])
        PluginEngine.seed(&value)
        value.plan = ReadingPlan(methodIDs: ["genre.history"])
        return value
    }
    private func installOutline(in value: inout BookProject) throws {
        let entries = try ["第一章", "第二章"].map { title -> BookOutlineEntry in
            let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "u", quote: title, in: value)
            return BookOutlineEntry(id: anchor.id, title: title, page: 1, anchor: anchor)
        }
        value.generatedOutline = GeneratedBookOutline(sourceHash: value.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: value), scannedUnitCount: 1, totalUnitCount: 1, entries: entries)
    }
    private var configuration: ReadingExecutionConfiguration {
        .init(granularity: .chapter, steps: [ReadingExecutionStep(id: "part", title: "讲清内容"),
            ReadingExecutionStep(id: "chapter", title: "章末回顾", frequency: .chapter),
            ReadingExecutionStep(id: "book", title: "本轮回顾", frequency: .book)])
    }
    private func authorize<T>(_ chunk: ReadingAnalysisChunk, in project: BookProject, _ body: () throws -> T) throws -> T {
        let session = try XCTUnwrap(project.smartReading)
        return try ReadingAnalysisAuthority.$current.withValue(.init(bookID: project.id, sessionID: session.id, sourceHash: project.sourceHash,
            chunk: chunk, unitHashes: session.unitHashes.filter { chunk.unitIDs.contains($0.key) }), operation: body)
    }
    private func complete(_ chunk: ReadingAnalysisChunk, in value: inout BookProject) throws {
        let text = try SmartReadingRuntime.analysisSourceUnits(in: value, allowedUnitIDs: Set(chunk.unitIDs), ranges: chunk.sourceRanges)
        let input = try JSONSerialization.data(withJSONObject: ["unitIDs": chunk.unitIDs, "completedStepIDs": chunk.stepIDs,
            "markdown": "已读本部分原文。", "evidence": text.map { ["unitID": $0.id, "quote": $0.text] }])
        let original = value
        try authorize(chunk, in: original) { _ = try SmartReadingRuntime.completeAnalysis(arguments: input, in: &value, allowedUnitIDs: Set(chunk.unitIDs)) }
    }

    func testSameUnitChaptersUseExactFrozenSlicesAndAllSlicesMustComplete() throws {
        var value = try book(); try installOutline(in: &value)
        let original = value.units
        value.smartReading = try SmartReadingRuntime.freeze(.init(execution: configuration), in: value, currentUnitID: "u")
        let planning = try SmartReadingRuntime.analysisSourceUnits(in: value, allowedUnitIDs: ["u"])
        XCTAssertEqual(planning[0].text.utf8.map { $0 }, original[0].text.utf8.map { $0 }, "章界不能给预读原文插入额外换行。")
        let chunks = try SmartReadingRuntime.analysisChunks(in: value)
        XCTAssertEqual(chunks.count, 3, "前言和同页两章分别分析，不重写原单位。")
        let texts = try chunks.map { try SmartReadingRuntime.analysisSourceUnits(in: value, allowedUnitIDs: Set($0.unitIDs), ranges: $0.sourceRanges).map(\.text).joined() }
        XCTAssertEqual(texts.joined(), original[0].text)
        XCTAssertFalse(texts[1].contains("乙留在村"))
        XCTAssertFalse(texts[2].contains("甲走进城"))
        try complete(chunks[0], in: &value)
        XCTAssertFalse(SmartReadingRuntime.isUnitComplete(original[0], in: value))
        XCTAssertEqual(try SmartReadingRuntime.progress(in: value)?.completed, 0)
        for chunk in chunks.dropFirst() { try complete(chunk, in: &value) }
        XCTAssertTrue(SmartReadingRuntime.isUnitComplete(original[0], in: value))
        XCTAssertEqual(try SmartReadingRuntime.progress(in: value)?.completed, 1)
        XCTAssertEqual(value.units, original)
        let disjoint = [ReadingSourceRange(unitID: "u", startUTF16: 0, endUTF16: 1), ReadingSourceRange(unitID: "u", startUTF16: 2, endUTF16: 3)]
        XCTAssertThrowsError(try SmartReadingRuntime.analysisSourceUnits(in: value, allowedUnitIDs: ["u"], ranges: disjoint), "不能把有缺口的选段伪装成连续原文。")
        XCTAssertNil(value.paragraphReceipts)
        XCTAssertNoThrow(try SmartReadingRuntime.validateStoredState(in: value))
        let roundTrip = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(try SmartReadingRuntime.analysisChunks(in: roundTrip), chunks)
    }

    func testCurrentChapterPlanningAndNewEvidenceCannotEscapeSameUnitBoundary() throws {
        var value = try book(); try installOutline(in: &value)
        let offset = (value.units[0].text as NSString).range(of: "甲走进城").location
        let selection = SmartReadingSelection(scope: .currentChapter, execution: configuration)
        value.smartReading = try SmartReadingRuntime.freeze(selection, in: value, currentUnitID: "u", currentOffsetUTF16: offset)
        let preview = try SmartReadingRuntime.analysisSourceUnits(in: value, allowedUnitIDs: ["u"])
        XCTAssertEqual(preview.count, 1)
        XCTAssertTrue(preview[0].text.contains("甲走进城"))
        XCTAssertFalse(preview[0].text.contains("乙留在村"))
        XCTAssertFalse(preview[0].text.contains("前言"))
        let chunk = try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: value).first)
        let inside = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "u", quote: "甲走进城。", in: value)
        let outside = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "u", quote: "乙留在村。", in: value)
        try authorize(chunk, in: value) {
            XCTAssertTrue(SmartReadingRuntime.analysisEvidenceAdmitted(.init(unitID: "u", quote: "甲走进城。"), in: value))
            XCTAssertFalse(SmartReadingRuntime.analysisEvidenceAdmitted(.init(unitID: "u", quote: "乙留在村。"), in: value))
            XCTAssertTrue(SmartReadingRuntime.analysisAnchorAdmitted(inside, in: value))
            XCTAssertFalse(SmartReadingRuntime.analysisAnchorAdmitted(outside, in: value))
        }
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(selection, in: value, currentUnitID: "u"), "同页多章无精确位置不能猜。")
        XCTAssertTrue(SmartReadingRuntime.selectionMatchesFrozenContext(selection, in: value, currentUnitID: "u", currentOffsetUTF16: offset))
        XCTAssertFalse(SmartReadingRuntime.selectionMatchesFrozenContext(selection, in: value, currentUnitID: "u", currentOffsetUTF16: outside.utf16Location))
    }

    func testPartialUnitChapterNeverFeedsWholeUnitToLegacyOrCloseReceipts() throws {
        var value = try book(); try installOutline(in: &value)
        let offset = (value.units[0].text as NSString).range(of: "甲走进城").location
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(.init(scope: .currentChapter), in: value, currentUnitID: "u", currentOffsetUTF16: offset))
        var close = configuration; close.precision = .close
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(.init(scope: .currentChapter, execution: close), in: value, currentUnitID: "u", currentOffsetUTF16: offset))
        XCTAssertNoThrow(try SmartReadingRuntime.freeze(.init(scope: .currentPage, execution: close), in: value, currentUnitID: "u"), "明确页范围的精读仍有全单位授权。")
        XCTAssertNoThrow(try SmartReadingRuntime.freeze(.init(execution: close), in: value, currentUnitID: "u"))
    }

    func testPausedLegacyRunKeepsCompletedChunksAndRepartitionsOnlyPendingWork() throws {
        var value = try book()
        value.units.append(SourceUnit(id: "v", order: 1, chapter: value.title, page: 2, text: "第三章\n丙来到山中。"))
        value.smartReading = try SmartReadingRuntime.freeze(.init(execution: .init(granularity: .page, steps: [])), in: value, currentUnitID: "u")
        let old = try SmartReadingRuntime.analysisChunks(in: value)
        try complete(old[0], in: &value)
        value.smartReading?.status = .paused
        let first = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "u", quote: "第一章", in: value)
        let second = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "u", quote: "第二章", in: value)
        let third = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "v", quote: "第三章", in: value)
        value.generatedOutline = GeneratedBookOutline(sourceHash: value.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: value), scannedUnitCount: 2, totalUnitCount: 2,
            entries: [BookOutlineEntry(id: first.id, title: "第一章", page: 1, anchor: first), BookOutlineEntry(id: second.id, title: "第二章", page: 1, anchor: second), BookOutlineEntry(id: third.id, title: "第三章", page: 2, anchor: third)])
        XCTAssertTrue(try SmartReadingRuntime.freezeChapterBoundaries(in: &value))
        let chunks = try SmartReadingRuntime.analysisChunks(in: value)
        XCTAssertEqual(chunks.first, old.first)
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(chunks[0], in: value))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertNotNil(chunks[1].sourceRanges)
        let frozen = chunks
        value.generatedOutline = nil
        XCTAssertEqual(try SmartReadingRuntime.analysisChunks(in: value), frozen, "运行目录快照不跟随实时目录更新。")
        XCTAssertNoThrow(try SmartReadingRuntime.validateStoredState(in: value))
        value.smartReading?.selection.execution?.steps = [ReadingExecutionStep(id: "new", title: "新增关注")]
        XCTAssertFalse(try SmartReadingRuntime.analysisChunks(in: value).contains { $0.id == old[0].id }, "变更实际步骤不可继续冒认旧完成。")
    }

    func testPartialDirectoryDoesNotBlockExplicitPageWorkOrSilentlyOmitUnscannedUnits() throws {
        var value = try book()
        value.units = [
            SourceUnit(id: "u", order: 0, chapter: value.title, page: 1, text: "第一章\n甲。"),
            SourceUnit(id: "v", order: 1, chapter: value.title, page: 2, text: "第二章\n乙。"),
            SourceUnit(id: "w", order: 2, chapter: value.title, page: 3, text: "第三章\n丙。")
        ]
        let page = SmartReadingSelection(execution: .init(granularity: .page, steps: []))
        value.smartReading = try SmartReadingRuntime.freeze(page, in: value, currentUnitID: "u")
        let old = try SmartReadingRuntime.analysisChunks(in: value)
        try complete(old[0], in: &value)
        value.smartReading?.status = .paused
        let anchors = try [("u", "第一章"), ("v", "第二章")].map { unitID, title in
            try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: unitID, quote: title, in: value)
        }
        value.generatedOutline = GeneratedBookOutline(sourceHash: value.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: value), scannedUnitCount: 2, totalUnitCount: 3,
            entries: anchors.map { BookOutlineEntry(id: $0.id, title: $0.quote, page: $0.unitID == "u" ? 1 : 2, anchor: $0) })
        XCTAssertFalse(try SmartReadingRuntime.freezeChapterBoundaries(in: &value))
        XCTAssertNil(value.smartReading?.chapterIndex)
        XCTAssertEqual(try SmartReadingRuntime.analysisChunks(in: value), old, "未扫描到的第三页仍在原按页队列。")
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(old[0], in: value))
        let frozen = try SmartReadingRuntime.freeze(page, in: value, currentUnitID: "u")
        XCTAssertNil(frozen.chapterIndex)
        XCTAssertEqual(frozen.unitIDs, ["u", "v", "w"])
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(.init(execution: .init(granularity: .chapter)), in: value, currentUnitID: "u"))
        XCTAssertThrowsError(try SmartReadingRuntime.freeze(.init(execution: .init(granularity: .adaptive)), in: value, currentUnitID: "u"))
        XCTAssertNoThrow(try SmartReadingRuntime.freeze(.init(scope: .currentPage, execution: .init(granularity: .page)), in: value, currentUnitID: "u"))
    }

    func testOneLargeOriginalUnitIsBoundedByCharacterBudgetWithoutChangingItsID() throws {
        var value = try book()
        value.units[0].text = "第一章\n" + String(repeating: "文😀", count: 21_000)
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "u", quote: "第一章", in: value)
        value.generatedOutline = GeneratedBookOutline(sourceHash: value.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: value), scannedUnitCount: 1, totalUnitCount: 1,
            entries: [BookOutlineEntry(id: anchor.id, title: "第一章", page: 1, anchor: anchor)])
        value.smartReading = try SmartReadingRuntime.freeze(.init(execution: configuration), in: value, currentUnitID: "u")
        let chunks = try SmartReadingRuntime.analysisChunks(in: value)
        XCTAssertEqual(chunks.count, 3)
        var rendered = ""
        for chunk in chunks {
            let text = try SmartReadingRuntime.analysisSourceUnits(in: value, allowedUnitIDs: ["u"], ranges: chunk.sourceRanges)[0].text
            XCTAssertLessThanOrEqual(text.count, 20_000)
            XCTAssertEqual(chunk.unitIDs, ["u"])
            rendered += text
        }
        XCTAssertEqual(rendered, value.units[0].text)
        XCTAssertFalse(chunks[0].stepIDs.contains("chapter"))
        XCTAssertTrue(chunks.last?.stepIDs.contains("chapter") == true)
        try complete(chunks[0], in: &value)
        try complete(chunks[1], in: &value)
        let last = try XCTUnwrap(chunks.last), snapshot = value
        try authorize(last, in: snapshot) {
            var candidate = snapshot
            let result = try PluginEngine.registry.apply(name: "analysis_outline", arguments: Data(#"{"scope":"chapter"}"#.utf8), to: &candidate, allowedUnitIDs: ["u"], phase: .reading)
            let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            XCTAssertEqual(raw["total"] as? Int, 2, "同单位的前两个精确片段也应可供章末回顾。")
            let rows = try XCTUnwrap(raw["items"] as? [[String: Any]])
            XCTAssertEqual(rows.compactMap { $0["firstUTF16"] as? Int }, chunks.dropLast().compactMap { $0.sourceRanges?.first?.startUTF16 }, "同单位的章末资料按原文偏移排列，不能按chunk哈希排序。")
        }
    }
}
