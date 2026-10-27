import Foundation
import CoreGraphics
import CoreText
import PDFKit

@main struct NativeWorkerFixtureProbe {
    @MainActor static func attributed(_ text: String, size: CGFloat = 24, kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil),
            NSAttributedString.Key(kCTKernAttributeName as String): kern
        ])
    }
    @MainActor static func make(holdFonts: Bool) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw ProbeError.invalid }
        var media = CGRect(x: 0, y: 0, width: 600, height: 600)
        guard let renderer = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw ProbeError.invalid }
        renderer.beginPDFPage(nil); renderer.textMatrix = .identity
        var heldValues: [NSAttributedString] = [], heldLines: [CTLine] = []
        for (index, quote) in ["首行😀正文。", "高小字间距句。", "页末最后一句。"].enumerated() {
            let value: NSAttributedString
            if index == 1 {
                let mixed = NSMutableAttributedString(attributedString: attributed(String(quote.prefix(1)), size: 64))
                mixed.append(attributed(String(quote.dropFirst()), size: 18, kern: 8)); value = mixed
            } else { value = attributed(quote) }
            renderer.textPosition = CGPoint(x: 32, y: 510 - CGFloat(index) * 120)
            if holdFonts {
                let line = CTLineCreateWithAttributedString(value as CFAttributedString)
                heldValues.append(value); heldLines.append(line); CTLineDraw(line, renderer)
            } else { CTLineDraw(CTLineCreateWithAttributedString(value as CFAttributedString), renderer) }
        }
        renderer.endPDFPage(); renderer.closePDF()
        withExtendedLifetime(heldValues) { withExtendedLifetime(heldLines) {} }
        return data as Data
    }
    @MainActor static func report(_ name: String, _ document: PDFDocument) throws {
        guard let page = document.page(at: 0), let text = page.string else { throw ProbeError.invalid }
        print("CASE \(name) crop=\(page.bounds(for: .cropBox)) rotation=\(page.rotation) native=\(page.numberOfCharacters) utf16=\(text.utf16.count)")
        print("TEXT \(text.debugDescription)")
        print("SCALARS \(text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))")
        for quote in ["首行😀正文。", "高小字间距句。", "页末最后一句。"] {
            print("QUOTE \(quote.debugDescription) found=\(text.range(of: quote, options: .literal) != nil)")
        }
    }
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-FixtureProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard CommandLine.arguments.count == 3 else { throw ProbeError.invalid }
        let name = CommandLine.arguments[1], holdFonts = CommandLine.arguments[2] == "held"
        print("FONT LIFETIME \(holdFonts)")
        let data = try make(holdFonts: holdFonts)
        if name == "direct-data" {
            guard let direct = PDFDocument(data: data) else { throw ProbeError.invalid }
            try report(name, direct)
        } else if name == "raw-file" {
            let raw = folder.appendingPathComponent("raw.pdf")
            try data.write(to: raw)
            guard let rawDocument = PDFDocument(url: raw) else { throw ProbeError.invalid }
            try report(name, rawDocument)
        } else {
            guard let source = PDFDocument(data: data), let page = source.page(at: 0) else { throw ProbeError.invalid }
            if name.contains("crop") || name == "combined" { page.setBounds(CGRect(x: 10, y: 15, width: 580, height: 570), for: .cropBox) }
            if name.contains("rotation") || name == "combined" { page.rotation = 90 }
            let encrypted = name == "password" || name == "combined"
            let url = folder.appendingPathComponent(name + ".pdf")
            let written = encrypted ? source.write(to: url, withOptions: [.ownerPasswordOption: "fixture-owner", .userPasswordOption: "fixture-open"]) : source.write(to: url)
            guard written, let reopened = PDFDocument(url: url) else { throw ProbeError.invalid }
            if encrypted, !reopened.unlock(withPassword: "fixture-open") { throw ProbeError.invalid }
            try report(name, reopened)
        }
    }
    enum ProbeError: Error { case invalid }
}
