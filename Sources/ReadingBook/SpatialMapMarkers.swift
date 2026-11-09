import SwiftUI
import MapKit
import ReadingCore

/// Shared visual materials for standalone and composed maps. A material is a
/// presentation hint, not an additional persisted event type or fact store.
struct SpatialMarkerGlyph: View {
    let assetID: String
    var tint: Color {
        switch SpatialMarkerAssets.asset(assetID).tint {
        case "fire": return .orange
        case "battle": return .red
        case "retreat": return .teal
        case "march": return Palette.accent
        case "water": return .cyan
        case "camp": return Palette.copper
        case "meeting": return .purple
        default: return Palette.accent
        }
    }
    var body: some View {
        Group {
            if assetID == "battle" {
                Canvas { context, size in
                    // Two crossed swords with separate hilts, a vector material
                    // rather than a platform-dependent missing SF Symbol.
                    var path = Path()
                    path.move(to: .init(x: size.width * 0.17, y: size.height * 0.12))
                    path.addLine(to: .init(x: size.width * 0.83, y: size.height * 0.86))
                    path.move(to: .init(x: size.width * 0.83, y: size.height * 0.12))
                    path.addLine(to: .init(x: size.width * 0.17, y: size.height * 0.86))
                    path.move(to: .init(x: size.width * 0.58, y: size.height * 0.79))
                    path.addLine(to: .init(x: size.width * 0.84, y: size.height * 0.56))
                    path.move(to: .init(x: size.width * 0.16, y: size.height * 0.56))
                    path.addLine(to: .init(x: size.width * 0.42, y: size.height * 0.79))
                    context.stroke(path, with: .color(tint), style: .init(lineWidth: 2, lineCap: .round))
                }.frame(width: 18, height: 18)
            } else {
                Image(systemName: SpatialMarkerAssets.asset(assetID).symbol).font(.system(size: 16, weight: .semibold))
                    .frame(width: 18, height: 18).foregroundStyle(tint)
            }
        }.accessibilityHidden(true)
    }
}

struct SpatialMapAnnotations: MapContent {
    let nodes: [SpatialMarkerNode]
    var activate: (SpatialMarkerNode) -> Void
    private func anchor(for node: SpatialMarkerNode) -> UnitPoint {
        let width = node.isGroup ? 68.0 : node.showsTitle ? 172.0 : 32.0
        let baseX = node.showsTitle && !node.isGroup ? 18.0 / width : 0.5
        // Position the native annotation itself, including its hit area. Moving
        // only the SwiftUI button leaves MapKit intercepting clicks at its old
        // geographic frame when labels are packed away from nearby markers.
        return UnitPoint(x: baseX - node.offsetX / width, y: 0.5 - node.offsetY / 44)
    }
    var body: some MapContent {
        ForEach(nodes) { node in
            Annotation("", coordinate: node.coordinate.mapCoordinate,
                       anchor: anchor(for: node)) {
                Button { activate(node) } label: {
                    HStack(spacing: 6) {
                        SpatialMarkerGlyph(assetID: node.members[0].assetID)
                        if node.isGroup {
                            Text("\(node.members.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        } else if node.showsTitle {
                            Text(node.title).font(.system(size: 12, weight: node.isSelected ? .semibold : .medium)).lineLimit(1)
                        }
                    }.foregroundStyle(node.isSelected ? Palette.accent : Palette.ink)
                        .frame(width: node.isGroup ? 60 : node.showsTitle ? 160 : 24, height: 30, alignment: node.showsTitle ? .leading : .center)
                        .padding(.horizontal, node.showsTitle ? 6 : 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(node.isSelected ? Palette.accent.opacity(0.8) : Palette.accent.opacity(0.18), lineWidth: node.isSelected ? 1.5 : 1))
                        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(ReadingQuietButtonStyle())
                    .help(node.isGroup ? "\(node.title) · \(node.members.count) 条，点此展开；仅为显示分组。" : node.title + " · " + node.members[0].subtitle)
                    .accessibilityLabel(node.isGroup ? "展开\(node.members.count)条相邻记录" : node.title + "，" + node.members[0].subtitle)
                    .accessibilityIdentifier(node.isGroup ? "spatial-marker-group" : "spatial-marker-" + node.members[0].id)
            }.annotationTitles(.hidden)
        }
    }
}

struct SpatialMarkerGroupCard: View {
    let members: [SpatialMarkerSeed]
    var select: (SpatialMarkerSeed) -> Void
    var zoom: () -> Void
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("相邻记录 · \(members.count)").font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: zoom) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 36, height: 36) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("放大这一组；同一地点的记录仍可从列表选择").accessibilityLabel("放大这一组")
                Button(action: close) { Image(systemName: "xmark").frame(width: 36, height: 36) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("关闭相邻记录").accessibilityLabel("关闭相邻记录")
            }.padding(.horizontal, 14).padding(.top, 5)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(members) { seed in
                        Button { select(seed) } label: {
                            HStack(spacing: 10) {
                                SpatialMarkerGlyph(assetID: seed.assetID)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(seed.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                    Text(seed.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(ReadingToolbarButtonStyle()).help("查看这条记录及其原文依据")
                    }
                }.padding(8)
            }
        }.frame(width: 330).frame(maxHeight: 350)
            .readingGlass(radius: 20).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .accessibilityIdentifier("spatial-marker-group-details")
    }
}

struct SpatialMarkerLegend: View {
    let seeds: [SpatialMarkerSeed]
    @State private var expanded = false
    private var assets: [SpatialMarkerAsset] {
        let used = Set(seeds.map(\.assetID)); return SpatialMarkerAssets.all.filter { used.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                Label("图例", systemImage: "square.grid.2x2").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 32)
            }.buttonStyle(ReadingQuietButtonStyle()).help("显示图标含义；图标仅提示内容，不增加史实分类")
                .accessibilityLabel("地图图例")
            if expanded {
                ForEach(assets) { asset in
                    HStack(spacing: 8) { SpatialMarkerGlyph(assetID: asset.id); Text(asset.title).font(.system(size: 12)) }
                        .padding(.horizontal, 10).frame(height: 28)
                }
            }
            if seeds.count > SpatialMarkerPacking.maximumMarkers {
                Text("先显示2,048条").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 5)
                    .help("地图记录较多，所选记录优先。缩小时间或查看范围可浏览其余记录；书中资料没有删除。")
            }
        }.padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .background(GeometryReader { geometry in Color.clear.preference(key: SpatialMarkerLegendSize.self, value: geometry.size) })
    }
}
struct SpatialMarkerLegendSize: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

func spatialMarkerLayout(seeds: [SpatialMarkerSeed], proxy: MapProxy, size: CGSize, selected: Set<String>, routeID: String?, showTitles: Bool) -> [SpatialMarkerNode]? {
    let admitted = SpatialMarkerPacking.boundedSeeds(seeds, selectedObjectIDs: selected, selectedRouteID: routeID)
    let screen = admitted.compactMap { seed -> SpatialMarkerScreenPoint? in
        guard let point = proxy.convert(seed.coordinate.mapCoordinate, to: .local) else { return nil }
        return .init(seed: seed, x: point.x, y: point.y)
    }
    // MapKit briefly cannot convert during camera/annotation replacement. A
    // missing transform is not a valid empty map and must not erase good nodes.
    guard size.width > 0, size.height > 0, seeds.isEmpty || !screen.isEmpty else { return nil }
    // Compositions cap their publication at 400 points and 128 routes; the
    // standalone map discloses the 2,048-marker display ceiling in its legend.
    // Keep its bounded annotations; MapKit virtualizes their visible views.
    // SwiftUI safe-area proposals and the native tile viewport can differ, so
    // independently deleting "offscreen" records here can lose visible data.
    return SpatialMarkerPacking.layout(screen, width: size.width, height: size.height,
        selectedObjectIDs: selected, selectedRouteID: routeID, showTitles: showTitles, retainOffscreen: true).nodes
}

func spatialMarkerGroupRegion(_ seeds: [SpatialMarkerSeed]) -> MKCoordinateRegion? {
    guard !seeds.isEmpty else { return nil }
    let lat = seeds.map(\.coordinate.latitude), lon = seeds.map(\.coordinate.longitude)
    let minLat = lat.min()!, maxLat = lat.max()!, minLon = lon.min()!, maxLon = lon.max()!
    return .init(center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                 span: .init(latitudeDelta: max(0.02, (maxLat - minLat) * 2), longitudeDelta: min(360, max(0.02, (maxLon - minLon) * 2))))
}
