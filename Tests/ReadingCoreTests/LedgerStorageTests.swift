import Foundation
import XCTest
@testable import ReadingCore

final class LedgerStorageTests: XCTestCase {
    private func fixture() throws -> (URL, URL, BookProject) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-LedgerStorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("原书.txt")
        let text = "第一段：设 α > 0。\n\n第二段：因此结论成立。\n"
        try Data(text.utf8).write(to: source)
        let project = BookProject(title: "账本存储", originalName: source.lastPathComponent,
                                  sourceHash: try BookImporter.sha256(Data(text.utf8)),
                                  units: [SourceUnit(id: "unit-1", order: 0, chapter: "原书", lineStart: 1, lineEnd: 4, text: text)])
        return (directory, source, project)
    }

    private func withLedger(_ original: BookProject) throws -> BookProject {
        var project = original
        project.methods = [ReadingMethod(id: "original-method", name: "复述", goal: "核对条件", steps: ["复述本段条件"]),
                           ReadingMethod(id: "new-method", name: "比较", goal: "比较论证", steps: ["比较前后论证"])]
        project.plan = ReadingPlan(methodIDs: ["original-method"])
        let unit = project.units[0], paragraphs = try ReadingLedger.paragraphs(for: unit, in: project)
        project.paragraphReceipts = paragraphs.map {
            ParagraphReceipt(paragraphID: $0.id, unitID: $0.unitID, unitHash: $0.unitHash, textHash: $0.textHash,
                             utf8Start: $0.utf8Start, utf8End: $0.utf8End, summary: "本段说明条件与结论。",
                             startQuote: $0.startQuote, endQuote: $0.endQuote, issues: [], createdAt: Date())
        }
        project.readingStepResults = try ReadingLedger.stepRequirements(for: unit, in: project).map {
            ReadingStepResult(stepID: $0.stepID, unitID: $0.unitID, methodID: $0.methodID,
                              methodHash: $0.methodHash, stepIndex: $0.stepIndex, result: "原文限定 α 为正数。",
                              paragraphIDs: paragraphs.map(\.id), createdAt: Date())
        }
        return project
    }

    func testOldProjectsAndHistoricalMethodLedgerRoundTrip() async throws {
        let (directory, source, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        try await repository.create(original, sourceURL: source)
        let old = try await repository.loadAll()
        XCTAssertNil(old[0].paragraphReceipts)
        XCTAssertNil(old[0].readingStepResults)

        var checkpoint = try withLedger(original)
        checkpoint.plan = ReadingPlan(methodIDs: ["new-method"])
        checkpoint.receiptBatch = try ReadingLedger.makeBatch(unit: checkpoint.units[0], paragraphs: ReadingLedger.paragraphs(for: checkpoint.units[0], in: checkpoint))
        try await repository.save(checkpoint)
        let package = directory.appendingPathComponent("账本备份.readingbook", isDirectory: true)
        try await repository.exportProject(checkpoint, to: package)
        let imported = try await repository.importProject(from: package)
        XCTAssertEqual(imported.paragraphReceipts, checkpoint.paragraphReceipts)
        XCTAssertEqual(imported.readingStepResults, checkpoint.readingStepResults)
        XCTAssertEqual(imported.receiptBatch, checkpoint.receiptBatch)
        XCTAssertEqual(imported.plan?.methodIDs, ["new-method"])
        let loaded = try await repository.loadAll()
        XCTAssertEqual(loaded.count, 2)
    }

    func testSaveRejectsBrokenLedgerWithoutReplacingStoredMetadata() async throws {
        let (directory, source, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        let valid = try withLedger(original)
        try await repository.create(valid, sourceURL: source)
        let metadata = directory.appendingPathComponent("library/books/\(valid.id)/project.json")
        let before = try Data(contentsOf: metadata)
        let corruptions: [(String, (inout BookProject) -> Void)] = [
            ("回执来源不存在", { $0.paragraphReceipts![0].unitID = "unknown-unit" }),
            ("回执重复", { project in let first = project.paragraphReceipts![0]; project.paragraphReceipts!.append(first) }),
            ("原文哈希不符", { $0.paragraphReceipts![0].unitHash = "changed" }),
            ("片段哈希不符", { $0.paragraphReceipts![0].textHash = "changed" }),
            ("片段范围不符", { $0.paragraphReceipts![0].utf8End += 1 }),
            ("锚点不符", { $0.paragraphReceipts![0].endQuote = "原文中没有" }),
            ("步骤重复", { project in let first = project.readingStepResults![0]; project.readingStepResults!.append(first) }),
            ("步骤来源不存在", { $0.readingStepResults![0].unitID = "unknown-unit" }),
            ("步骤引用悬空", { $0.readingStepResults![0].paragraphIDs = ["unknown-paragraph"] }),
            ("步骤结果为空", { $0.readingStepResults![0].result = " \n " }),
            ("步骤结果过长", { $0.readingStepResults![0].result = String(repeating: "字", count: 2001) }),
            ("方法不存在", { $0.readingStepResults![0].methodID = "unknown-method" }),
            ("方法版本不符", { $0.methods[0].steps[0] += "新增条件" }),
            ("方法哈希不符", { $0.readingStepResults![0].methodHash = "changed" }),
            ("步骤序号不符", { $0.readingStepResults![0].stepIndex += 1 })
        ]
        for (label, corrupt) in corruptions {
            var damaged = valid; corrupt(&damaged)
            do { try await repository.save(damaged); XCTFail("应拒绝：\(label)") } catch { }
        }
        var batch = valid
        batch.receiptBatch = try ReadingLedger.makeBatch(unit: valid.units[0], paragraphs: ReadingLedger.paragraphs(for: valid.units[0], in: valid))
        batch.receiptBatch!.paragraphIDs.append("unknown-paragraph")
        do { try await repository.save(batch); XCTFail("应拒绝批次悬空片段") } catch { }
        batch.receiptBatch!.paragraphIDs.removeLast()
        batch.receiptBatch!.unitHash = "changed"
        do { try await repository.save(batch); XCTFail("应拒绝批次原文变化") } catch { }
        XCTAssertEqual(try Data(contentsOf: metadata), before)
    }

    func testLoadAndImportRejectTamperedLedgerAndPreserveFiles() async throws {
        let (directory, source, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        let valid = try withLedger(original)
        try await repository.create(valid, sourceURL: source)
        let package = directory.appendingPathComponent("损坏备份.readingbook", isDirectory: true)
        try await repository.exportProject(valid, to: package)
        var damaged = valid
        damaged.readingStepResults![0].paragraphIDs = ["unknown-paragraph"]
        let damagedData = try JSONEncoder().encode(damaged)
        let packageMetadata = package.appendingPathComponent("project.json")
        try damagedData.write(to: packageMetadata, options: .atomic)
        do { _ = try await repository.importProject(from: package); XCTFail("应拒绝导入断链步骤") } catch { }
        let loaded = try await repository.loadAll()
        XCTAssertEqual(loaded.count, 1, "失败导入不应创建新书籍")
        XCTAssertEqual(try Data(contentsOf: packageMetadata), damagedData)
        let storedMetadata = directory.appendingPathComponent("library/books/\(valid.id)/project.json")
        try damagedData.write(to: storedMetadata, options: .atomic)
        do { _ = try await repository.loadAll(); XCTFail("应拒绝载入断链账本") } catch { }
        XCTAssertEqual(try Data(contentsOf: storedMetadata), damagedData)
    }
}
