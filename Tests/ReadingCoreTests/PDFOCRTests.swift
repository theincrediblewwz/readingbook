import Foundation
import XCTest
@testable import ReadingCore
#if os(macOS)
import CoreGraphics
import PDFKit
#endif

final class PDFOCRTests: XCTestCase {
    func testVisionWireShapeAndStrictOCRParsingPreserveUncertainty() throws {
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        let messages = try PDFOCRReader.makeMessages(imageData: image, mimeType: "image/png", page: 3)
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let imagePart = try XCTUnwrap(parts.last?["image_url"] as? [String: Any])
        XCTAssertEqual(imagePart["detail"] as? String, "high")
        XCTAssertEqual(imagePart["url"] as? String, "data:image/png;base64,\(image.base64EncodedString())")
        let markdown = "## 定理 2\n\n$E=mc^2$\n\n证明：[看不清]"
        let json = try JSONSerialization.data(withJSONObject: ["markdown": markdown, "issues": []])
        let content = try XCTUnwrap(String(data: json, encoding: .utf8))
        let result = try PDFOCRReader.parseResponse(content: content, finishReason: "stop", page: 3, model: "vision-model")
        XCTAssertEqual(result.markdown, markdown, "不能把转录替换成摘要或润色后的文本。")
        XCTAssertEqual(result.page, 3)
        XCTAssertTrue(result.issues.contains(PDFOCRReader.reviewNotice))
        XCTAssertTrue(result.issues.contains { $0.contains("看不清") })
        XCTAssertThrowsError(try PDFOCRReader.parseResponse(content: content, finishReason: "length", page: 3, model: "vision-model"))
        for malformed in ["```json\n\(content)\n```", "{\"markdown\":\"\",\"issues\":[]}", "{\"markdown\":\"正文\",\"issues\":[1]}", "{\"markdown\":\"正文\",\"issues\":[],\"summary\":\"不能增加解释\"}"] {
            XCTAssertThrowsError(try PDFOCRReader.parseResponse(content: malformed, finishReason: "stop", page: 3, model: "vision-model"))
        }
    }

    #if os(macOS)
    func testLateOCRRejectsCanonicallyEquivalentSourceEditWithoutChangingCurrentLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-OCR-SourceBytes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = NSMutableData(), source = directory.appendingPathComponent("book.pdf")
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdf as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let renderer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        renderer.beginPDFPage(nil); renderer.endPDFPage(); renderer.closePDF()
        let originalPDF = pdf as Data
        try originalPDF.write(to: source)
        let oldText = "Cafe\u{301} 的原文。", currentText = "Caf\u{e9} 的原文。"
        XCTAssertEqual(oldText, currentText, "回归必须覆盖Swift规范等价。")
        XCTAssertFalse(oldText.utf8.elementsEqual(currentText.utf8))
        var old = BookProject(title: "OCR原文字节", originalName: "book.pdf", sourceHash: try BookImporter.sha256(originalPDF),
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: oldText)])
        PluginEngine.seed(&old)
        let root = directory.appendingPathComponent("library", isDirectory: true), repository = LibraryRepository(rootURL: root)
        try await repository.create(old, sourceURL: source)
        var current = old; current.units[0].text = currentText; current.bookmarks = ["u1"]
        let saved = try await repository.save(current)
        XCTAssertEqual(old.units, saved.units, "仅使用Swift单元相等无法发现此来源编辑。")
        let metadataURL = root.appendingPathComponent("books/\(old.id)/project.json")
        let preservedMetadata = try Data(contentsOf: metadataURL)
        let result = OCRPageResult(page: 1, markdown: "迟到的识别结果", issues: [], model: "fixture-vision")
        do {
            _ = try await repository.saveOCRPage(project: old, result: result)
            XCTFail("原文字节已变化，迟到OCR必须拒绝，不能覆盖当前内容。")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("识别期间原文层已变化"))
        }
        let loaded = try await repository.loadAll()
        let retained = try XCTUnwrap(loaded.first)
        XCTAssertTrue(retained.units[0].text.utf8.elementsEqual(currentText.utf8))
        XCTAssertEqual(retained.units.map(\.id), ["u1"])
        XCTAssertEqual(retained.bookmarks, ["u1"])
        XCTAssertNil(retained.ocrPages)
        XCTAssertEqual(try Data(contentsOf: metadataURL), preservedMetadata)
        let storedSource = await repository.sourceURL(for: retained)
        XCTAssertEqual(try Data(contentsOf: storedSource), originalPDF)
        let fresh = try await repository.saveOCRPage(project: saved, result: result)
        XCTAssertEqual(fresh.units.map(\.text).joined(), result.markdown, "对当前相同字节版本的OCR仍能正常保存。")
        XCTAssertEqual(try Data(contentsOf: storedSource), originalPDF)
    }

    func testPageRenderingRespectsCropRotationAndOutputBoundsWithoutNetwork() throws {
        let output = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: output as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 100, y: 200, width: 200, height: 400), for: .cropBox)
        page.rotation = 90
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url))
        let rendered = try PDFOCRReader.renderPage(sourceURL: url, page: 1)
        XCTAssertEqual(rendered.width, 2200)
        XCTAssertEqual(rendered.height, 1100)
        XCTAssertLessThanOrEqual(rendered.data.count, PDFOCRReader.maximumImageBytes)
        XCTAssertTrue(["image/png", "image/jpeg"].contains(rendered.mimeType))
        XCTAssertThrowsError(try PDFOCRReader.renderPage(sourceURL: url, page: 2))
    }
    #endif
}
