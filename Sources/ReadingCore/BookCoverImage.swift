import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

public struct BookCoverImage: Codable, Hashable, Sendable {
    public static let maximumBytes = 2_000_000
    public let sha256: String
    public let fileExtension: String
    public let byteCount: Int
    public let width: Int
    public let height: Int
    public var relativePath: String { "cover/" + sha256 + "." + fileExtension }
    private static let extensions: Set<String> = ["jpg", "png", "heic", "heif", "webp", "gif", "tiff", "bmp", "avif"]
    public func validate() throws {
        guard sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Self.extensions.contains(fileExtension), byteCount > 0, byteCount < Self.maximumBytes,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 40_000_000 else {
            throw ReadingError.invalid("封面信息无效；原书、笔记和分析保留。")
        }
    }
    public static func inspect(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count < maximumBytes else { throw ReadingError.invalid("请选择小于 2 MB 的封面图片。") }
        #if canImport(ImageIO)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ReadingError.invalid("无法读取这张图片；请选择 PNG、JPEG、HEIC、WebP、GIF、TIFF 或 BMP。")
        }
        let formats = ["public.jpeg":"jpg", "public.png":"png", "public.heic":"heic", "public.heif":"heif",
                       "org.webmproject.webp":"webp", "com.compuserve.gif":"gif", "public.tiff":"tiff", "com.microsoft.bmp":"bmp", "public.avif":"avif"]
        guard let format = formats[type] else { throw ReadingError.invalid("暂不支持这张封面的格式，请换用 PNG 或 JPEG。") }
        let value = Self(sha256: try BookImporter.sha256(data), fileExtension: format, byteCount: data.count, width: width, height: height)
        try value.validate()
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceThumbnailMaxPixelSize:64, kCGImageSourceCreateThumbnailWithTransform:true,
            kCGImageSourceShouldCache:false] as CFDictionary) != nil else { throw ReadingError.invalid("图片内容不完整；未更换原封面。") }
        return value
        #else
        throw ReadingError.invalid("当前系统不支持封面图片解码。")
        #endif
    }
    public static func preview(_ data: Data, maximumPixelSize: Int = 640) throws -> Data {
        _ = try inspect(data)
        #if canImport(ImageIO)
        guard (64...1024).contains(maximumPixelSize), let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maximumPixelSize,kCGImageSourceShouldCache:false] as CFDictionary) else {
            throw ReadingError.invalid("无法准备封面预览。")
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { throw ReadingError.invalid("无法准备封面预览。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ReadingError.invalid("无法准备封面预览。") }
        return result as Data
        #else
        throw ReadingError.invalid("当前系统不支持封面图片解码。")
        #endif
    }
}

public enum BookReadingProgress {
    /// Human reading position, deliberately independent from AI analysis coverage.
    public static func fraction(in project: BookProject, unitID: String?, page: Int?) -> Double {
        guard !project.units.isEmpty else { return 0 }
        let index = unitID.flatMap { id in project.units.firstIndex { $0.id == id } }
            ?? page.flatMap { number in project.units.lastIndex { $0.page == number } }
        guard let index else { return 0 }
        return min(1, max(0, Double(index + 1) / Double(project.units.count)))
    }
}
