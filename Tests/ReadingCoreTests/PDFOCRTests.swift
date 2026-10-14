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
