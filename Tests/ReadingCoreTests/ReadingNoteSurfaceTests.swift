import Foundation
import XCTest
import CoreGraphics
import ImageIO
@testable import ReadingCore

final class ReadingNoteSurfaceTests: XCTestCase {
    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private func image(_ green: CGFloat = 0.4, type: String = "public.png") throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: green, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        let output = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return output as Data
    }
    private func fixture() async throws -> (URL, LibraryRepository, BookProject) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/note-surface-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt"); try Data("原书不改 e\u{301} 👩🏽‍💻。".utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        let imported = try await BookImporter.importFile(at: source)
        let project = try await repository.create(imported, sourceURL: source)
        return (root, repository, project)
    }
    private func records() -> BookProject {
        var book = BookProject(id: "group-test", title: "分组", originalName: "book.pdf", sourceHash: String(repeating: "a", count: 64), units: [
            .init(id: "u1", order: 0, chapter: "抽取内容", page: 10, text: "原文一"),
            .init(id: "u2", order: 1, chapter: "抽取内容", page: 11, text: "原文二")])
        book.documents = (0..<150).map { index in
            var note = DocumentRecord(id: "n\(index)", title: "第\(index)篇")
            note.updatedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index % 3) * 86_400)
            return note
        }
        return book
    }
    func testOldProjectDecodesWithoutCoverAndDoesNotInventAsset() throws {
        let original = records(), data = try bytes(original)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("coverImage"))
        XCTAssertNil(try JSONDecoder().decode(BookProject.self, from: data).coverImage)
    }
    func testPNGAndJPEGInspectDecodedContentRatherThanFilename() throws {
        for (type, ext) in [("public.png", "png"), ("public.jpeg", "jpg")] {
            let data = try image(type: type), record = try BookCoverImage.inspect(data)
            XCTAssertEqual(record.fileExtension, ext); XCTAssertEqual(record.width, 64); XCTAssertEqual(record.height, 96)
            XCTAssertEqual(record.sha256, try BookImporter.sha256(data)); try record.validate()
        }
    }
    func testInvalidImageAndExactTwoMegabytesRejected() throws {
        for data in [Data(), Data("not-an-image.png".utf8), Data(repeating: 0, count: 2_000_000)] {
            XCTAssertThrowsError(try BookCoverImage.inspect(data))
        }
        let invalid = BookCoverImage(sha256: "../../source", fileExtension: "png", byteCount: 10, width: 1, height: 1)
        XCTAssertThrowsError(try invalid.validate())
    }
    func testThumbnailIsDecodedBoundedAndOriginalBytesRemain() throws {
        let original = try image(), hash = try BookImporter.sha256(original), preview = try BookCoverImage.preview(original, maximumPixelSize: 64)
        let record = try BookCoverImage.inspect(preview)
        XCTAssertLessThanOrEqual(max(record.width, record.height), 64)
        XCTAssertEqual(try BookImporter.sha256(original), hash)
        XCTAssertThrowsError(try BookCoverImage.preview(original, maximumPixelSize: 20_000))
    }
    func testReplaceAndRemoveCoverDoNotAccumulateFilesOrChangeOriginal() async throws {
        let (root, repository, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = await repository.sourceURL(for: project), original = try Data(contentsOf: source)
        let first = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: image())
        let second = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: image(0.8))
        XCTAssertNotEqual(first.coverImage, second.coverImage)
        let directory = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("cover")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        let cleared = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: nil)
        XCTAssertNil(cleared.coverImage); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testWrongSourceAndInvalidImageLeaveDeclaredCoverUntouched() async throws {
        let (root, repository, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let png = try image(), saved = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: png)
        for (hash, data) in [("wrong-source", png), (project.sourceHash, Data("broken".utf8))] {
            do { _ = try await repository.setBookCover(bookID: project.id, expectedSourceHash: hash, data: data); XCTFail("Must reject invalid replacement") } catch { }
        }
        let retained = try await repository.bookCoverData(for: saved); XCTAssertEqual(retained, png)
    }
    func testStaleEditorAndAIResultCannotEraseUserCover() async throws {
        let (root, repository, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let note = DocumentRecord(id: "note", title: "原笔记"), body = "用户正文 $x^2$ e\u{301}"
        let stale = try await repository.saveDocument(project: initial, document: note, markdown: body)
        let saved = try await repository.setBookCover(bookID: initial.id, expectedSourceHash: initial.sourceHash, data: image())
        let edited = try await repository.saveDocument(project: stale, document: note, markdown: body, expectedContentHash: BookImporter.sha256(Data(body.utf8)))
        XCTAssertEqual(edited.coverImage, saved.coverImage)
        var result = stale; result.chats.append(.init(id: "late", role: "assistant", content: "迟到回答"))
        let merged = try await repository.commitAIResult(base: stale, result: result, operationID: "cover-stale-ai")
        XCTAssertEqual(merged.coverImage, saved.coverImage); XCTAssertEqual(merged.chats.last?.content, "迟到回答")
        let retainedBody = try await repository.readDocument(bookID: initial.id, document: note); XCTAssertEqual(retainedBody, body)
        try await repository.save(stale)
        let reopened = try await repository.loadAll(); XCTAssertEqual(reopened.first?.coverImage, saved.coverImage)
    }
    func testProjectExportImportPreservesCoverSourceNoteAndPlacement() async throws {
        let (root, repository, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let body = "# 用户便签\n\n原句 e\u{301} 👩🏽‍💻。", note = DocumentRecord(id: "note", title: "便签")
        let placed = try await repository.saveDocument(project: initial, document: note, markdown: body,
            notePlacement: .init(sourceHash: initial.sourceHash, unitID: initial.units[0].id, page: initial.units[0].page, x: 0.5, y: 0.5))
        let png = try image(), saved = try await repository.setBookCover(bookID: initial.id, expectedSourceHash: initial.sourceHash, data: png)
        let package = root.appendingPathComponent("export.readingbook")
        try await repository.exportProject(saved, to: package)
        let other = LibraryRepository(rootURL: root.appendingPathComponent("other")), imported = try await other.importProject(from: package)
        let data = try await other.bookCoverData(for: imported), markdown = try await other.readDocument(bookID: imported.id, document: imported.documents[0])
        XCTAssertEqual(data, png); XCTAssertEqual(markdown, body); XCTAssertEqual(imported.sourceHash, initial.sourceHash)
        XCTAssertEqual(imported.readerCollections?.notePlacements?["note"], placed.readerCollections?.notePlacements?["note"])
    }
    func testWholeLibraryBackupRestoresCustomCoverToNewDirectory() async throws {
        let (root, repository, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let png = try image(); _ = try await repository.setBookCover(bookID: initial.id, expectedSourceHash: initial.sourceHash, data: png)
        let backup = root.appendingPathComponent("all.readingbookbackup"), destination = root.appendingPathComponent("restored")
        _ = try await repository.exportLibraryBackup(to: backup)
        _ = try await repository.restoreLibraryBackup(from: backup, to: destination)
        let other = LibraryRepository(rootURL: destination), projects = try await other.loadAll()
        let loaded = try XCTUnwrap(projects.first), restored = try await other.bookCoverData(for: loaded)
        XCTAssertEqual(restored, png); XCTAssertEqual(loaded.sourceHash, initial.sourceHash)
    }
    func testTamperedExportCoverCannotBeImported() async throws {
        let (root, repository, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await repository.setBookCover(bookID: initial.id, expectedSourceHash: initial.sourceHash, data: image())
        let package = root.appendingPathComponent("tampered.readingbook"); try await repository.exportProject(saved, to: package)
        try image(0.9).write(to: package.appendingPathComponent(try XCTUnwrap(saved.coverImage).relativePath))
        let other = LibraryRepository(rootURL: root.appendingPathComponent("other"))
        do { _ = try await other.importProject(from: package); XCTFail("Tampered cover must fail validation") } catch { }
    }
    func testReadingProgressUsesHumanPositionRatherThanAIAnalysisCoverage() {
        let book = records()
        XCTAssertEqual(BookReadingProgress.fraction(in: book, unitID: "u1", page: nil), 0.5)
        XCTAssertEqual(BookReadingProgress.fraction(in: book, unitID: "u2", page: nil), 1)
        XCTAssertEqual(BookReadingProgress.fraction(in: book, unitID: nil, page: 11), 1)
        XCTAssertEqual(BookReadingProgress.fraction(in: book, unitID: "missing", page: nil), 0)
    }
    func testFanCardsRemainSeparateRotatedAndBoundedAtSupportedWindowSizes() {
        for width in [320.0, 440, 759, 760, 1120, 1800] {
            let cards = ReadingNoteFanLayout.cards(count: 240, width: width, height: 600)
            XCTAssertEqual(cards.count, ReadingNoteFanLayout.pageSize(width: width))
            for card in cards {
                let a = card.degrees * .pi / 180, dx = abs(cos(a)) * card.width / 2 + abs(sin(a)) * card.height / 2
                XCTAssertGreaterThanOrEqual(card.x - dx, 0); XCTAssertLessThanOrEqual(card.x + dx, width)
                XCTAssertGreaterThan(card.y - card.height / 2, 0); XCTAssertLessThan(card.y + card.height / 2, 600)
            }
        }
        XCTAssertTrue(ReadingNoteFanLayout.cards(count: 10, width: .nan, height: 600).isEmpty)
        XCTAssertTrue(ReadingNoteFanLayout.cards(count: 0, width: 1120, height: 600).isEmpty)
    }
    func testDateGroupingIncludesAll150NotesWithoutChangingSourceMetadata() throws {
        let book = records(), before = try bytes(book), catalog = try ReadingRecordCatalog.prepare(in: book)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let ids = book.documents.reversed().map { "note:" + $0.id }, groups = catalog.groups(ids: ids, by: .date, calendar: calendar)
        XCTAssertEqual(groups.count, 3); XCTAssertEqual(groups.flatMap(\.records).count, 150)
        XCTAssertEqual(Set(groups.flatMap(\.records).map(\.id)), Set(ids)); XCTAssertEqual(try bytes(book), before)
    }
    func testPDFWithoutTrustedChaptersGroupsByActualPageAndUnboundRecords() throws {
        var book = records(); book.documents = Array(book.documents.prefix(3))
        book.readerCollections = try ReaderCollectionRuntime.apply(.setNotePlacement("n0", .init(sourceHash: book.sourceHash, unitID: "u1", page: 10, x: 0.2, y: 0.5)), in: book)
        book.readerCollections = try ReaderCollectionRuntime.apply(.setNotePlacement("n1", .init(sourceHash: book.sourceHash, unitID: "u2", page: 11, x: 0.8, y: 0.5)), in: book)
        let groups = try ReadingRecordCatalog.prepare(in: book).groups(ids: ["note:n2", "note:n1", "note:n0"], by: .chapter)
        XCTAssertEqual(groups.map(\.title), ["第 10 页", "第 11 页", "未关联章节"])
    }
    func testUngroupedProjectionKeepsCallerOrderAndDoesNotChangeArchiveOrReferences() throws {
        var book = records(); book.readerCollections = .init()
        let before = try bytes(book), ids = ["note:n149", "note:n0", "note:n81"]
        let rows = try ReadingRecordCatalog.prepare(in: book).groups(ids: ids, by: .none)
        XCTAssertEqual(rows.flatMap(\.records).map(\.id), ids); XCTAssertEqual(try bytes(book), before)
    }
    func testDuplicateRecordIdentitiesAreRejectedRatherThanSilentlyCombined() throws {
        var book = records(); book.documents.append(book.documents[0])
        XCTAssertThrowsError(try ReadingRecordCatalog.prepare(in: book))
    }
}
