import Foundation

/// Disposable presentation state. Source books, Markdown and graph nodes never live here.
public struct WorkspacePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 1e12 && abs(y) <= 1e12 }
}
public struct WorkspaceGraphCamera: Codable, Equatable, Sendable {
    public var center: WorkspacePoint
    public var scale: Double
    public init(center: WorkspacePoint, scale: Double) { self.center = center; self.scale = scale }
    public var isValid: Bool { center.isValid && scale.isFinite && (0.00001...4).contains(scale) }
}
public struct WorkspaceSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var isValid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 && width <= 100_000 && height <= 100_000 }
}
public struct WorkspacePanelMemory: Codable, Equatable, Sendable {
    public var origin: WorkspacePoint?
    public var isPresented: Bool
    public var collapsed: Bool
    public var size: WorkspaceSize?
    public var dock: String?
    public init(origin: WorkspacePoint? = nil, isPresented: Bool = true, collapsed: Bool = false, size: WorkspaceSize? = nil, dock: String? = nil) {
        self.origin = origin; self.isPresented = isPresented; self.collapsed = collapsed
        self.size = size; self.dock = dock
    }
}
public struct WorkspacePDFMemory: Codable, Equatable, Sendable {
    public var page: Int
    /// PDF page coordinates normalized to the unrotated crop box; PDFKit owns conversion.
    public var location: WorkspacePoint?
    public var scale: Double
    public var fitMode: String
    public var continuous: Bool
    public var thumbnails: Bool
    public init(page: Int, location: WorkspacePoint? = nil, scale: Double = 1, fitMode: String = "width", continuous: Bool = true, thumbnails: Bool = false) {
        self.page = page; self.location = location; self.scale = scale; self.fitMode = fitMode; self.continuous = continuous; self.thumbnails = thumbnails
    }
    public var isValid: Bool { page > 0 && page <= 1_000_000 && scale.isFinite && (0.05...12).contains(scale) && ["page", "width", "actual", "custom"].contains(fitMode) && (location == nil || location!.isValid) }
}
public struct WorkspaceMapMemory: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double
    public init(latitude: Double, longitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.latitude = latitude; self.longitude = longitude; self.latitudeDelta = latitudeDelta; self.longitudeDelta = longitudeDelta
    }
    public var isValid: Bool { [latitude, longitude, latitudeDelta, longitudeDelta].allSatisfy(\.isFinite) && (-90...90).contains(latitude) && (-180...180).contains(longitude) && latitudeDelta > 0 && latitudeDelta <= 180 && longitudeDelta > 0 && longitudeDelta <= 360 }
}
public struct BookWorkspaceMemory: Codable, Equatable, Sendable {
    public var version = 1
    public var bookID = ""
    public var sourceHash = ""
    public var route = "reader"
    public var documentID: String?
    public var pdf: WorkspacePDFMemory?
    public var graphs: [String: WorkspaceGraphCamera] = [:]
    public var panels: [String: WorkspacePanelMemory] = [:]
    public var map: WorkspaceMapMemory?
    public var timeFrom: Double?
    public var timeTo: Double?
    public var timeCursor: Double?
    public var temporalAxis: String?
    public var temporalEntityID: String?
    public var showUndated = true
    public var timelineDock: String?
    public var readerShowsPDF = true
    public var readerOutline = false
    public var readingSourceMode = "original"
    /// A hidden PDF must not override the last text/OCR unit or parallel-reading position.
    public var activePDFPage: Int? { readerShowsPDF && readingSourceMode == "original" ? pdf?.page : nil }
    public init(bookID: String = "", sourceHash: String = "") { self.bookID = bookID; self.sourceHash = sourceHash }
    public func sanitized(bookID: String, sourceHash: String) -> Self {
        guard version == 1, self.bookID == bookID, self.sourceHash == sourceHash else { return Self(bookID: bookID, sourceHash: sourceHash) }
        var value = self
        if route.count > 256 { value.route = "reader" }
        if documentID?.count ?? 0 > 256 { value.documentID = nil }
        if pdf?.isValid == false { value.pdf = nil }
        value.graphs = graphs.filter { $0.key.count <= 256 && $0.value.isValid }
        value.panels = panels.filter { $0.key.count <= 256 && ($0.value.origin == nil || $0.value.origin!.isValid) }.mapValues { panel in
            var panel = panel
            if panel.size?.isValid == false { panel.size = nil }
            if let dock = panel.dock, FloatingPanelDock(rawValue: dock) == nil { panel.dock = nil }
            return panel
        }
        if map?.isValid == false { value.map = nil }
        if let from = timeFrom, let to = timeTo, from.isFinite, to.isFinite, from <= to, abs(from) <= 1e9, abs(to) <= 1e9 {} else { value.timeFrom = nil; value.timeTo = nil }
        if let cursor = timeCursor, !cursor.isFinite || abs(cursor) > 1e9 { value.timeCursor = nil }
        if (temporalAxis?.count ?? 0) > 256 { value.temporalAxis = nil }
        if (temporalEntityID?.count ?? 0) > 256 { value.temporalEntityID = nil }
        if !["original", "stacked", "parallel", "layers"].contains(readingSourceMode) { value.readingSourceMode = "original" }
        return value
    }
    public mutating func resetLayout() {
        graphs = [:]; panels = [:]; map = nil; timelineDock = nil
        readerOutline = false
        if pdf != nil { pdf!.scale = 1; pdf!.fitMode = "width"; pdf!.continuous = true; pdf!.thumbnails = false }
    }
}

