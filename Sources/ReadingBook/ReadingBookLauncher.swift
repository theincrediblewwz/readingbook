import Foundation
import SwiftUI
import Darwin

/// Packaging checks run before SwiftUI constructs ReadingBookApp or AppStore.
@main
enum ReadingBookLauncher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify-resources") {
            do {
                try PackagedResourceVerification.run()
                print("ReadingBook 0.13.0 资源检查 OK")
            } catch {
                let message = "ReadingBook 0.13.0 资源检查失败：\(error.localizedDescription)\n"
                try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
                exit(1)
            }
            return
        }
        ReadingBookApp.main()
    }
}

/// Deliberately reads only the resources inside the completed .app. A build-tree
/// Bundle.module fallback must never make a broken distribution pass this check.
private enum PackagedResourceVerification {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() throws {
        let app = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard app.pathExtension.lowercased() == "app" else {
            throw Failure(message: "请运行已打包的 ReadingBook.app 内的二进制。")
        }
        let expected = app.appendingPathComponent("Contents/Resources/ReadingBook_ReadingBook.bundle", isDirectory: true)
            .standardizedFileURL
        guard let bundle = ReadingBookResources.bundle,
              bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath() == expected else {
            throw Failure(message: "未命中 .app/Contents/Resources 中的资源包。")
        }
        guard let html = bundle.url(forResource: "index", withExtension: "html", subdirectory: "Markdown") else {
            throw Failure(message: "缺少 Markdown/index.html。")
        }
        let markdown = html.deletingLastPathComponent()
        _ = try read(html, inside: expected)
        for path in ["renderer.js", "reader.css", "vendor/markdown-it/browser/markdown-it.umd.min.js", "vendor/katex/katex.min.js"] {
            _ = try read(markdown.appendingPathComponent(path), inside: expected)
        }
        let katex = markdown.appendingPathComponent("vendor/katex", isDirectory: true)
        let cssData = try read(katex.appendingPathComponent("katex.min.css"), inside: expected)
        guard let css = String(data: cssData, encoding: .utf8) else {
            throw Failure(message: "KaTeX CSS 不是有效 UTF-8。")
        }
        // Validate every WOFF2 referenced by the shipped CSS, including fonts
        // added by future KaTeX updates, instead of checking a single sample.
        let pattern = #"url\(["']?([^"')]+\.woff2)["']?\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ranges = regex.matches(in: css, range: NSRange(css.startIndex..., in: css))
        var fontPaths = Set<String>()
        for match in ranges {
            guard let range = Range(match.range(at: 1), in: css) else { continue }
            fontPaths.insert(String(css[range]))
        }
        guard !fontPaths.isEmpty else { throw Failure(message: "KaTeX CSS 未声明 WOFF2 字体。") }
        for path in fontPaths.sorted() {
            guard path.hasPrefix("fonts/"), !path.contains(":"), !path.contains("\\"),
                  path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw Failure(message: "KaTeX 字体路径无效。")
            }
            let data = try read(katex.appendingPathComponent(path), inside: expected)
            guard data.prefix(4) == Data("wOF2".utf8) else { throw Failure(message: "WOFF2 字体损坏：\(path)") }
        }
        guard let catalogURL = bundle.url(forResource: "provider-catalog", withExtension: "json") else {
            throw Failure(message: "缺少 provider-catalog.json。")
        }
        guard let symbolsURL = bundle.url(forResource: "symbols", withExtension: "json", subdirectory: "Brand"),
              let symbols = try JSONSerialization.jsonObject(with: read(symbolsURL, inside: expected)) as? [String: Any],
              let glyphs = symbols["glyphs"] as? [String: Any],
              ["mark", "reader", "workflow", "chat", "note", "map", "mindmap", "relations", "knowledge"].allSatisfy({ glyphs[$0] != nil }) else {
            throw Failure(message: "缺少 ReadingBook 品牌图标资源。")
        }
        let catalog = try JSONDecoder().decode(ProviderCatalog.self, from: read(catalogURL, inside: expected))
        guard !catalog.verifiedAt.isEmpty, !catalog.providers.isEmpty,
              catalog.providers.allSatisfy({ !$0.id.isEmpty && !$0.models.isEmpty }) else {
            throw Failure(message: "服务目录或模型列表为空。")
        }
    }

    private static func read(_ url: URL, inside bundle: URL) throws -> Data {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(bundle.path + "/") else {
            throw Failure(message: "资源指向 .app 资源包以外：\(url.lastPathComponent)")
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 16 * 1_024 * 1_024 else {
            throw Failure(message: "资源为空、过大或不是普通文件：\(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: file)
        guard data.count == size else { throw Failure(message: "资源读取不完整：\(url.lastPathComponent)") }
        return data
    }
}
