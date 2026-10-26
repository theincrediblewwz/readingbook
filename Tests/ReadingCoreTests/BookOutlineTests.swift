import Foundation
import XCTest
@testable import ReadingCore
#if os(macOS)
import CoreGraphics
import PDFKit
#endif

final class BookOutlineTests: XCTestCase {
    private func book(count: Int = 3) throws -> BookProject {
        let units = (0..<count).map { index in
            SourceUnit(id: "u\(index)", order: index, chapter: "第 \(index + 1) 页", page: index + 1,
                text: "第\(index + 1)章\n本章标题\n这是本章的开头原文。\n这是正文。")
        }
        return BookProject(title: "目录", originalName: "book.pdf", sourceHash: try BookImporter.sha256(Data("original-pdf-placeholder".utf8)), units: units)
    }
    private func response(_ value: Any, finish: String = "stop") throws -> ProviderClient.Result {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        let message = try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": content])
        return ProviderClient.Result(message: try JSONDecoder().decode(ProviderClient.Message.self, from: message), finishReason: finish, tokenCost: 8)
    }
    private func firstBatch(_ project: BookProject) throws -> BookOutlineBatch {
        let prepared = try BookOutlineRuntime.prepare(in: project)
        return try prepared.request(for: XCTUnwrap(prepared.batches.first))
    }

    func testOldBookOmitsDirectoryAndCandidatesAreBoundedLiteralLocations() throws {
        let project = try book(count: 70)
        let encoded = try JSONEncoder().encode(project)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("generatedOutline"))
        XCTAssertNil(try JSONDecoder().decode(BookProject.self, from: encoded).generatedOutline)
        let prepared = try BookOutlineRuntime.prepare(in: project)
        XCTAssertGreaterThan(prepared.batches.count, 2)
        XCTAssertEqual(prepared.batches.first?.startUnit, 0)
        XCTAssertEqual(prepared.batches.last?.endUnit, 70)
        for range in prepared.batches {
            let batch = try prepared.request(for: range)
            XCTAssertLessThanOrEqual(batch.endUnit - batch.startUnit, 32)
            XCTAssertLessThanOrEqual(batch.candidates.count, 120)
            for entry in batch.candidates {
                let resolved = try ReadingExperienceRuntime.resolve(XCTUnwrap(entry.anchor), in: project)
                XCTAssertEqual(resolved.page, entry.page)
                XCTAssertTrue((batch.startUnit..<batch.endUnit).contains(resolved.unit.order))
                XCTAssertEqual(entry.title, resolved.anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func testModelOnlySelectsProvidedIDsInSourceOrderAndCannotInventPages() async throws {
        let project = try book(), batch = try firstBatch(project)
        let first = try XCTUnwrap(batch.candidates.first)
        let good = try response(["entries": [["id": first.id, "level": 0]]])
        let entries = try await BookOutlineEngine.generate(request: batch, settings: .init()) { messages, _, _ in
            XCTAssertEqual(messages.count, 2)
            let payload = try XCTUnwrap((messages.last?["content"] as? String)?.data(using: .utf8))
            let candidates = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [[String: Any]])
            XCTAssertEqual(candidates.first { $0["id"] as? String == first.id }?["text"] as? String, first.title)
            return good
        }
        XCTAssertEqual(entries, [first])
        let badRows: [Any] = [
            ["entries": [["id": "invented", "level": 0]]],
            ["entries": [["id": first.id, "level": true]]],
            ["entries": [["id": first.id, "level": 0, "page": 99]]],
            ["entries": [["id": first.id, "level": 0], ["id": first.id, "level": 0]]],
            ["entries": [["id": first.id, "level": 0]], "complete": true]
        ]
        for row in badRows {
            let bad = try response(row)
            do { _ = try await BookOutlineEngine.generate(request: batch, settings: .init()) { _, _, _ in bad }; XCTFail("无效模型目录不能被应用") }
            catch { XCTAssertTrue(error.localizedDescription.contains("目录")) }
        }
    }

    func testMultilineChapterHeadingIsOneLiteralCandidateAndCannotAlsoSelectItsLines() async throws {
        var project = try book(count: 1)
        let heading = "第三十八回\n定三分隆中决策\n战长江孙氏报仇"
        project.units[0].text = heading + "\n却说玄德两次拜访孔明未遇，打算再次前往。"
        let batch = try firstBatch(project)
        let combined = try XCTUnwrap(batch.candidates.first { $0.title == heading })
        let marker = try XCTUnwrap(batch.candidates.first { $0.title == "第三十八回" })
        let upper = try XCTUnwrap(batch.candidates.first { $0.title == "定三分隆中决策" })
        let resolved = try ReadingExperienceRuntime.resolve(XCTUnwrap(combined.anchor), in: project)
        XCTAssertEqual(resolved.anchor.quote, heading)
        let good = try response(["entries": [["id": combined.id, "level": 0]]])
        let result = try await BookOutlineEngine.generate(request: batch, settings: .init()) { messages, _, _ in
            XCTAssertTrue(String(describing: messages).contains("不得把标题续行单列成子节"))
            return good
        }
        XCTAssertEqual(result, [combined])
        for contained in [marker, upper] {
            let overlapping = try response(["entries": [["id": combined.id, "level": 0], ["id": contained.id, "level": 1]]])
            do { _ = try await BookOutlineEngine.generate(request: batch, settings: .init()) { _, _, _ in overlapping }; XCTFail("组合回目不能与其中单行重复成章") }
            catch { XCTAssertTrue(error.localizedDescription.contains("目录")) }
        }
        project.generatedOutline = GeneratedBookOutline(sourceHash: project.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: project),
            scannedUnitCount: 1, totalUnitCount: 1, entries: result)
        project.smartReading = try SmartReadingRuntime.freeze(.init(execution: .init(granularity: .chapter, steps: [])), in: project, currentUnitID: project.units[0].id)
        XCTAssertEqual(try SmartReadingRuntime.analysisChunks(in: project).count, 1, "回号和上下联共同属于一章，不拆出空的章末任务。")
    }

    func testOldSingleLinePartialDirectoryResumesAtItsVerifiedFrontierWithNewCandidates() throws {
        var project = try book(count: 50)
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: project.units[0].id, quote: "第1章", in: project)
        let old = BookOutlineEntry(id: anchor.id, title: "第1章", page: 1, anchor: anchor)
        // The old strategy offered four rows/unit: 120 candidates ended at 30.
        // Combined titles now end an earlier batch, but this known old frontier
        // is still source-proved and must not strand its existing partial work.
        project.generatedOutline = GeneratedBookOutline(sourceHash: project.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: project),
            scannedUnitCount: 30, totalUnitCount: 50, entries: [old])
        let prepared = try BookOutlineRuntime.prepare(in: project)
        XCTAssertEqual(prepared.cached?.entries, [old])
        XCTAssertEqual(prepared.cached?.scannedUnitCount, 30)
        let next = try XCTUnwrap(prepared.remainingBatches.first)
        XCTAssertEqual(next.startUnit, 30)
        XCTAssertEqual(try prepared.request(for: next).startUnit, 30)
        var forged = project; forged.generatedOutline?.scannedUnitCount = 29
        XCTAssertNil(try BookOutlineRuntime.prepare(in: forged).cached, "不能把任意计数伪装成旧批次前沿。")
    }

    func testFingerprintIncludesExtractionBytesAndPartialCacheResumesExactFrontier() throws {
        var project = try book(count: 40)
        let prepared = try BookOutlineRuntime.prepare(in: project), first = try firstBatch(project)
        let entry = try XCTUnwrap(first.candidates.first)
        project.generatedOutline = GeneratedBookOutline(sourceHash: project.sourceHash, sourceFingerprint: prepared.sourceFingerprint,
            scannedUnitCount: first.endUnit, totalUnitCount: project.units.count, entries: [entry])
        XCTAssertEqual(try BookOutlineRuntime.prepare(in: project).remainingBatches.first?.startUnit, first.endUnit)
        var badFrontier = project; badFrontier.generatedOutline?.scannedUnitCount = 1
        XCTAssertNil(try BookOutlineRuntime.prepare(in: badFrontier).cached)
        var changed = project; changed.units[0].text += "识别内容已更新。"
        XCTAssertNil(try BookOutlineRuntime.prepare(in: changed).cached)
        var wrongPage = project; wrongPage.generatedOutline?.entries[0].page = 20
        XCTAssertThrowsError(try BookOutlineRuntime.prepare(in: wrongPage))
        var wrongTitle = project; wrongTitle.generatedOutline?.entries[0].title = "并非原书的标题"
        XCTAssertThrowsError(try BookOutlineRuntime.prepare(in: wrongTitle))
        var composed = try book(); composed.units[0].text = "第1章\né。"
        var decomposed = composed; decomposed.units[0].text = "第1章\ne\u{301}。"
        XCTAssertEqual(composed.units, decomposed.units, "Swift 规范等价不能代表原文字节没变")
        XCTAssertNotEqual(try BookOutlineRuntime.fingerprint(in: composed), try BookOutlineRuntime.fingerprint(in: decomposed))
    }

    func testCanonicalBatchSavePreservesNotesAnalysisOriginalAndRejectsStaleReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Outline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("book.pdf"), original = Data("original-pdf-placeholder".utf8)
        try original.write(to: source)
        let project = try book(), repository = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        try await repository.create(project, sourceURL: source)
        let batch = try firstBatch(project), entry = try XCTUnwrap(batch.candidates.first)
        let note = DocumentRecord(id: "own-note", title: "自己的理解")
        var concurrent = try await repository.saveDocument(project: project, document: note, markdown: "我的正文不能被目录改写。")
        concurrent.chats = [ChatMessage(id: "qa", role: "user", content: "保留问答")]
        _ = try await repository.save(concurrent)
        let saved = try await repository.saveBookOutline(batch: batch, entries: [entry])
        XCTAssertEqual(saved.chats.map(\.content), ["保留问答"])
        XCTAssertEqual(saved.units, project.units)
        XCTAssertEqual(saved.generatedOutline?.entries, [entry])
        XCTAssertTrue(saved.generatedOutline?.complete == true)
        var stale = concurrent; stale.audit = [ToolAudit(name: "local", summary: "其他保存不能抹掉目录")]
        let retained = try await repository.save(stale)
        XCTAssertEqual(retained.generatedOutline, saved.generatedOutline)
        var altered = entry; altered.title = "模型编造的标题"
        do { _ = try await repository.saveBookOutline(batch: batch, entries: [altered]); XCTFail("不得改写候选") } catch {}
        do { _ = try await repository.saveBookOutline(batch: batch, entries: [entry]); XCTFail("旧批不能重复覆盖新进度") } catch {}
        XCTAssertEqual(try Data(contentsOf: source), original)
        let noteText = try await repository.readDocument(bookID: project.id, document: note)
        XCTAssertEqual(noteText, "我的正文不能被目录改写。")
        let reloaded = try await repository.loadAll()
        XCTAssertEqual(reloaded.first?.generatedOutline, saved.generatedOutline)
        let exported = directory.appendingPathComponent("export.readingbook", isDirectory: true)
        try await repository.exportProject(retained, to: exported)
        let data = try Data(contentsOf: exported.appendingPathComponent("project.json"))
        XCTAssertEqual(try JSONDecoder().decode(BookProject.self, from: data).generatedOutline, saved.generatedOutline)
    }

    func testAIIncrementalMergeCannotForgeHostDirectoryOrEraseLatestOne() throws {
        let base = try book(), batch = try firstBatch(base)
        let entry = try XCTUnwrap(batch.candidates.first)
        var latest = base
        latest.generatedOutline = GeneratedBookOutline(sourceHash: base.sourceHash, sourceFingerprint: batch.sourceFingerprint,
            scannedUnitCount: batch.endUnit, totalUnitCount: base.units.count, entries: [entry])
        let merged = try AIProjectMerge.merge(base: base, result: base, latest: latest)
        XCTAssertEqual(merged.generatedOutline, latest.generatedOutline)
        var forged = base; forged.generatedOutline = latest.generatedOutline
        XCTAssertThrowsError(try AIProjectMerge.merge(base: base, result: forged, latest: base))
        XCTAssertEqual(try ControlledChangeRecords.revision(base), try ControlledChangeRecords.revision(latest), "导航缓存不能扩大内容变更授权或使用户提案失效")
    }

    func testNativePluginCannotForgeTheHostDirectory() throws {
        var project = try book(), registry = PluginToolRegistry()
        let batch = try firstBatch(project), entry = try XCTUnwrap(batch.candidates.first)
        let forged = GeneratedBookOutline(sourceHash: project.sourceHash, sourceFingerprint: batch.sourceFingerprint,
            scannedUnitCount: batch.endUnit, totalUnitCount: project.units.count, entries: [entry])
        let tool = try RegisteredReadingTool(pluginID: "fixture", schema: ["type": "function", "function": [
            "name": "forge_outline", "parameters": ["type": "object", "properties": [:]]]], phases: [.planning]) { _, candidate, _ in
                candidate.generatedOutline = forged; return "ok"
            }
        try registry.register(tool)
        XCTAssertThrowsError(try registry.apply(name: "forge_outline", arguments: Data("{}".utf8), to: &project, allowedUnitIDs: [], phase: .planning))
        XCTAssertNil(project.generatedOutline)
    }

    func testNativePluginCannotChangeCanonicalEquivalentDirectoryBytes() throws {
        var project = try book(); project.units[0].text = "第1章\né"
        let batch = try firstBatch(project), entry = try XCTUnwrap(batch.candidates.first(where: { $0.title == "é" }))
        project.generatedOutline = GeneratedBookOutline(sourceHash: project.sourceHash, sourceFingerprint: batch.sourceFingerprint,
            scannedUnitCount: batch.endUnit, totalUnitCount: project.units.count, entries: [entry])
        let before = project.generatedOutline
        var registry = PluginToolRegistry()
        let tool = try RegisteredReadingTool(pluginID: "fixture", schema: ["type": "function", "function": [
            "name": "normalize_outline", "parameters": ["type": "object", "properties": [:]]]], phases: [.planning]) { _, candidate, _ in
                candidate.generatedOutline?.entries[0].title = "e\u{301}"; return "ok"
            }
        try registry.register(tool)
        XCTAssertThrowsError(try registry.apply(name: "normalize_outline", arguments: Data("{}".utf8), to: &project, allowedUnitIDs: [], phase: .planning))
        XCTAssertEqual(project.generatedOutline, before)
        let unchanged = try XCTUnwrap(project.generatedOutline?.entries.first)
        XCTAssertTrue(unchanged.title.utf8.elementsEqual("é".utf8))
    }

    #if os(macOS)
    func testNativePDFOutlineKeepsHierarchyGoToTargetsAndOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-NativeOutline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("outline.pdf"), output = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }; context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: output as Data)), root = PDFOutline()
        let chapter = PDFOutline(); chapter.label = "第一卷"
        chapter.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 0)), at: CGPoint(x: 40, y: 700))
        let child = PDFOutline(); child.label = "第一章 原书标题"
        child.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(document.page(at: 1)), at: CGPoint(x: 30, y: 600)))
        chapter.insertChild(child, at: 0); root.insertChild(chapter, at: 0)
        let external = PDFOutline(); external.label = "外部资料"; external.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com")))
        root.insertChild(external, at: 1); document.outlineRoot = root
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
        let original = try Data(contentsOf: url), hash = try BookImporter.sha256(original)
        let entries = try BookOutlineRuntime.originalPDFOutline(at: url, expectedSourceHash: hash, password: nil)
        XCTAssertEqual(entries.map(\.title), ["第一卷", "第一章 原书标题", "外部资料"])
        XCTAssertEqual(entries.map(\.level), [0, 1, 0])
        XCTAssertEqual(entries.map(\.page), [1, 2, nil])
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try BookOutlineRuntime.originalPDFOutline(at: url, expectedSourceHash: String(repeating: "0", count: 64), password: nil))
    }
    #endif
}
