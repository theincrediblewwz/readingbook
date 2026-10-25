import Foundation
import XCTest
@testable import ReadingCore

private actor PublicationScript {
    private var responses: [ProviderClient.Result]
    private(set) var count = 0
    init(_ responses: [ProviderClient.Result]) { self.responses = responses }
    func next() async throws -> ProviderClient.Result {
        count += 1
        if !responses.isEmpty { return responses.removeFirst() }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        throw CancellationError()
    }
}

private actor PublicationRecords {
    private(set) var flags: [Bool] = []
    func record(_ complete: Bool) { flags.append(complete) }
}

final class AIReadingPublicationTests: XCTestCase {
    private struct Fixture: Sendable {
        var directory: URL
        var repository: LibraryRepository
        var book: BookProject
        var chunk: ReadingAnalysisChunk
        var document: DocumentRecord
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("book.txt"), text = "贾诩来到城中。"
        try Data(text.utf8).write(to: source)
        var book = BookProject(title: "及时保存", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "第一章", page: 1, text: text)])
        PluginEngine.seed(&book)
        book.plan = ReadingPlan(methodIDs: ["genre.history"])
        let configuration = ReadingExecutionConfiguration(granularity: .page,
            steps: [ReadingExecutionStep(id: "facts", title: "整理人物", actionID: "facts.extract")])
        book.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: configuration), in: book, currentUnitID: "u1")
        book.smartReading?.isPlanConfirmed = true; book.smartReading?.status = .running
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library", isDirectory: true))
        try await repository.create(book, sourceURL: source)
        let document = DocumentRecord(id: "note", title: "我的理解")
        book = try await repository.saveDocument(project: book, document: document, markdown: "# 用户笔记\n\n不可覆盖 $x^2$。\n")
        return Fixture(directory: directory, repository: repository, book: book,
            chunk: try XCTUnwrap(SmartReadingRuntime.analysisChunks(in: book).first), document: document)
    }
    private func call(_ name: String, _ arguments: [String: Any], id: String = UUID().uuidString) throws -> ProviderClient.ToolCall {
        ProviderClient.ToolCall(id: id, type: "function", function: .init(name: name,
            arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)))
    }
    private func response(_ calls: [ProviderClient.ToolCall]) -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: calls, reasoning_content: nil), finishReason: "tool_calls", tokenCost: 10)
    }
    private func cards() throws -> ProviderClient.ToolCall {
        try call("cards_upsert", ["entities": [["id": "jia", "typeID": "person", "name": "贾诩", "summary": "本段里来到城中的人物。",
            "evidence": [["unitID": "u1", "quote": "贾诩来到城中。"]]]]])
    }
    private func completion(_ chunk: ReadingAnalysisChunk) throws -> ProviderClient.ToolCall {
        try call("reading_analysis", ["unitIDs": chunk.unitIDs, "completedStepIDs": chunk.stepIDs,
            "markdown": "贾诩来到城中，故事从这里展开。", "evidence": [["unitID": "u1", "quote": "贾诩来到城中。"]]])
    }
    private var settings: ProviderSettings { ProviderSettings(model: "offline-fixture", maxRequestsPerRun: 6, maxOutputTokens: 256) }

    func testPauseKeepsPublishedProductsWithoutPretendingChunkComplete() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let script = PublicationScript([response([try cards()])]), records = PublicationRecords()
        let reader = AIReader(transport: { _ in try await script.next() })
        let saved = expectation(description: "人物已在下一次模型请求前持久保存")
        let sessionID = try XCTUnwrap(f.book.smartReading?.id)
        await reader.setPublicationHandler { publication in
            _ = try await f.repository.commitAIResult(base: publication.before, result: publication.after,
                operationID: publication.operationID, expectedReadingSessionID: sessionID)
            await records.record(publication.isAnalysisComplete); saved.fulfill()
        }
        let requestSettings = settings
        let task = Task { try await reader.readChunk(project: f.book, chunk: f.chunk, settings: requestSettings, apiKey: "") }
        await fulfillment(of: [saved], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("暂停不能继续完成该块") } catch { XCTAssertTrue(error is CancellationError) }
        let books = try await f.repository.loadAll(), latest = try XCTUnwrap(books.first)
        XCTAssertEqual(latest.entities.map(\.id), ["jia"])
        XCTAssertFalse(SmartReadingRuntime.isChunkComplete(f.chunk, in: latest))
        XCTAssertTrue(latest.insights.isEmpty)
        let flags = await records.flags; XCTAssertEqual(flags, [false])
        let body = try await f.repository.readDocument(bookID: latest.id, document: f.document)
        XCTAssertEqual(body, "# 用户笔记\n\n不可覆盖 $x^2$。\n")
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("book.txt"), encoding: .utf8), "贾诩来到城中。")
    }

    func testTerminalMustBeLastAndPartialProductsStillSurviveTheBadBatch() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let invalidBatch = response([try cards(), try completion(f.chunk), try call("knowledge_search", ["query": "贾诩"])])
        let stop = ProviderClient.Result(message: .init(role: "assistant", content: "完成", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 10)
        let script = PublicationScript([invalidBatch, stop]), records = PublicationRecords()
        let reader = AIReader(transport: { _ in try await script.next() })
        await reader.setPublicationHandler { publication in
            _ = try await f.repository.commitAIResult(base: publication.before, result: publication.after, operationID: publication.operationID)
            await records.record(publication.isAnalysisComplete)
        }
        do { _ = try await reader.readChunk(project: f.book, chunk: f.chunk, settings: settings, apiKey: ""); XCTFail("完成工具后还有调用不能计为完成") } catch {}
        let books = try await f.repository.loadAll(), latest = try XCTUnwrap(books.first)
        XCTAssertEqual(latest.entities.map(\.id), ["jia"])
        XCTAssertFalse(SmartReadingRuntime.isChunkComplete(f.chunk, in: latest))
        let flags = await records.flags; XCTAssertEqual(flags, [false])
    }

    func testCompleteBatchIsOnePublicationAndConcurrentChatRemains() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var question = f.book; question.chats.append(ChatMessage(id: "question", role: "user", content: "这个人是谁？"))
        _ = try await f.repository.commitAIResult(base: f.book, result: question, operationID: "question-before-products")
        let script = PublicationScript([response([try cards(), try completion(f.chunk)])]), records = PublicationRecords()
        let reader = AIReader(transport: { _ in try await script.next() })
        await reader.setPublicationHandler { publication in
            _ = try await f.repository.commitAIResult(base: publication.before, result: publication.after, operationID: publication.operationID)
            await records.record(publication.isAnalysisComplete)
        }
        _ = try await reader.readChunk(project: f.book, chunk: f.chunk, settings: settings, apiKey: "")
        let books = try await f.repository.loadAll(), latest = try XCTUnwrap(books.first)
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(f.chunk, in: latest))
        XCTAssertEqual(latest.chats.map(\.id), ["question"])
        let flags = await records.flags; XCTAssertEqual(flags, [true])
        let count = await script.count; XCTAssertEqual(count, 1)
    }

    func testPersistenceFailureDoesNotAskTheModelToRepeatSavedWork() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let script = PublicationScript([response([try cards()])])
        let reader = AIReader(transport: { _ in try await script.next() })
        await reader.setPublicationHandler { _ in throw ReadingError.invalid("模拟磁盘不可写") }
        do { _ = try await reader.readChunk(project: f.book, chunk: f.chunk, settings: settings, apiKey: ""); XCTFail("保存失败须停止") }
        catch { XCTAssertTrue(error.localizedDescription.contains("磁盘不可写")) }
        let count = await script.count; XCTAssertEqual(count, 1, "存储失败不能变成模型参数重试")
        let books = try await f.repository.loadAll(), latest = try XCTUnwrap(books.first)
        XCTAssertTrue(latest.entities.isEmpty); XCTAssertFalse(SmartReadingRuntime.isChunkComplete(f.chunk, in: latest))
    }

    func testCorrectedTerminalCanRepairItsOwnEarlierArgumentError() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let malformed = try call("reading_analysis", ["unitIDs": ["different-unit"]])
        let script = PublicationScript([response([malformed]), response([try cards(), try completion(f.chunk)])])
        let reader = AIReader(transport: { _ in try await script.next() }), records = PublicationRecords()
        await reader.setPublicationHandler { publication in
            _ = try await f.repository.commitAIResult(base: publication.before, result: publication.after, operationID: publication.operationID)
            await records.record(publication.isAnalysisComplete)
        }
        _ = try await reader.readChunk(project: f.book, chunk: f.chunk, settings: settings, apiKey: "")
        let books = try await f.repository.loadAll(), latest = try XCTUnwrap(books.first)
        XCTAssertTrue(SmartReadingRuntime.isChunkComplete(f.chunk, in: latest))
        let flags = await records.flags; XCTAssertEqual(flags, [true])
        let count = await script.count; XCTAssertEqual(count, 2)
    }

    func testLegacyReceiptBatchStillReturnsToItsOriginalCallerWithoutIncrementalPublication() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var legacy = f.book; legacy.smartReading = nil
        let unit = try XCTUnwrap(legacy.units.first), paragraphs = try ReadingLedger.paragraphs(for: unit, in: legacy)
        let batch = try ReadingLedger.makeBatch(unit: unit, paragraphs: paragraphs)
        let receipt = try call("read_receipt", ["batchID": batch.id, "receipts": paragraphs.map { paragraph in
            ["paragraphID": paragraph.id, "textHash": paragraph.textHash, "summary": "本段写贾诩来到城中。",
             "startQuote": paragraph.startQuote, "endQuote": paragraph.endQuote, "issues": []] as [String: Any]
        }])
        let script = PublicationScript([response([receipt])]), records = PublicationRecords()
        let reader = AIReader(transport: { _ in try await script.next() })
        await reader.setPublicationHandler { publication in await records.record(publication.isAnalysisComplete) }
        let result = try await reader.readNext(project: legacy, settings: ProviderSettings(model: "offline-fixture", maxOutputTokens: 1200), apiKey: "")
        XCTAssertEqual(result.paragraphReceipts?.count, paragraphs.count)
        XCTAssertEqual(result.receiptBatch?.id, batch.id)
        XCTAssertEqual(result.units, legacy.units); XCTAssertEqual(result.documents, legacy.documents)
        XCTAssertNil(result.smartReading); XCTAssertTrue(result.insights.isEmpty)
        XCTAssertEqual(result.coverage[unit.id]?.status, legacy.coverage[unit.id]?.status)
        let flags = await records.flags; XCTAssertTrue(flags.isEmpty, "旧回执批次仍由原调用方完整提交，不能流式写入临时宿主状态")
        let books = try await f.repository.loadAll(), stored = try XCTUnwrap(books.first)
        XCTAssertNil(stored.paragraphReceipts)
    }
}
