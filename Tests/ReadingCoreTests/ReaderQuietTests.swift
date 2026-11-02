import Foundation
import XCTest
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
@testable import ReadingCore

final class ReaderQuietTests: XCTestCase {
    func testThumbnailGridFillsEachWidthAndAddsColumnsWhenExpanded() throws {
        for density in PDFThumbnailDensity.allCases {
            var previous = 0
            for width in stride(from: CGFloat(220), through: 900, by: 20) {
                for aspect in [CGFloat(0.62), 0.75, 1.4] {
                    let grid = PDFThumbnailGridGeometry(width: width, pageAspectRatio: aspect, density: density)
                    XCTAssertGreaterThanOrEqual(grid.columns, previous)
                    XCTAssertLessThanOrEqual((grid.thumbnailSize.width + 20) * CGFloat(grid.columns), width)
                    XCTAssertLessThan(width - (grid.thumbnailSize.width + 20) * CGFloat(grid.columns), CGFloat(grid.columns))
                    XCTAssertEqual(grid.thumbnailSize.width / grid.thumbnailSize.height, aspect, accuracy: 0.0001)
                }
                previous = PDFThumbnailGridGeometry(width: width, pageAspectRatio: 0.75, density: density).columns
            }
        }
        XCTAssertEqual(PDFThumbnailGridGeometry(width: 400, pageAspectRatio: 0.75, density: .small).columns, 3)
        XCTAssertEqual(PDFThumbnailGridGeometry(width: 400, pageAspectRatio: 0.75, density: .medium).columns, 2)
        XCTAssertEqual(PDFThumbnailGridGeometry(width: 400, pageAspectRatio: 0.75, density: .large).columns, 1)
    }
    func testSearchSnippetLocatesRepeatedMatchesAndExtractedParagraphs() throws {
        let text = "首段 貂蟬\r\n第二段 貂蟬\r第三段 貂蟬\u{2029}第四段 貂蟬", native = text as NSString
        let index = NativePDFSearchTextIndex(text)
        var offset = 0
        for paragraph in 1...4 {
            let range = native.range(of: "貂蟬", range: NSRange(location: offset, length: native.length - offset))
            let snippet = index.snippet(range: range, expectedMatch: "貂蟬", context: 80)
            XCTAssertEqual(snippet.paragraph, paragraph); XCTAssertEqual(snippet.match, "貂蟬")
            XCTAssertFalse(snippet.text.contains("\n")); XCTAssertFalse(snippet.text.contains("\r"))
            offset = NSMaxRange(range)
        }
    }
    func testSearchSnippetKeepsUnicodeContextWholeAndBounded() throws {
        let prefix = String(repeating: "前", count: 100) + "👩🏽‍💻e\u{301}", match = "匹配", suffix = "🇨🇳👨‍👩‍👧‍👦" + String(repeating: "后", count: 100)
        let text = prefix + match + suffix, range = (text as NSString).range(of: match)
        // Five UTF-16 units reach into the family after the four-unit flag;
        // the context must then expand to include that entire grapheme.
        let snippet = NativePDFSearchTextIndex(text).snippet(range: range, expectedMatch: match, context: 5)
        XCTAssertTrue(snippet.before.hasPrefix("…")); XCTAssertTrue(snippet.after.hasSuffix("…"))
        XCTAssertTrue(snippet.before.contains("👩🏽‍💻")); XCTAssertTrue(snippet.before.contains("e\u{301}"))
        XCTAssertTrue(snippet.after.contains("🇨🇳")); XCTAssertTrue(snippet.after.contains("👨‍👩‍👧‍👦"))
        XCTAssertFalse(snippet.text.contains("�")); XCTAssertLessThan(snippet.text.utf16.count, 80)
        XCTAssertEqual(snippet.paragraph, 1)
    }
    func testSearchSnippetRejectsStaleOrInvalidOffsetsWithoutInventingLocation() throws {
        let index = NativePDFSearchTextIndex("first match\nsecond match")
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 2),
            NSRange(location: 0, length: 0), NSRange(location: Int.max - 1, length: 4), NSRange(location: 3, length: 99), NSRange(location: 0, length: 5)] {
            XCTAssertEqual(index.snippet(range: range, expectedMatch: "match"), .unlocated("match"))
        }
        XCTAssertEqual(index.snippet(range: NSRange(location: 6, length: 5), expectedMatch: "match", context: 81), .unlocated("match"))
    }
    func testSearchSnippetHandlesPDFKitRangeIncludingOnlyAdjacentLineWhitespace() throws {
        let text = "前文\n貂\r\n后文", native = text as NSString, hit = native.range(of: "貂")
        let index = NativePDFSearchTextIndex(text)
        let snippet = index.snippet(range: NSRange(location: hit.location, length: hit.length + 2), expectedMatch: "貂")
        XCTAssertEqual(snippet.match, "貂"); XCTAssertEqual(snippet.paragraph, 2)
        XCTAssertTrue(snippet.before.contains("前文")); XCTAssertTrue(snippet.after.contains("后文"))
        XCTAssertEqual(index.snippet(range: NSRange(location: hit.location, length: hit.length + 3), expectedMatch: "貂"), .unlocated("貂"))
    }
    private func fixture() async throws -> (URL, LibraryRepository, BookProject) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/reader-quiet-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt"); try Data("原书保持 e\u{301} 👩🏽‍💻。".utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        let project = try await repository.create(BookImporter.importFile(at: source), sourceURL: source)
        return (root, repository, project)
    }
    private func image(width: Int = 200, height: Int = 100, orientation: Int? = nil) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let output = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return output as Data
    }
    private func centerPixel(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0.5 - CGFloat(image.width) / 2, y: 0.5 - CGFloat(image.height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }
    func testCropPanClampsAndScalesWithPreview() throws {
        for image in [CGSize(width: 200, height: 100), CGSize(width: 100, height: 200), CGSize(width: 1, height: 4096)] {
            for zoom in [1.0, 1.7, 4, 20] { for pan in [-30.0, -1, 0, 1, 30] {
                let viewport = CGSize(width: 312, height: 400)
                let frame = try XCTUnwrap(BookCoverCropGeometry.frame(image: image, viewport: viewport, zoom: zoom, panX: pan, panY: -pan))
                XCTAssertLessThanOrEqual(frame.minX, 0.0001); XCTAssertLessThanOrEqual(frame.minY, 0.0001)
                XCTAssertGreaterThanOrEqual(frame.maxX, viewport.width - 0.0001); XCTAssertGreaterThanOrEqual(frame.maxY, viewport.height - 0.0001)
                let doubled = try XCTUnwrap(BookCoverCropGeometry.frame(image: image, viewport: CGSize(width: 624, height: 800), zoom: zoom, panX: pan, panY: -pan))
                XCTAssertEqual(doubled.minX, frame.minX * 2, accuracy: 0.0001); XCTAssertEqual(doubled.width, frame.width * 2, accuracy: 0.0001)
            } }
        }
        XCTAssertNil(BookCoverCropGeometry.frame(image: .zero, viewport: .init(width: 312, height: 400), zoom: 1, panX: 0, panY: 0))
        XCTAssertNil(BookCoverCropGeometry.frame(image: .init(width: 100, height: 200), viewport: .init(width: 312, height: 400), zoom: .nan, panX: 0, panY: 0))
    }
    func testCropExportUsesVisiblePanAndPreservesInputBytes() throws {
        let raw = try image(), before = try BookImporter.sha256(raw), decoded = try BookCoverCropImage(data: raw)
        let left = try decoded.jpeg(zoom: 1, panX: 1, panY: 0), right = try decoded.jpeg(zoom: 1, panX: -1, panY: 0)
        let l = try centerPixel(left), r = try centerPixel(right)
        XCTAssertGreaterThan(Int(l[0]) - Int(l[1]), 150); XCTAssertGreaterThan(Int(r[1]) - Int(r[0]), 150)
        for output in [left, right, try decoded.jpeg(zoom: 4, panX: 0.5, panY: -0.8)] {
            let metadata = try BookCoverImage.inspect(output)
            XCTAssertEqual(metadata.width, 1248); XCTAssertEqual(metadata.height, 1600)
            XCTAssertLessThan(output.count, 2_000_000)
        }
        XCTAssertEqual(try BookImporter.sha256(raw), before)
    }
    func testCropDecodesEXIFOrientationBeforePreviewAndExport() throws {
        let raw = try image(orientation: 6), decoded = try BookCoverCropImage(data: raw)
        XCTAssertEqual(decoded.image.width, 100); XCTAssertEqual(decoded.image.height, 200)
        let exported = try BookCoverImage.inspect(decoded.jpeg(zoom: 1, panX: 0, panY: 0))
        XCTAssertEqual(Double(exported.width) / Double(exported.height), BookCoverCropGeometry.aspectRatio)
        XCTAssertThrowsError(try BookCoverCropImage(data: Data("not an image".utf8)))
        XCTAssertThrowsError(try decoded.jpeg(zoom: .infinity, panX: 0, panY: 0))
    }
    func testRenamePreservesCanonicalNotesCoverAndStaleAISnapshots() async throws {
        let (root, repository, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let note = DocumentRecord(id: "note", title: "原笔记"), body = "用户笔记原样 e\u{301}。"
        let stale = try await repository.saveDocument(project: project, document: note, markdown: body)
        let cover = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: image())
        let renamed = try await repository.renameBook(bookID: project.id, expectedSourceHash: project.sourceHash, expectedTitle: project.title, title: "  自己的书名 📖  ")
        XCTAssertEqual(renamed.title, "自己的书名 📖"); XCTAssertEqual(renamed.userTitle, renamed.title)
        XCTAssertEqual(renamed.originalName, project.originalName); XCTAssertEqual(renamed.coverImage, cover.coverImage)
        let edited = try await repository.saveDocument(project: stale, document: note, markdown: body, expectedContentHash: BookImporter.sha256(Data(body.utf8)))
        XCTAssertEqual(edited.title, renamed.title); XCTAssertEqual(edited.userTitle, renamed.userTitle)
        var ai = stale; ai.chats.append(.init(id: "late", role: "assistant", content: "保留回答"))
        let merged = try await repository.commitAIResult(base: stale, result: ai, operationID: "rename-stale-ai")
        XCTAssertEqual(merged.title, renamed.title); XCTAssertEqual(merged.chats.last?.content, "保留回答")
        _ = try await repository.save(stale)
        let loaded = try await repository.loadAll(), reopened = try XCTUnwrap(loaded.first)
        XCTAssertEqual(reopened.title, renamed.title); XCTAssertEqual(reopened.originalName, project.originalName)
        let markdown = try await repository.readDocument(bookID: project.id, document: note)
        XCTAssertEqual(markdown, body)
        let original = await repository.sourceURL(for: reopened)
        XCTAssertEqual(try BookImporter.sha256(Data(contentsOf: original)), project.sourceHash)
    }
    func testRenameRejectsStaleAndInvalidCommandsWithoutMutation() async throws {
        let (root, repository, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repository.renameBook(bookID: project.id, expectedSourceHash: project.sourceHash, expectedTitle: project.title, title: "最新名称")
        for (hash, expected, title) in [(project.sourceHash, project.title, "过时指令"), ("wrong", "最新名称", "错误书"),
                (project.sourceHash, "最新名称", "  "), (project.sourceHash, "最新名称", "换\n行"),
                (project.sourceHash, "最新名称", String(repeating: "字", count: 257))] {
            do { _ = try await repository.renameBook(bookID: project.id, expectedSourceHash: hash, expectedTitle: expected, title: title); XCTFail("Must reject stale or invalid rename") } catch { }
        }
        let loaded = try await repository.loadAll(); XCTAssertEqual(loaded.first?.title, "最新名称")
    }
    func testRenamedTitleRoundTripsThroughProjectExportAndOldProjectsHaveNoOverride() async throws {
        let (root, repository, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(project.userTitle)
        let renamed = try await repository.renameBook(bookID: project.id, expectedSourceHash: project.sourceHash, expectedTitle: project.title, title: "新书名")
        let package = root.appendingPathComponent("export.readingbook"); try await repository.exportProject(renamed, to: package)
        let other = LibraryRepository(rootURL: root.appendingPathComponent("other")), imported = try await other.importProject(from: package)
        XCTAssertEqual(imported.title, "新书名"); XCTAssertEqual(imported.userTitle, "新书名")
        XCTAssertEqual(imported.sourceHash, project.sourceHash)
    }
    func testStaleCoverCropCannotReplaceNewCover() async throws {
        let (root, repository, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: image(), expectedCoverRevision: "original")
        let nextData = try image(width: 100, height: 200)
        let next = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: nextData, expectedCoverRevision: first.coverImage!.sha256)
        do { _ = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: image(), expectedCoverRevision: first.coverImage!.sha256); XCTFail("Stale crop must not overwrite") } catch { }
        let kept = try await repository.bookCoverData(for: next); XCTAssertEqual(kept, nextData)
    }
    func testUnderlineOptionalMetadataKeepsLegacyHighlightAndRejectsRegionStyle() throws {
        var record = ReaderAnnotation(sourceHash: String(repeating: "a", count: 64), page: 1, text: "原文", rangeLocation: 0, rangeLength: 2,
            quads: [.init(x: 20, y: 40, width: 100, height: 14)])
        let bytes = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("lineStyle"))
        XCTAssertNil(try JSONDecoder().decode(ReaderAnnotation.self, from: bytes).lineStyle)
        for style in ReaderAnnotationLineStyle.allCases {
            record.lineStyle = style
            XCTAssertEqual(try JSONDecoder().decode(ReaderAnnotation.self, from: JSONEncoder().encode(record)).lineStyle, style)
        }
        let project = BookProject(title: "原书", originalName: "source.pdf", sourceHash: record.sourceHash, units: [.init(id: "p1", order: 0, chapter: "PDF", page: 1, text: "原文")])
        record.kind = .region; record.text = ""; record.rangeLength = 0
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(record, in: project))
    }
    func testUnderlineNativePathsAreBoundedAndDifferentWithoutSolidFill() throws {
        var record = ReaderAnnotation(sourceHash: String(repeating: "a", count: 64), page: 1, text: "text", rangeLocation: 0, rangeLength: 4,
            quads: [.init(x: 20, y: 40, width: 100, height: 14)], color: .blue, lineStyle: .straight)
        let crop = CGRect(x: 0, y: 0, width: 400, height: 600)
        let straight = try XCTUnwrap(ReaderAnnotationAppearance.make(record, quad: record.quads[0], crop: crop))
        XCTAssertEqual(straight.type, "Ink"); XCTAssertEqual(straight.paths?.first?.elementCount, 2)
        record.lineStyle = .wavy
        let wave = try XCTUnwrap(ReaderAnnotationAppearance.make(record, quad: record.quads[0], crop: crop)), path = try XCTUnwrap(wave.paths?.first)
        XCTAssertGreaterThan(path.elementCount, 100); XCTAssertLessThan(path.bounds.height, 3)
        XCTAssertEqual(wave.bounds, CGRect(x: 20, y: 40, width: 100, height: 14))
        XCTAssertGreaterThanOrEqual(path.bounds.minY, 0); XCTAssertLessThanOrEqual(path.bounds.maxX, wave.bounds.width)
        record.lineStyle = nil
        XCTAssertEqual(ReaderAnnotationAppearance.make(record, quad: record.quads[0], crop: crop)?.type, "Highlight")
    }
    func testExactSecondSentenceUnderlinePersistsTrashRestoreAndOriginalPDF() async throws {
        let (root, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sentences.pdf"), output = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 500, height: 600)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil)); context.beginPDFPage(nil)
        let phrase = "Same sentence. Same sentence."
        context.textMatrix = .identity; context.textPosition = CGPoint(x: 30, y: 400)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: phrase, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)]) as CFAttributedString)
        CTLineDraw(line, context); context.endPDFPage(); context.closePDF(); try (output as Data).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("pdf-library"))
        let project = try await repository.create(BookImporter.importFile(at: source), sourceURL: source)
        let pdf = try XCTUnwrap(PDFDocument(data: output as Data)), page = try XCTUnwrap(pdf.page(at: 0))
        page.rotation = 90
        let text = try XCTUnwrap(page.string) as NSString, range = text.range(of: "Same sentence.", options: .backwards)
        let selection = try XCTUnwrap(page.selection(for: range))
        var record = try XCTUnwrap(ReaderAnnotationCapture.capture(selection: selection, document: pdf, sourceHash: project.sourceHash).first)
        XCTAssertGreaterThan(record.rangeLocation, 0); XCTAssertEqual(record.rangeLocation, range.location)
        record.lineStyle = .wavy; record.color = .blue
        let saved = try await repository.saveAnnotations(project: project, annotations: [record])
        XCTAssertEqual(saved.readerAnnotations?.first?.rangeLocation, range.location)
        _ = try await repository.setAnnotationTrashed(project: saved, annotationID: record.id, trashed: true)
        _ = try await repository.setAnnotationTrashed(project: saved, annotationID: record.id, trashed: false)
        let reopened = try await repository.loadAll(); XCTAssertEqual(reopened.first?.readerAnnotations?.first?.lineStyle, .wavy)
        XCTAssertNil(reopened.first?.readerAnnotations?.first?.trashedAt)
        let original = await repository.sourceURL(for: saved); XCTAssertEqual(try Data(contentsOf: original), output as Data)
    }
}
