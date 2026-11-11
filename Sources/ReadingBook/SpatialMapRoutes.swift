import SwiftUI
import MapKit
import ReadingCore

/// One renderer for standalone and composed maps. Routes retain canonical IDs.
struct SpatialMapRoutes: MapContent {
    let routes: [SpatialRoute]
    @Binding var inspected: SpatialRoute?
    var selectEvent: (String) -> Void
    var showsMarkers = true
    var body: some MapContent {
        ForEach(routes) { route in
            let color = routeColor(route)
            MapPolyline(coordinates: route.coordinates.map(\.mapCoordinate))
                .stroke(color.opacity(route.isUncertain ? 0.65 : 0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: route.isUncertain ? [7, 5] : []))
            MapPolygon(coordinates: SpatialRouteGeometry.arrowhead(route.coordinates).map(\.mapCoordinate)).foregroundStyle(color)
            if showsMarkers, let anchor = route.coordinates.dropFirst().first {
                Annotation("", coordinate: anchor.mapCoordinate, anchor: .bottom) {
                    Button {
                        inspected = route
                        if let id = route.eventID { selectEvent(id) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right")
                            if routes.count <= 12 || inspected?.id == route.id { Text(route.title).lineLimit(1) }
                        }.font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(color.opacity(0.2)))
                    }.buttonStyle(ReadingQuietButtonStyle())
                        .help(route.actorNames.joined(separator: "、") + " · " + (route.isUncertain ? "推断或时间待考，点此看依据" : "方向示意，点此看依据"))
                }.annotationTitles(.hidden)
            }
        }
    }
    private func routeColor(_ route: SpatialRoute) -> Color {
        let key = route.actorIDs.first ?? route.relationID
        let index = key.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff } % 5
        return [Palette.accent, Palette.copper, Color.teal, Color.purple, Color.indigo][index]
    }
}
extension SpatialCoordinate {
    var mapCoordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct SpatialRouteDetails: View {
    @EnvironmentObject private var store: AppStore
    let route: SpatialRoute
    var embedded = false
    @ViewBuilder var body: some View {
        if embedded { content }
        else { ScrollView { content }.frame(width: 380).frame(maxHeight: 520) }
    }
    private var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(route.title).font(.system(size: 18, weight: .semibold))
                if !route.actorNames.isEmpty { Text(route.actorNames.joined(separator: "、")).foregroundStyle(Palette.accent) }
                Text(route.placeNames.joined(separator: " → ")).font(.system(size: 15, weight: .medium))
                Text(route.assertion == .explicit ? "原文记载的行动 · 方向示意" : "推断的行动路线 · 方向示意").font(.caption).foregroundStyle(.secondary)
                if !route.extent.sourceText.isEmpty { Text(route.extent.sourceText).font(.subheadline) }
                if route.timeMatch == .unknown {
                    Text("这条路线的时间尚不能与所选时间比较，保留虚线供核对，不代表发生在这个区间。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if route.extent.assertion == .inferred || route.timeMatch == .possible {
                    Text("时间为推算或待考：" + (route.extent.explanation ?? route.explanation)).font(.caption).foregroundStyle(.secondary)
                }
                if !route.explanation.isEmpty { Text(route.explanation).font(.subheadline) }
                ForEach(Array(route.evidence.prefix(8).enumerated()), id: \.offset) { _, evidence in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(evidence.quote).font(.subheadline).lineLimit(5)
                        Button { store.follow(evidence) } label: {
                            Label("回到原文", systemImage: "book").frame(minHeight: 38)
                        }.buttonStyle(ReadingToolbarButtonStyle()).help("定位到这条行动的原文出处")
                    }
                }
                Divider()
                Text(Array(Set(route.locationNotes)).sorted().joined(separator: "；") + "。连线只表示行动方向，不表示精确古道、河道或战场边界。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(embedded ? 0 : 20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared by standalone and composed maps; uncertainty stays discoverable
/// without adding another permanent explanatory paragraph to the canvas.
struct SpatialRouteTimeNotice: View {
    let routes: [SpatialRoute]
    @State private var showingDetails = false
    var body: some View {
        let count = routes.filter { $0.timeMatch == .unknown }.count
        if count > 0 {
            Button { showingDetails.toggle() } label: {
                Label("时间待定 \(count)", systemImage: "clock.badge.questionmark")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
            }.buttonStyle(ReadingQuietButtonStyle()).padding(12)
                .help("这些虚线路线的时间未定，或与当前时间轴不可比较；点击查看说明")
                .popover(isPresented: $showingDetails) {
                    Text("保留这些路线供你核对；它们不代表已落在所选时间内。只有先后顺序、日期未明或历法不同的记录都可能出现在这里。点击路线可查看原文依据。")
                        .font(.subheadline).padding(18).frame(width: 290)
                }
        }
    }
}
