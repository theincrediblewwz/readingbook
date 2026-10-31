import SwiftUI
import MapKit
import ReadingCore

private struct ReadingMapPoint: Identifiable, Equatable {
    var id: String
    var targetID: String
    var title: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.targetID.utf8.elementsEqual(rhs.targetID.utf8)
            && lhs.title.utf8.elementsEqual(rhs.title.utf8) && lhs.subtitle.utf8.elementsEqual(rhs.subtitle.utf8)
            && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// One floating time card over a full viewport map. Details stay below the
/// existing axis; changing a filter never inserts a second timeline.
struct SpatialTimelineView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    @State private var camera: MapCameraPosition = .automatic
    @State private var mapSelection: ReadingMapSelection?
    @State private var showingEvents = false
    @State private var editingRange = false
    @State private var expandedEventID: String?
    @State private var inspectedObjectID: String?
    @State private var fromText = ""
    @State private var toText = ""
    @State private var rangeError = ""
    @State private var eventQuery = ""
    @State private var showsTimeline = true
    @State private var timelineCollapsed = false
    @State private var viewport = CGSize(width: 900, height: 650)
    @AppStorage("readingbook.timelinePanelDock") private var dockRaw = FloatingPanelDock.bottomLeading.rawValue
    @State private var measuredPanelSize = CGSize(width: 740, height: 214)
    @State private var personFrame = CGRect.zero
    @State private var dragOrigin: CGPoint?
    @State private var dragCenter: CGPoint?
    @State private var pointerEpoch = 0
    @State private var memoryScope: String?
    @State private var selectionLayoutToken: UUID?
    @State private var showsPerson = true
    @State private var showsFootprintSequence = false
    @State private var mapMemorySaveTask: Task<Void, Never>?

    private var temporalMode: Bool { store.temporalAxis != "legacy" }
    private var visibleEvents: [KnowledgeEvent] {
        guard let book = store.book else { return [] }
        // A snapshot can traverse all temporal records. Resolve it once, rather
        // than once per event while a reader drags the current-time pointer.
        let snapshots = store.temporalEvents
        let byID = Dictionary(snapshots.map { ($0.object.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scoped = (store.readingScopeCurrent ? store.readingContextItems.events : book.events).compactMap { event -> KnowledgeEvent? in
            guard let object = byID[event.id]?.object else { return nil }
            var safe = event; safe.summary = object.summary
            safe.participantIDs = object.references["participants"] ?? []; safe.placeIDs = object.references["places"] ?? []
            return safe
        }
        if !temporalMode { return scoped.filter { event in
            guard let year = event.startYear else { return store.showUndated }
            return Double(event.endYear ?? year) >= store.timeFrom && Double(year) <= store.timeTo
        } }
        return scoped.filter { event in
            guard let item = byID[event.id] else { return false }
            if store.selectedTemporalEntityID != nil { return item.match == .matches }
            let start = axisValue(item.extent), end = axisEnd(item.extent)
            guard let start else { return store.showUndated }
            return (end ?? start) >= store.timeFrom && start <= store.timeTo
        }
    }
    private var axisEvents: [KnowledgeEvent] {
        guard temporalMode else {
            let ids = Set(store.temporalEvents.map(\.object.id))
            return (store.readingScopeCurrent ? store.readingContextItems.events : (store.book?.events ?? [])).filter { ids.contains($0.id) }
        }
        let eventsByID = Dictionary((store.book?.events ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.temporalEvents.compactMap { item in
            guard var event = eventsByID[item.object.id], let value = axisValue(item.extent) else { return nil }
            event.startYear = Int(value); event.endYear = axisEnd(item.extent).map(Int.init); return event
        }
    }
    private func axisValue(_ extent: TemporalExtent) -> Double? {
        if store.temporalAxis == "narrative" { return extent.narrativeStart.map(Double.init) }
        guard store.temporalAxis == "calendar:" + (extent.calendar ?? "") else { return nil }
        return extent.start.map { Double($0.year) }
    }
    private func axisEnd(_ extent: TemporalExtent) -> Double? {
        if store.temporalAxis == "narrative" { return extent.narrativeEnd.map(Double.init) }
        guard store.temporalAxis == "calendar:" + (extent.calendar ?? "") else { return nil }
        return extent.end.map { Double($0.year) }
    }
    private func axisLabel(_ value: Double) -> String {
        store.temporalAxis == "narrative" ? "叙事 \(Int(value))" : TimelineRangeControl.yearLabel(Int(value))
    }

    private var filteredEvents: [KnowledgeEvent] {
        visibleEvents.filter { eventQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(eventQuery) || $0.dateText.localizedCaseInsensitiveContains(eventQuery) || $0.participantIDs.contains(where: { store.objectTitle($0).localizedCaseInsensitiveContains(eventQuery) }) }
    }
    private var expandedEvent: KnowledgeEvent? {
        guard let book = store.book, var event = book.events.first(where: { $0.id == expandedEventID }),
              let object = try? TemporalKnowledgeRuntime.object(id: event.id, in: book, boundary: store.temporalBoundary) else { return nil }
        event.summary = object.summary; event.participantIDs = object.references["participants"] ?? []; event.placeIDs = object.references["places"] ?? []
        return event
    }
    private var admittedEntities: [KnowledgeEntity] {
        guard let book = store.book else { return [] }
        let ids = Set(((try? TemporalKnowledgeRuntime.objects(in: book, boundary: store.temporalBoundary)) ?? []).filter { $0.kind == .entity }.map(\.id))
        return book.entities.filter { ids.contains($0.id) }
    }
    private var expandedEventIsVisible: Bool {
        guard let expandedEventID else { return false }
        return visibleEvents.contains { $0.id == expandedEventID }
    }
    private var points: [ReadingMapPoint] {
        guard let book = store.book else { return [] }
        let places = Dictionary(uniqueKeysWithValues: book.entities.map { ($0.id, $0) })
        if temporalMode, let id = store.selectedTemporalEntityID {
            return (store.temporalSnapshot(id)?.footprints ?? []).compactMap { presence in
                guard let placeID = presence.placeID, let place = places[placeID], let lat = place.latitude, let lon = place.longitude else { return nil }
                return ReadingMapPoint(id: presence.id, targetID: presence.eventID ?? id, title: store.objectTitle(id), subtitle: presence.action + " · " + place.name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        var result: [ReadingMapPoint] = []
        for event in visibleEvents {
            for id in event.placeIDs {
                if let place = places[id], let lat = place.latitude, let lon = place.longitude {
                    result.append(ReadingMapPoint(id: "\(event.id)|\(place.id)", targetID: event.id, title: event.name, subtitle: "\(event.dateText) · \(place.name)", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
                }
            }
        }
        if book.events.isEmpty {
            let admitted = Set(admittedEntities.map(\.id))
            result = (store.readingScopeCurrent ? store.readingContextItems.entities : book.entities).filter { admitted.contains($0.id) }.compactMap { place in
                guard let lat = place.latitude, let lon = place.longitude else { return nil }
                return ReadingMapPoint(id: place.id, targetID: place.id, title: place.name, subtitle: place.locationNote ?? "书中地点", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        return result
    }
    private var bounds: ClosedRange<Double> {
        if temporalMode {
            let extents = store.availableTemporalExtents
            let values = extents.flatMap { [axisValue($0), axisEnd($0)].compactMap { $0 } }
            if let first = values.min(), let last = values.max() { return (first - 1)...(last + 1) }
            return 0...1
        }
        let years = axisEvents.flatMap { [$0.startYear, $0.endYear].compactMap { $0 } }
        guard let first = years.min(), let last = years.max() else { return -5000...3000 }
        return (Double(first) - 5)...(Double(last) + 5)
    }
    private var footprintSequence: [CLLocationCoordinate2D] {
        guard showsFootprintSequence, temporalMode, let book = store.book, let id = store.selectedTemporalEntityID,
              let snapshot = try? TemporalKnowledgeRuntime.entitySnapshot(entityID: id, in: book, boundary: store.temporalBoundary) else { return [] }
        let candidates = snapshot.footprints.filter { item in
            guard let value = axisValue(item.extent) else { return false }
            return item.extent.uncertainty == .exact && item.extent.kind == .point && value >= store.timeFrom && value <= min(store.timeCursor, store.timeTo)
        }
        // The visible axis is year/narrative precision. Tied or uncertain times
        // do not establish an order, so never invent a segment between them.
        let grouped = Dictionary(grouping: candidates, by: { axisValue($0.extent) ?? 0 })
        let ordered = candidates.filter { grouped[axisValue($0.extent) ?? 0]?.count == 1 }
            .sorted { (axisValue($0.extent) ?? 0) < (axisValue($1.extent) ?? 0) }
        guard !ordered.isEmpty else { return [] }
        let entitiesByID = Dictionary(book.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { item in
            guard let id = item.placeID, let place = entitiesByID[id], let lat = place.latitude, let lon = place.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
    // Keep distinct upper-corner targets even while reserving MapKit's controls.
    private var topReserve: CGFloat { 96 }
    private var workingViewport: CGSize { CGSize(width: viewport.width, height: max(0, viewport.height - topReserve)) }
    private var panelWidth: CGFloat { min(timelineCollapsed ? 480 : 740, max(0, viewport.width - 144)) }
    private let timelineHeaderHeight: CGFloat = 56
    private var detailHeight: CGFloat { min(220, max(210, viewport.height * 0.24)) }
    private var dock: FloatingPanelDock { FloatingPanelDock(rawValue: dockRaw) ?? .bottomLeading }
    private var maximumTimelineHeight: CGFloat {
        let viewportLimit = max(timelineHeaderHeight, workingViewport.height - 48)
        guard viewport.width < 1050, showsPerson, store.selectedTemporalEntityID != nil else { return viewportLimit }
        // Keep a scrollable person card above a bottom dock or below a top
        // dock. Only presentation height changes; the saved dock stays intact.
        let reserve: CGFloat = dock == .topLeading || dock == .topTrailing ? 296 : 272
        return min(viewportLimit, max(timelineHeaderHeight, viewport.height - reserve))
    }
    private var panelSize: CGSize {
        CGSize(width: panelWidth, height: timelineCollapsed ? timelineHeaderHeight : min(max(timelineHeaderHeight, measuredPanelSize.height), maximumTimelineHeight))
    }
    private func dockFrame(_ position: FloatingPanelDock) -> CGRect {
        let frame = FloatingPanelGeometry.frame(at: position, viewport: workingViewport, panel: panelSize, margin: 24).offsetBy(dx: 0, dy: topReserve)
        return frame
    }
    private func clampedPanelCenter(_ center: CGPoint) -> CGPoint {
        let local = FloatingPanelGeometry.clampedCenter(CGPoint(x: center.x, y: center.y - topReserve), viewport: workingViewport, panel: panelSize, margin: 24)
        return CGPoint(x: local.x, y: local.y + topReserve)
    }
    private var panelFrame: CGRect {
        if let dragCenter {
            let center = clampedPanelCenter(dragCenter)
            return CGRect(x: center.x - panelSize.width / 2, y: center.y - panelSize.height / 2, width: panelSize.width, height: panelSize.height)
        }
        return dockFrame(dock)
    }
    private var timelineRestoreFrame: CGRect { CGRect(x: max(24, viewport.width / 2 - 122), y: max(topReserve + 12, viewport.height - 76), width: 244, height: 52) }
    private var settledTimelineFrame: CGRect { showsTimeline ? dockFrame(dock) : timelineRestoreFrame }
    private var mapControlsFrame: CGRect { CGRect(x: max(0, viewport.width - 70), y: 88, width: 56, height: 150) }
    private func chromeFrames(in geometry: GeometryProxy) -> [String: CGRect] {
        let origin = geometry.frame(in: .global).origin
        var frames = ["map-timeline": settledTimelineFrame.offsetBy(dx: origin.x, dy: origin.y),
                      "map-controls": mapControlsFrame.offsetBy(dx: origin.x, dy: origin.y)]
        if store.selectedTemporalEntityID != nil, !personFrame.isEmpty {
            frames["map-person"] = personFrame.offsetBy(dx: origin.x, dy: origin.y)
        }
        return frames
    }

    private var mapWorkspace: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                bookMap
                if let id = store.selectedTemporalEntityID {
                    ReaderFloatingPanel(title: store.objectTitle(id), icon: "person.crop.rectangle", width: 340, height: 490,
                        isPresented: $showsPerson, viewport: geometry.size, memoryIDOverride: "map.person", bottomReserve: 24,
                        avoidRects: [settledTimelineFrame, mapControlsFrame], restoreNearTop: true,
                        onFrameChange: { frame in if personFrame != frame { personFrame = frame } }) {
                        TemporalPersonContents(entityID: id)
                    }
                }
                if showsTimeline {
                timelineCard.frame(width: panelWidth, height: panelSize.height, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .position(x: panelFrame.midX, y: panelFrame.midY)
                    .onPreferenceChange(TimelinePanelSizeKey.self) { next in
                        guard next.width > 0, next.height > 0,
                              abs(next.height - measuredPanelSize.height) > 0.5 || abs(next.width - measuredPanelSize.width) > 0.5 else { return }
                        cancelPanelDrag()
                        measuredPanelSize = next
                    }
                    .transition(.opacity)
                } else {
                    ReadingDockSurface {
                        Button { restoreTimeline() } label: { Label("时间轴", systemImage: "clock").frame(minHeight: 44) }
                            .buttonStyle(ReadingToolbarButtonStyle()).help("显示时间轴与事件")
                        DockDivider()
                        DockIconButton(title: "显示全部地图标记", icon: "arrow.up.left.and.arrow.down.right") { camera = .automatic }
                    }.frame(width: timelineRestoreFrame.width, height: timelineRestoreFrame.height)
                        .position(x: timelineRestoreFrame.midX, y: timelineRestoreFrame.midY).transition(.opacity)
                }
            }
            // Only settled rectangles are shared. Dragging the time card does
            // not make the person card or the global progress follow each frame.
            .preference(key: WorkspaceChromeBoundsPreference.self, value: chromeFrames(in: geometry))
            .onAppear {
                viewport = geometry.size
                if geometry.size.width < 900 || geometry.size.height < 700 { timelineCollapsed = true }
            }
            .onChange(of: geometry.size) { old, next in
                cancelPanelDrag(); viewport = next
                if (old.width >= 900 && next.width < 900) || (old.height >= 700 && next.height < 700) {
                    withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { timelineCollapsed = true }
                }
            }
        }
    }

    private var observedWorkspace: some View {
        mapWorkspace.onAppear {
            if FloatingPanelDock(rawValue: dockRaw) == nil { dockRaw = FloatingPanelDock.bottomLeading.rawValue }
            normalizeRange()
            restoreMapMemory()
            if let id = store.selectedObjectID, store.book?.events.contains(where: { $0.id == id }) == true { expandedEventID = id }
        }
        .onDisappear { selectionLayoutToken = nil; saveMapPanelMemory(); cancelPanelDrag() }
        .onChange(of: store.workspaceMemoryRevision) { _, _ in restoreMapMemory() }
        .onChange(of: showsTimeline) { _, _ in saveMapPanelMemory() }
        .onChange(of: timelineCollapsed) { _, _ in saveMapPanelMemory() }
        .onChange(of: store.timeFrom) { _, _ in clampCursor(); scheduleMapPanelMemory() }
        .onChange(of: store.timeTo) { _, _ in clampCursor(); scheduleMapPanelMemory() }
        .onChange(of: store.timeCursor) { _, _ in scheduleMapPanelMemory() }
        .onChange(of: store.temporalAxis) { _, _ in saveMapPanelMemory() }
        .onChange(of: store.selectedTemporalEntityID) { _, id in if id != nil { showsPerson = true }; saveMapPanelMemory() }
        .onChange(of: store.showUndated) { _, _ in saveMapPanelMemory() }
    }

    var body: some View {
        observedWorkspace
        .onChange(of: store.workspaceAICommand) { _, command in handleViewCommand(command) }
        .onExitCommand { cancelPanelDrag() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ReadingBookCaptureWorkspaceMemory"))) { _ in saveMapPanelMemory() }
        .onChange(of: measuredPanelSize) { _, _ in
            // Only settle a newly selected event's expanding detail card.
            // Resizing or moving chrome after manual navigation preserves the map.
            if selectionLayoutToken != nil, !camera.positionedByUser, let id = store.selectedObjectID { locate(id) }
        }
        .onChange(of: dockRaw) { _, _ in saveMapPanelMemory() }
        .popover(isPresented: Binding(get: { inspectedObjectID != nil }, set: { if !$0 { inspectedObjectID = nil } })) {
            if let id = inspectedObjectID { ObjectInspector(id: id, onClose: { inspectedObjectID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }
        .onChange(of: store.selectedObjectID) { _, id in handleObjectSelection(id) }
        .onChange(of: store.selectedUnitID) { _, _ in
            if let id = store.selectedTemporalEntityID, !admittedEntities.contains(where: { $0.id == id }) { store.selectedTemporalEntityID = nil }
        }
        .onChange(of: store.bookID) { _, _ in
            cancelPanelDrag()
            selectionLayoutToken = nil
            normalizeRange(); showingEvents = false; editingRange = false; eventQuery = ""; expandedEventID = nil; inspectedObjectID = nil; camera = .automatic; showsTimeline = true; timelineCollapsed = false
        }
        .onChange(of: store.book?.events.map(\.id) ?? []) { _, ids in
            if let id = expandedEventID, !ids.contains(id) { expandedEventID = nil }
        }
        .onChange(of: bounds) { previous, _ in
            if store.timeFrom == previous.lowerBound, store.timeTo == previous.upperBound { fitTime() }
            else { normalizeRange() }
        }
    }

    private func handleObjectSelection(_ selectedID: String?) {
        guard let id = selectedID else { return }
        if store.book?.events.contains(where: { $0.id == id }) == true {
            expand(id)
        } else if let entity = admittedEntities.first(where: { $0.id == id }),
                  entity.latitude == nil, entity.longitude == nil {
            store.selectedTemporalEntityID = id
            showsPerson = true
            if store.temporalAxis == "legacy" {
                if let calendar = store.temporalCalendars.first { selectAxis("calendar:" + calendar) }
                else if store.hasNarrativeTime { selectAxis("narrative") }
            }
        }
        locateSelection(id)
    }

    private var mapScope: ReadingMapScope {
        ReadingMapScope(root: store.libraryRootURL, key: store.workspaceMemoryKey)
    }
    private var bookMap: some View {
        let expectedKey = store.workspaceMemoryKey
        let expectedRoot = store.libraryRootURL
        return ReadingMapRenderer(points: points, sequence: footprintSequence,
                                  selectedID: store.selectedObjectID, scope: mapScope,
                                  cameraValue: camera, camera: $camera, selection: $mapSelection)
        .equatable()
        .onChange(of: mapSelection) { _, value in
            guard let value, value.scope == mapScope else { return }
            selectEvent(value.targetID)
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let region = context.region
            let saved = WorkspaceMapMemory(latitude: region.center.latitude, longitude: region.center.longitude, latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta)
            guard memoryScope == expectedKey, store.libraryRootURL == expectedRoot, saved.isValid else { return }
            store.updateWorkspaceMemory({ $0.map = saved }, expectedKey: expectedKey)
        }
        .safeAreaPadding(.top, topReserve).safeAreaPadding(.trailing, 16)
    }
    private func restoreMapMemory() {
        selectionLayoutToken = nil
        memoryScope = store.workspaceMemoryKey
        let saved = store.workspaceMemory
        if let map = saved.map, map.isValid {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: map.latitude, longitude: map.longitude), span: MKCoordinateSpan(latitudeDelta: map.latitudeDelta, longitudeDelta: map.longitudeDelta)))
        } else { camera = .automatic }
        let panel = saved.panels["map.timeline"]
        showsTimeline = panel?.isPresented ?? true; timelineCollapsed = panel?.collapsed ?? (viewport.width < 900 || viewport.height < 700)
        dockRaw = saved.timelineDock.flatMap { FloatingPanelDock(rawValue: $0)?.rawValue } ?? FloatingPanelDock.bottomLeading.rawValue
        store.temporalAxis = saved.temporalAxis ?? "legacy"
        store.timeCursor = saved.timeCursor ?? store.timeFrom
        store.selectedTemporalEntityID = saved.temporalEntityID.flatMap { id in store.book?.entities.contains(where: { $0.id == id }) == true ? id : nil }
    }
    private func saveMapPanelMemory() {
        mapMemorySaveTask?.cancel(); mapMemorySaveTask = nil
        guard let memoryScope else { return }
        store.updateWorkspaceMemory({ memory in
            memory.panels["map.timeline"] = WorkspacePanelMemory(isPresented: showsTimeline, collapsed: timelineCollapsed)
            memory.timelineDock = dockRaw; memory.timeFrom = store.timeFrom; memory.timeTo = store.timeTo; memory.showUndated = store.showUndated
            memory.temporalAxis = store.temporalAxis; memory.timeCursor = store.timeCursor; memory.temporalEntityID = store.selectedTemporalEntityID
        }, expectedKey: memoryScope)
    }

    private func clampCursor() {
        let next = min(store.timeTo, max(store.timeFrom, store.timeCursor))
        if next != store.timeCursor { store.timeCursor = next }
    }
    private func scheduleMapPanelMemory() {
        mapMemorySaveTask?.cancel()
        let expectedKey = store.workspaceMemoryKey
        mapMemorySaveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard !Task.isCancelled, expectedKey == store.workspaceMemoryKey, memoryScope == expectedKey else { return }
            saveMapPanelMemory()
        }
    }
    @ViewBuilder private var timelineCard: some View {
        if timelineCollapsed {
            ReadingDockSurface { timelineHeader.frame(width: max(0, panelWidth - 12)) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Keep dismissal in the draggable title, outside the body scroll.
                timelineHeader.padding(.horizontal, 12).frame(height: timelineHeaderHeight)
                ScrollView {
                    timelineContents.fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                        .background {
                            GeometryReader { contents in
                                Color.clear.preference(key: TimelinePanelSizeKey.self,
                                    value: CGSize(width: panelWidth, height: contents.size.height + timelineHeaderHeight))
                            }
                        }
                }.scrollBounceBehavior(.basedOnSize)
                    .frame(height: max(0, panelSize.height - timelineHeaderHeight))
            }.readingGlass(radius: 20)
        }
    }
    private var timelineContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            timeRangeBar
            TimelineRangeControl(lower: $store.timeFrom, upper: $store.timeTo, bounds: bounds,
                                   events: axisEvents, selectedID: store.selectedObjectID, select: selectEvent,
                                   cursor: temporalMode ? $store.timeCursor : nil, label: axisLabel)
                .id(store.bookID)
            if let event = expandedEvent {
                Divider().opacity(0.5)
                // Keep this region's height stable when filtering the selected
                // event out, so a held endpoint never shifts under the pointer.
                eventDetails(event).frame(height: detailHeight).transition(.opacity)
            } else if points.isEmpty {
                Text(visibleEvents.isEmpty ? "当前范围没有事件；可调整端点或显示全部时间。" : "暂无可定位坐标，事件详情仍可从清单阅读。")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: 18, alignment: .leading)
                    .padding(.horizontal, 7).padding(.bottom, 3)
            }
        }
    }

    private var timelineHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "clock").font(.system(size: 18)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("时间与地图").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if timelineCollapsed { Text("\(axisLabel(store.timeFrom)) — \(axisLabel(store.timeTo))").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                .overlay {
                    FloatingPanelPointerInput(epoch: pointerEpoch, begin: beginPanelDrag, drag: dragPanel, cancel: cancelPanelDrag)
                        .accessibilityHidden(true)
                }
                .help("拖动此处移动时间卡片；松手后吸附到最近的角或下方中央，Esc 取消")
                .accessibilityLabel("时间与地图，可在选项菜单更改停靠位置")
            Menu {
                Button("浏览事件清单（\(visibleEvents.count)）") { showingEvents = true }
                Menu("时间体系") {
                    Button("原书纪年标签（历法未统一）") { selectAxis("legacy") }
                    ForEach(store.temporalCalendars, id: \.self) { calendar in Button(calendar) { selectAxis("calendar:" + calendar) } }
                    if store.hasNarrativeTime { Button("叙事顺序") { selectAxis("narrative") } }
                }
                Toggle("显示出现次序虚线", isOn: $showsFootprintSequence).disabled(store.selectedTemporalEntityID == nil || !temporalMode)
                Text("虚线连接有出处的出现点，不代表真实路线。")
                Toggle("只看当前原文相关事件", isOn: $store.readingScopeCurrent)
                Toggle("保留时间待考事件", isOn: $store.showUndated)
                Button("地图适合全部标记") { camera = .automatic }
                Button("显示全部时间") { fitTime() }
                Divider()
                Menu("面板停靠位置") {
                    ForEach(FloatingPanelDock.allCases, id: \.self) { position in
                        Button { movePanel(to: position) } label: {
                            if dock == position { Label(dockTitle(position), systemImage: "checkmark") }
                            else { Text(dockTitle(position)) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).fixedSize().help("时间与地图选项").accessibilityLabel("时间与地图选项")
                .popover(isPresented: $showingEvents) { eventList }
            Button { cancelPanelDrag(); withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { timelineCollapsed.toggle() } } label: {
                Image(systemName: timelineCollapsed ? "plus" : "minus")
            }.buttonStyle(ReadingToolbarButtonStyle()).help(timelineCollapsed ? "展开时间卡片" : "收起时间卡片内容").accessibilityLabel(timelineCollapsed ? "展开时间卡片" : "收起时间卡片内容")
            Button { cancelPanelDrag(); withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { showsTimeline = false } } label: {
                Image(systemName: "xmark")
            }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭时间卡片，可从底部工具栏恢复").accessibilityLabel("关闭时间卡片")
        }
    }

    private var timeRangeBar: some View {
        Group {
            if panelWidth < 700 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) { timeRangeButton; Spacer(minLength: 0); eventListButton }
                    personSelector
                }
            } else {
                HStack(spacing: 8) {
                    timeRangeButton
                    Spacer(minLength: 8)
                    personSelector.frame(maxWidth: 180)
                    eventListButton
                }
            }
        }.padding(.horizontal, 0)
    }
    private var timeRangeButton: some View {
        Button {
            fromText = String(Int(store.timeFrom)); toText = String(Int(store.timeTo)); rangeError = ""; editingRange = true
        } label: {
            HStack(spacing: 5) {
                Text("\(axisLabel(store.timeFrom)) — \(axisLabel(store.timeTo))")
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
        }.buttonStyle(ReadingToolbarButtonStyle(selected: editingRange)).help("\(axisLabel(store.timeFrom)) — \(axisLabel(store.timeTo))；输入精确起止时间")
            .popover(isPresented: $editingRange) { rangeEditor }
    }
    private var personSelector: some View {
        Menu {
            Button("全部人物与事件") { store.selectedTemporalEntityID = nil }
            ForEach(admittedEntities.filter { $0.latitude == nil && $0.longitude == nil }) { entity in
                Button(entity.name) { store.selectedTemporalEntityID = entity.id; showsPerson = true }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                Text(store.selectedTemporalEntityID.map(store.objectTitle) ?? "跟随人物").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }.font(.system(size: 15)).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help(store.selectedTemporalEntityID.map(store.objectTitle) ?? "选择人物，查看其行动与时空")
    }
    private var eventListButton: some View {
        Button { showingEvents.toggle() } label: { Label("事件 \(visibleEvents.count)", systemImage: "list.bullet").lineLimit(1) }
            .buttonStyle(ReadingToolbarButtonStyle(selected: showingEvents)).fixedSize(horizontal: true, vertical: false).help("浏览事件清单")
    }

    private func eventDetails(_ event: KnowledgeEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.dateText + (event.placeIDs.isEmpty ? "" : " · " + event.placeIDs.map(store.objectTitle).joined(separator: "、")))
                        .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Text(event.name).font(.system(size: 16, weight: .semibold)).lineLimit(2).textSelection(.enabled)
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
                        if !event.evidence.isEmpty {
                            DisclosureGroup("原文依据 · \(event.evidence.count)") { EvidenceList(evidence: event.evidence) }.font(.system(size: 13))
                        }
                    }.padding(.horizontal, 5).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
                }.id(event.id)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("此事件不在当前时间范围内", systemImage: "line.3.horizontal.decrease.circle").font(.subheadline.weight(.medium))
                    Text("当前筛选不包含这条事件。可重新显示它，或继续调整时间范围。").font(.caption).foregroundStyle(.secondary)
                    Button("显示并定位此事件") { selectEvent(event.id) }.buttonStyle(ReadingToolbarButtonStyle())
                }.padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if expandedEventIsVisible {
                HStack(spacing: 12) {
                    if let evidence = event.evidence.first {
                        Text(store.book?.units.first(where: { $0.id == evidence.unitID })?.locator ?? "原文依据")
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.navigateToUnit(evidence.unitID); store.route = "reader"
                        } label: { Label("回到原句", systemImage: "book") }
                            .buttonStyle(ReadingToolbarButtonStyle()).foregroundStyle(Palette.accent)
                    } else {
                        Text("暂未登记原文依据").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 5).frame(minHeight: 44)
            }
        }
    }
    private func objectLinks(_ ids: [String], title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    Button {
                        store.focus(id)
                        if title == "参与者" { store.selectedTemporalEntityID = id; showsPerson = true }
                        else { inspectedObjectID = id }
                    } label: {
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
                        if visibleEvents.isEmpty { Text("当前范围没有事件。调整端点或显示全部时间。").font(.caption).foregroundStyle(.secondary).padding(16) }
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
        store.timeCursor = min(store.timeTo, max(store.timeFrom, store.timeCursor))
    }
    private func handleViewCommand(_ command: WorkspaceAICommand?) {
        guard let command, let args = try? JSONSerialization.jsonObject(with: command.arguments) as? [String: Any] else { return }
        guard dragOrigin == nil else { store.acknowledgeViewCommand(command, status: "busy", message: "时间面板正在拖动。"); return }
        if command.name == "panel_present", args["panelID"] as? String == "map.timeline" {
            switch args["state"] as? String {
            case "open": restoreTimeline()
            case "collapse": showsTimeline = true; timelineCollapsed = true
            case "close": showsTimeline = false
            default: store.acknowledgeViewCommand(command, status: "unsupported", message: "面板状态无效。"); return
            }
            store.acknowledgeViewCommand(command, message: "时间面板状态已更新。")
        } else if command.name == "map_fit_objects" {
            let ids = Set(args["objectIDs"] as? [String] ?? [])
            let matches = points.filter { ids.contains($0.targetID) }
            guard !matches.isEmpty else { store.acknowledgeViewCommand(command, status: "unsupported", message: "当前快照没有这些对象的可靠坐标。"); return }
            let latitudes = matches.map { $0.coordinate.latitude }, longitudes = matches.map { $0.coordinate.longitude }
            guard let south = latitudes.min(), let north = latitudes.max(), let west = longitudes.min(), let east = longitudes.max() else { return }
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (north + south) / 2, longitude: (west + east) / 2),
                span: MKCoordinateSpan(latitudeDelta: min(170, max(0.3, (north - south) * 1.5)), longitudeDelta: min(350, max(0.3, (east - west) * 1.5)))))
            store.acknowledgeViewCommand(command, message: "已按有证据的位置调整地图；没有创建坐标。")
        }
    }
    private func selectAxis(_ axis: String) {
        store.temporalAxis = axis; fitTime(); store.timeCursor = store.timeFrom
        if let first = axisEvents.compactMap(\.startYear).min() { store.timeCursor = Double(first) }
    }
    private func expand(_ id: String) {
        restoreTimeline()
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
        locateSelection(id)
    }
    private func locateSelection(_ id: String) {
        locate(id)
        let token = UUID(), key = store.workspaceMemoryKey
        selectionLayoutToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard selectionLayoutToken == token else { return }
            defer { selectionLayoutToken = nil }
            guard key == store.workspaceMemoryKey, store.selectedObjectID == id, !camera.positionedByUser else { return }
            locate(id)
        }
    }
    private func locate(_ id: String) {
        guard let point = points.first(where: { $0.targetID == id }) else { return }
        // Use the actual dock/size, including expanded details. A bottom card
        // leaves the point above it; a top card or side card chooses its free area.
        let span = MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
        let free = showsTimeline
            ? FloatingPanelGeometry.unobscuredMapRect(viewport: workingViewport, panel: panelFrame.offsetBy(dx: 0, dy: -topReserve)).offsetBy(dx: 0, dy: topReserve)
            : CGRect(x: 0, y: topReserve, width: viewport.width, height: workingViewport.height)
        var center = point.coordinate
        center.longitude -= Double(free.midX / max(1, viewport.width) - 0.5) * span.longitudeDelta
        center.latitude += Double(free.midY / max(1, viewport.height) - 0.5) * span.latitudeDelta
        center.latitude = min(85, max(-85, center.latitude))
        if center.longitude < -180 { center.longitude += 360 }
        if center.longitude > 180 { center.longitude -= 360 }
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
    private func beginPanelDrag() {
        let frame = panelFrame
        dragOrigin = CGPoint(x: frame.midX, y: frame.midY)
        dragCenter = nil
    }
    private func dragPanel(by delta: CGSize, ended: Bool) {
        guard let dragOrigin else { return }
        let center = clampedPanelCenter(CGPoint(x: dragOrigin.x + delta.width, y: dragOrigin.y + delta.height))
        if ended {
            let candidates = [dock] + FloatingPanelDock.allCases.filter { $0 != dock }
            let target = candidates.min { first, second in
                let a = dockFrame(first), b = dockFrame(second)
                return hypot(a.midX - center.x, a.midY - center.y) < hypot(b.midX - center.x, b.midY - center.y)
            } ?? dock
            withAnimation(ReadingMotion.animation(reduce: reduceMotion)) {
                self.dragOrigin = nil; dragCenter = nil; dockRaw = target.rawValue
            }
        } else {
            var transaction = Transaction(); transaction.animation = nil
            withTransaction(transaction) { dragCenter = center }
        }
    }
    private func cancelPanelDrag() {
        var transaction = Transaction(); transaction.animation = nil
        withTransaction(transaction) { dragOrigin = nil; dragCenter = nil; pointerEpoch += 1 }
    }
    private func movePanel(to target: FloatingPanelDock) {
        cancelPanelDrag()
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { dockRaw = target.rawValue }
    }
    private func restoreTimeline() {
        cancelPanelDrag()
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { showsTimeline = true; timelineCollapsed = false }
    }
    private func dockTitle(_ position: FloatingPanelDock) -> String {
        switch position {
        case .topLeading: return "左上角"
        case .topTrailing: return "右上角"
        case .bottomLeading: return "左下角"
        case .bottomCenter: return "下方居中"
        case .bottomTrailing: return "右下角"
        }
    }
    private func fitTime() { store.timeFrom = bounds.lowerBound; store.timeTo = bounds.upperBound }
}

private struct TimelinePanelSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct ReadingMapScope: Equatable {
    let root: URL
    let key: String?
}
private struct ReadingMapSelection: Equatable {
    let targetID: String
    let scope: ReadingMapScope
    let token = UUID()
}
/// The time card can update without rebuilding unchanged MapKit annotations.
/// Bindings deliver camera commands and clicks; actions are handled by the current
/// parent view, so this equality never retains an old action closure.
private struct ReadingMapRenderer: View, Equatable {
    let points: [ReadingMapPoint]
    let sequence: [CLLocationCoordinate2D]
    let selectedID: String?
    let scope: ReadingMapScope
    let cameraValue: MapCameraPosition
    @Binding var camera: MapCameraPosition
    @Binding var selection: ReadingMapSelection?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.selectedID == rhs.selectedID && lhs.cameraValue == rhs.cameraValue
            && lhs.points == rhs.points && lhs.sequence.count == rhs.sequence.count
            && zip(lhs.sequence, rhs.sequence).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }
    var body: some View {
        Map(position: $camera) {
            if sequence.count > 1 {
                MapPolyline(coordinates: sequence).stroke(Palette.copper.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            }
            ForEach(points) { point in
                Annotation("", coordinate: point.coordinate) { mapMarker(point) }
            }
        }
        .mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
    }
    private func mapMarker(_ point: ReadingMapPoint) -> some View {
        let selected = selectedID == point.targetID
        return Button { selection = ReadingMapSelection(targetID: point.targetID, scope: scope) } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? "mappin" : "circle.fill").font(.system(size: selected ? 18 : 9, weight: .semibold))
                    .foregroundStyle(selected ? Palette.surface : Palette.accent)
                    .frame(width: selected ? 42 : 22, height: selected ? 42 : 22)
                    .background(selected ? Palette.accent : Palette.surface, in: Circle())
                    .overlay(Circle().stroke(Palette.accent.opacity(0.5), lineWidth: 1))
                if selected {
                    Text(point.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240).padding(.horizontal, 14).padding(.vertical, 8).background(Palette.surface, in: Capsule())
                    Text(point.subtitle).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240).padding(.horizontal, 9).padding(.vertical, 5).background(Palette.surface.opacity(0.94), in: Capsule())
                }
            }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(point.title) · \(point.subtitle)").accessibilityLabel("\(point.title)，\(point.subtitle)")
    }

}
