import Foundation
import XCTest
@testable import ReadingCore
#if os(macOS)
import CoreGraphics
import CoreText
import PDFKit

final class EncryptedPDFTests: XCTestCase {
    private let openPassword = "readingbook-test-open-7c91"
    private let ownerPassword = "readingbook-test-owner-8a42"

    private func encryptedFixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-EncryptedPDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("encrypted.pdf")
        let output = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributes = [kCTFontAttributeName as String: font] as CFDictionary
        let text = try XCTUnwrap(CFAttributedStringCreate(nil, "Encrypted source detail: alpha 17." as CFString, attributes))
        context.textPosition = CGPoint(x: 45, y: 720)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: output as Data))
        XCTAssertTrue(document.write(to: url, withOptions: [.ownerPasswordOption: ownerPassword, .userPasswordOption: openPassword]))
        let locked = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(locked.isEncrypted)
        XCTAssertTrue(locked.isLocked)
        return (directory, url)
    }

    func testEncryptedImportRetriesExtractsAndPreservesOriginalThroughExport() async throws {
        let (directory, source) = try encryptedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        do { _ = try await BookImporter.importFile(at: source); XCTFail("锁定 PDF 必须请求密码") }
        catch { XCTAssertEqual(error as? PDFPasswordError, .needsPassword) }
        do { _ = try await BookImporter.importFile(at: source, password: "wrong"); XCTFail("错误密码不能生成原文单元") }
        catch { XCTAssertEqual(error as? PDFPasswordError, .wrongPassword) }
        let project = try await BookImporter.importFile(at: source, password: openPassword)
        XCTAssertTrue(project.units.map(\.text).joined().contains("alpha 17"))
        XCTAssertEqual(project.sourceHash, try BookImporter.sha256(original))
        XCTAssertEqual(try Data(contentsOf: source), original)
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        try await repository.create(project, sourceURL: source)
        let stored = await repository.sourceURL(for: project)
        XCTAssertEqual(try Data(contentsOf: stored), original)
        let storedPDF = try XCTUnwrap(PDFDocument(url: stored))
        XCTAssertTrue(storedPDF.isLocked, "书库仍保存原始加密 PDF")
        let package = directory.appendingPathComponent("encrypted.readingbook", isDirectory: true)
        try await repository.exportProject(project, to: package)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("source/encrypted.pdf")), original)
        let metadata = try String(contentsOf: package.appendingPathComponent("project.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains(openPassword))
        XCTAssertFalse(metadata.contains(ownerPassword))
    }

    func testEncryptedOCRRendersOnlyAfterUnlockWithoutProviderRequest() async throws {
        let (directory, source) = try encryptedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        XCTAssertThrowsError(try PDFOCRReader.renderPage(sourceURL: source, page: 1)) {
            XCTAssertEqual($0 as? PDFPasswordError, .needsPassword)
        }
        XCTAssertThrowsError(try PDFOCRReader.renderPage(sourceURL: source, page: 1, password: "wrong")) {
            XCTAssertEqual($0 as? PDFPasswordError, .wrongPassword)
        }
        let page = try PDFOCRReader.renderPage(sourceURL: source, page: 1, password: openPassword)
        XCTAssertEqual(page.width, 1650)
        XCTAssertEqual(page.height, 2200)
        XCTAssertFalse(page.data.isEmpty)
        XCTAssertLessThanOrEqual(page.data.count, PDFOCRReader.maximumImageBytes)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: source)).isLocked)

        let reader = PDFOCRReader()
        // Invalid transport configuration is a second guard against any network
        // call; the password error must occur before transport preparation.
        let settings = ProviderSettings(baseURL: "invalid-url", model: "unused", maxRequestsPerRun: 1, maxOutputTokens: 512)
        do {
            _ = try await reader.recognizePage(sourceURL: source, page: 1, settings: settings, apiKey: "", password: "wrong")
            XCTFail("锁定页不能进入 OCR 请求")
        } catch { XCTAssertEqual(error as? PDFPasswordError, .wrongPassword) }
        let requests = await reader.requestCount
        XCTAssertEqual(requests, 0)
    }
}
#endif
