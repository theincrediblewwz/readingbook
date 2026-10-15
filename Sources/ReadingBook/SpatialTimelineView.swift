import SwiftUI
import MapKit
import ReadingCore

private struct ReadingMapPoint: Identifiable {
    var id: String
    var targetID: String
    var title: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D
}

/// One floating time card over a full viewport map. Details stay below the
/// existing axis; changing a filter never inserts a second timeline.
struct SpatialTimelineView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: MapCameraPosition = .automatic
    @State private var showingEvents = false
    @State private var editingRange = false
    @State private var expandedEventID: String?
    @State private var inspectedObjectID: String?
    @State private var fromText = ""
    @State private var toText = ""
    @State private var rangeError = ""
    @State private var eventQuery = ""
    @State private var viewport = CGSize(width: 900, height: 650)

    private var filteredEvents: [KnowledgeEvent] {
        store.visibleEvents.filter { eventQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(eventQuery) || $0.dateText.localizedCaseInsensitiveContains(eventQuery) || $0.participantIDs.contains(where: { store.objectTitle($0).localizedCaseInsensitiveContains(eventQuery) }) }
    }
    private var expandedEvent: KnowledgeEvent? { store.book?.events.first { $0.id == expandedEventID } }
    private var expandedEventIsVisible: Bool {
        guard let expandedEventID else { return false }
        return store.visibleEvents.contains { $0.id == expandedEventID }
    }
    private var points: [ReadingMapPoint] {
        guard let book = store.book else { return [] }
        let places = Dictionary(uniqueKeysWithValues: book.entities.map { ($0.id, $0) })
        var result: [ReadingMapPoint] = []
        for event in store.visibleEvents {
            for id in event.placeIDs {
                if let place = places[id], let lat = place.latitude, let lon = place.longitude {
                    result.append(ReadingMapPoint(id: "\(event.id)|\(place.id)", targetID: event.id, title: event.name, subtitle: "\(event.dateText) · \(place.name)", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
                }
            }
        }
        if book.events.isEmpty {
            result = book.entities.compactMap { place in
                guard let lat = place.latitude, let lon = place.longitude else { return nil }
                return ReadingMapPoint(id: place.id, targetID: place.id, title: place.name, subtitle: place.locationNote ?? "书中地点", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        return result
    }
    private var bounds: ClosedRange<Double> {
        let years = store.book?.events.flatMap { [$0.startYear, $0.endYear].compactMap { $0 } } ?? []
        guard let first = years.min(), let last = years.max() else { return -5000...3000 }
        return (Double(first) - 5)...(Double(last) + 5)
    }
    private var panelWidth: CGFloat { min(560, max(0, viewport.width - 88)) }
    private var detailHeight: CGFloat { min(260, max(120, viewport.height * 0.35)) }

    var body: some View {
        GeometryReader { geometry in
            Map(position: $camera) {
                ForEach(points) { point in
                    Annotation("", coordinate: point.coordinate) { mapMarker(point) }
                }
            }
            .mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
            .overlay(alignment: .topLeading) {
                timelineCard.frame(width: min(560, max(0, geometry.size.width - 88))).padding(16)
            }
            .onAppear { viewport = geometry.size }
            .onChange(of: geometry.size) { _, next in viewport = next }
        }
        .onAppear {
            normalizeRange()
            if let id = store.selectedObjectID, store.book?.events.contains(where: { $0.id == id }) == true { expandedEventID = id }
        }
        .popover(isPresented: Binding(get: { inspectedObjectID != nil }, set: { if !$0 { inspectedObjectID = nil } })) {
            if let id = inspectedObjectID { ObjectInspector(id: id, onClose: { inspectedObjectID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }
        .onChange(of: store.selectedObjectID) { _, id in
            guard let id else { return }
            if store.book?.events.contains(where: { $0.id == id }) == true { expand(id) }
            locate(id)
        }
        .onChange(of: store.bookID) { _, _ in
            normalizeRange(); showingEvents = false; editingRange = false; eventQuery = ""; expandedEventID = nil; inspectedObjectID = nil; camera = .automatic
        }
        .onChange(of: store.book?.events.map(\.id) ?? []) { _, ids in
            if let id = expandedEventID, !ids.contains(id) { expandedEventID = nil }
        }
        .onChange(of: bounds) { previous, _ in
            if store.timeFrom == previous.lowerBound, store.timeTo == previous.upperBound { fitTime() }
            else { normalizeRange() }
        }
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("时间与地图", systemImage: "map").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button { showingEvents.toggle() } label: {
                    Label("事件 \(store.visibleEvents.count)", systemImage: "list.bullet")
                }.buttonStyle(ReadingToolbarButtonStyle(selected: showingEvents))
                    .help("浏览当前时间范围的事件").popover(isPresented: $showingEvents) { eventList }
                Menu {
                    Toggle("保留时间待考事件", isOn: $store.showUndated)
                    Button("地图适合全部标记") { camera = .automatic }
                    Button("显示全部时间") { fitTime() }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").frame(width: 36, height: 36).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).fixedSize().help("时间与地图选项").accessibilityLabel("时间与地图选项")
            }
            HStack(spacing: 6) {
                Button {
                    fromText = String(Int(store.timeFrom)); toText = String(Int(store.timeTo)); rangeError = ""; editingRange = true
                } label: {
                    HStack(spacing: 5) {
                        Text("\(TimelineRangeControl.yearLabel(Int(store.timeFrom))) — \(TimelineRangeControl.yearLabel(Int(store.timeTo)))")
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                }.buttonStyle(ReadingToolbarButtonStyle(selected: editingRange)).help("输入精确起止年份")
                    .popover(isPresented: $editingRange) { rangeEditor }
                Spacer(minLength: 0)
                Button("全部") { fitTime() }.buttonStyle(ReadingToolbarButtonStyle()).help("显示全部时间")
            }
            TimelineRangeControl(lower: $store.timeFrom, upper: $store.timeTo, bounds: bounds,
                                 events: store.book?.events ?? [], selectedID: store.selectedObjectID, select: selectEvent)
                .id(store.bookID)
            if let event = expandedEvent {
                Divider().opacity(0.5)
                // Keep this region's height stable when filtering the selected
                // event out, so a held endpoint never shifts under the pointer.
                eventDetails(event).frame(height: detailHeight).transition(.opacity)
            } else {
                Text(points.isEmpty
                     ? (store.visibleEvents.isEmpty ? "当前范围没有事件；可调整端点或显示全部时间。" : "暂无可定位坐标，事件详情仍可从清单阅读。")
                     : "\(points.count) 个地图标记 · 点事件查看详情")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: 18, alignment: .leading)
                    .padding(.horizontal, 7).padding(.bottom, 3)
            }
        }.padding(12).readingGlass(radius: 22)
    }

    private func eventDetails(_ event: KnowledgeEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.name).font(.system(size: 17, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text(event.dateText).font(.subheadline).foregroundStyle(Palette.copper).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { collapseDetails() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("收起事件详情，保留时间范围").accessibilityLabel("收起事件详情")
            }.padding(.horizontal, 5)
            if expandedEventIsVisible {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !event.placeIDs.isEmpty { objectLinks(event.placeIDs, title: "地点", symbol: "mappin.and.ellipse") }
                        else { Label("地点尚未登记", systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary) }
                        if !event.participantIDs.isEmpty { objectLinks(event.participantIDs, title: "参与者", symbol: "person.2") }
                        if !event.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { MarkdownText(markdown: event.summary) }
                        if !event.placeIDs.isEmpty, !points.contains(where: { $0.targetID == event.id }) {
                            Text("此事件还没有可定位的地点坐标；详情与原文依据仍可阅读。").font(.caption).foregroundStyle(.secondary)
                        }
                        EvidenceList(evidence: event.evidence)
                        if event.evidence.isEmpty { Text("暂未登记原文依据").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 5).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
                }.id(event.id)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("此事件不在当前时间范围内", systemImage: "line.3.horizontal.decrease.circle").font(.subheadline.weight(.medium))
                    Text("当前筛选不包含这条事件。可重新显示它，或继续调整时间范围。").font(.caption).foregroundStyle(.secondary)
                    Button("显示并定位此事件") { selectEvent(event.id) }.buttonStyle(ReadingToolbarButtonStyle())
                }.padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
    private func objectLinks(_ ids: [String], title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    Button { store.focus(id); inspectedObjectID = id } label: {
                        HStack(spacing: 5) {
                            Text(store.objectTitle(id)).lineLimit(2)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 10))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(ReadingToolbarButtonStyle()).foregroundStyle(Palette.accent)
                }
            }
        }
    }
    private func mapMarker(_ point: ReadingMapPoint) -> some View {
        let selected = store.selectedObjectID == point.targetID
        return Button { selectEvent(point.targetID) } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? "flag.fill" : "circle.fill").font(.system(size: selected ? 14 : 9))
                    .foregroundStyle(selected ? Palette.surface : Palette.accent)
                    .frame(width: selected ? 32 : 22, height: selected ? 32 : 22)
                    .background(selected ? Palette.accent : Palette.surface, in: Circle())
                    .overlay(Circle().stroke(Palette.accent.opacity(0.5), lineWidth: 1))
                if selected { Text(point.title).font(.caption.weight(.semibold)).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 4).background(Palette.surface, in: Capsule()) }
            }.frame(minWidth: 36, minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(point.title) · \(point.subtitle)").accessibilityLabel("\(point.title)，\(point.subtitle)")
    }

    private var rangeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("精确时间范围").font(.headline)
            Text("公元前年份输入负数。两个端点也可在轴上拖动或用方向键调整。").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("起点", text: $fromText).textFieldStyle(.roundedBorder)
                Text("至").foregroundStyle(.secondary)
                TextField("终点", text: $toText).textFieldStyle(.roundedBorder)
            }
            if !rangeError.isEmpty { Text(rangeError).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { editingRange = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用") {
                    guard let from = Int(fromText.trimmingCharacters(in: .whitespaces)), let to = Int(toText.trimmingCharacters(in: .whitespaces)),
                          from <= to, bounds.contains(Double(from)), bounds.contains(Double(to)) else {
                        rangeError = "请输入轴内年份，并让起点不晚于终点。"; return
                    }
                    store.timeFrom = Double(from); store.timeTo = Double(to); editingRange = false
                }.keyboardShortcut(.defaultAction)
            }.buttonStyle(ReadingToolbarButtonStyle())
        }.padding(18).frame(width: 320)
    }
    private var eventList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前范围的事件").font(.headline)
                Spacer()
                Button { showingEvents = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("关闭事件清单").accessibilityLabel("关闭事件清单")
            }
            TextField("查找事件、时间或参与者", text: $eventQuery).textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredEvents) { event in
                            Button { selectEvent(event.id); showingEvents = false } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Circle().fill(store.selectedObjectID == event.id ? Palette.copper : Palette.accent.opacity(0.4)).frame(width: 7, height: 7).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(event.name).font(.subheadline.weight(.medium))
                                        Text(event.dateText).font(.caption).foregroundStyle(.secondary)
                                        if !event.participantIDs.isEmpty { Text(event.participantIDs.map { store.objectTitle($0) }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .background(store.selectedObjectID == event.id ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(event.id)
                        }
                        if store.visibleEvents.isEmpty { Text("当前范围没有事件。调整端点或显示全部时间。").font(.caption).foregroundStyle(.secondary).padding(16) }
                        else if filteredEvents.isEmpty { Text("没有匹配的事件。请调整搜索词。").font(.caption).foregroundStyle(.secondary).padding(16) }
                    }.frame(maxWidth: .infinity)
                }.onAppear { if let id = store.selectedObjectID { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: store.selectedObjectID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }.padding(14).frame(width: 350, height: 400)
    }

    private func normalizeRange() {
        store.timeFrom = min(bounds.upperBound, max(bounds.lowerBound, store.timeFrom))
        store.timeTo = max(store.timeFrom, min(bounds.upperBound, max(bounds.lowerBound, store.timeTo)))
    }
    private func expand(_ id: String) {
        if expandedEventID == nil {
            withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { expandedEventID = id }
        } else { expandedEventID = id }
    }
    private func collapseDetails() {
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { expandedEventID = nil }
    }
    private func selectEvent(_ id: String) {
        if let event = store.book?.events.first(where: { $0.id == id }) {
            if event.startYear == nil { store.showUndated = true }
            store.focus(id); expand(id)
        } else { store.focus(id); inspectedObjectID = id }
        // Repeat even for the same selected ID, whose onChange will not fire.
        locate(id)
    }
    private func locate(_ id: String) {
        guard let point = points.first(where: { $0.targetID == id }) else { return }
        // Leave the point in the open map area rather than underneath the card.
        let span = MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
        var center = point.coordinate
        if viewport.width - panelWidth - 32 >= 240 {
            center.longitude -= min(1.45, Double((panelWidth + 32) / max(1, viewport.width)) * span.longitudeDelta / 2)
        } else {
            let panelHeight: CGFloat = 178 + (expandedEvent == nil ? 0 : detailHeight + 9)
            center.latitude += min(1.6, Double(panelHeight / max(1, viewport.height)) * span.latitudeDelta / 2)
        }
        center.latitude = min(85, max(-85, center.latitude))
        if center.longitude < -180 { center.longitude += 360 }
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
    private func fitTime() { store.timeFrom = bounds.lowerBound; store.timeTo = bounds.upperBound }
}

