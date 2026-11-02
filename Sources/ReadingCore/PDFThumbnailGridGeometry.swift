import Foundation

public enum PDFThumbnailDensity: String, CaseIterable, Sendable {
    case small, medium, large
    public var preferredWidth: CGFloat { switch self { case .small: return 96; case .medium: return 160; case .large: return 248 } }
}

/// PDFThumbnailView includes a small gutter around each image. Size images to
/// the available columns, rather than leaving a fixed-width image in a wide row.
public struct PDFThumbnailGridGeometry: Equatable, Sendable {
    public let columns: Int
    public let thumbnailSize: CGSize
    public init(width: CGFloat, pageAspectRatio: CGFloat, density: PDFThumbnailDensity) {
        let available = width.isFinite ? min(2400, max(100, width)) : 100
        let aspect = pageAspectRatio.isFinite ? min(4, max(0.2, pageAspectRatio)) : 0.7
        columns = max(1, Int(available / (density.preferredWidth + 20)))
        let imageWidth = max(64, floor(available / CGFloat(columns)) - 20)
        thumbnailSize = CGSize(width: imageWidth, height: imageWidth / aspect)
    }
}
