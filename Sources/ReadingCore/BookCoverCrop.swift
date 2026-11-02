import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics

/// Normalized pan keeps the crop identical when the preview window resizes.
/// Coordinates in this rectangle use the preview's top-left origin.
public enum BookCoverCropGeometry {
    public static let aspectRatio = 0.78
    public static func frame(image: CGSize, viewport: CGSize, zoom: Double, panX: Double, panY: Double) -> CGRect? {
        guard [image.width, image.height, viewport.width, viewport.height, zoom, panX, panY].allSatisfy(\.isFinite),
              image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let scale = max(viewport.width / image.width, viewport.height / image.height) * min(4, max(1, zoom))
        let width = image.width * scale, height = image.height * scale
        let x = max(0, (width - viewport.width) / 2), y = max(0, (height - viewport.height) / 2)
        return CGRect(x: (viewport.width - width) / 2 + min(1, max(-1, panX)) * x,
                      y: (viewport.height - height) / 2 + min(1, max(-1, panY)) * y, width: width, height: height)
    }
}

/// A single bounded, orientation-correct decode is shared by preview and export.
/// No image file or project is touched until the user applies the crop.
public final class BookCoverCropImage: @unchecked Sendable {
    public let image: CGImage
    public init(data: Data) throws {
        _ = try BookCoverImage.inspect(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ReadingError.invalid("无法准备这张封面。") }
        self.image = image
    }
    public func jpeg(zoom: Double, panX: Double, panY: Double) throws -> Data {
        let width = 1248, height = 1600
        guard let frame = BookCoverCropGeometry.frame(image: CGSize(width: image.width, height: image.height),
                viewport: CGSize(width: width, height: height), zoom: zoom, panX: panX, panY: panY),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ReadingError.invalid("封面裁剪参数无效，原封面保留。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: frame.minX, y: CGFloat(height) - frame.maxY, width: frame.width, height: frame.height))
        guard let cropped = context.makeImage() else { throw ReadingError.invalid("无法导出封面，原封面保留。") }
        for quality in [0.9, 0.8, 0.7] {
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, "public.jpeg" as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), result.length < BookCoverImage.maximumBytes {
                let bytes = result as Data; _ = try BookCoverImage.inspect(bytes); return bytes
            }
        }
        throw ReadingError.invalid("裁剪后图片仍超过 2 MB，原封面保留。")
    }
}
#endif
