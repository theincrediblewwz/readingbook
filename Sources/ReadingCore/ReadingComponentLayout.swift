import Foundation

/// One reversible presentation change. Only geometry and asset choices are
/// retained; shared bindings and facts are never duplicated in this backup.
public struct CompositionLayoutBackup: Codable, Hashable, Sendable {
    public var rootID: String
    public var layout: [CompositionLayoutNode]
    public var bindingsRevision: String
    public var markerAssets: [String: [String: String]]? = nil
}
public enum ReadingComponentLayout {
    public static func revision(_ definition: CompositionDefinition) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try BookImporter.sha256(encoder.encode(definition))
    }
    private static func bindingsRevision(_ definition: CompositionDefinition) throws -> String {
        var value = definition; value.layout = []; value.rootID = ""
        for index in value.parts.indices { value.parts[index].markerAssets = nil }
        return try revision(value)
    }
    public static func changed(_ view: ViewDefinition, expectedRevision: String, layout: [CompositionLayoutNode]?,
                               rootID: String?, restore: Bool, markerAssets: [String: [String: String]]? = nil, in book: BookProject) throws -> ViewDefinition {
        guard view.rendererID == "reading.composition", view.configuration?["presentation"] != "inline", var composition = view.composition else {
            throw ReadingError.invalid("只能调整已有组合视图的布局，资料绑定不会改变。")
        }
        guard try revision(composition) == expectedRevision else { throw ReadingError.invalid("这个布局已变化，请重新打开视图取得最新布局版本；没有覆盖。") }
        let bindings = try bindingsRevision(composition)
        var previous = CompositionLayoutBackup(rootID: composition.rootID, layout: composition.layout, bindingsRevision: bindings)
        let materials = Dictionary(uniqueKeysWithValues: composition.parts.compactMap { part in part.markerAssets.map { (part.id, $0) } })
        previous.markerAssets = materials.isEmpty ? nil : materials
        if restore {
            guard layout == nil, rootID == nil, markerAssets == nil, let backup = view.previousLayout, backup.bindingsRevision == bindings else {
                throw ReadingError.invalid("没有可恢复的同一份资料布局；未改动当前视图。")
            }
            composition.layout = backup.layout; composition.rootID = backup.rootID
            for index in composition.parts.indices { composition.parts[index].markerAssets = backup.markerAssets?[composition.parts[index].id] }
        } else {
            guard layout != nil || markerAssets != nil, rootID == nil || layout != nil else { throw ReadingError.invalid("请提供布局或地图素材映射；元件和资料绑定保持不变。") }
            if let layout {
                guard !layout.isEmpty, layout.count <= 48 else { throw ReadingError.invalid("请提供完整的1至48项布局。") }
                composition.layout = layout; composition.rootID = rootID ?? composition.rootID
            }
            if let markerAssets {
                let mapIDs = Set(composition.parts.filter { $0.primitive == .map }.map(\.id))
                guard !markerAssets.isEmpty, markerAssets.count <= 24, Set(markerAssets.keys).isSubset(of: mapIDs) else { throw ReadingError.invalid("markerAssets只能引用本视图已有geo.map元件ID。") }
                for index in composition.parts.indices {
                    if let values = markerAssets[composition.parts[index].id] { composition.parts[index].markerAssets = values }
                }
            }
        }
        try CompositionRuntime.validate(composition, in: book)
        guard try JSONEncoder().encode(previous).count <= 32_768 else { throw ReadingError.invalid("上次布局超过可恢复大小，未覆盖。") }
        var updated = view
        if updated.composition != composition { updated.previousLayout = previous; updated.composition = composition }
        return updated
    }
}
extension LibraryRepository {
    /// Re-read current canonical data in one actor turn. Concurrent notes,
    /// analyses and other view edits are retained rather than copied from chat.
    public func updateReadingComponentLayout(bookID: String, sourceHash: String, viewID: String, expectedRevision: String,
                                             layout: [CompositionLayoutNode]?, rootID: String? = nil, restore: Bool = false, markerAssets: [String: [String: String]]? = nil,
                                             grant: ControlledWriteGrant? = nil) throws -> ReadingComponentInstallation {
        try Task.checkCancellation()
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        var current = try readProject(in: directory)
        guard current.sourceHash == sourceHash, let index = current.views.firstIndex(where: { $0.id == viewID }),
              !current.plugins.contains(where: { current.disabledPluginIDs.contains($0.id) && $0.views.contains { $0.id == viewID } }) else {
            throw ReadingError.invalid("原书版本或组件可用状态已改变，未调整布局。")
        }
        let before = current
        let view = try ReadingComponentLayout.changed(current.views[index], expectedRevision: expectedRevision, layout: layout, rootID: rootID, restore: restore, markerAssets: markerAssets, in: current)
        guard view != current.views[index] else { return .init(project: current, view: view, created: false) }
        current.views[index] = view
        try Task.checkCancellation()
        let saved = try saveCanonicalProject(current)
        try followOwnComponentAppend(grant: grant, before: before, after: saved)
        return .init(project: saved, view: view, created: false)
    }
}
