import SwiftUI
import AppKit
import MapKit
import ReadingCore

/// Declarative compositions use small native parts, rather than embedding the
/// existing full-page workspaces. All data comes from the scoped Core projection.
struct CompositionWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    var definition: ViewDefinition?
    var embedded = false
    var contextOverride: ReadingContext? = nil
    var currentScope: CompositionCurrentScope = .automatic
    @State private var projections: [String: CompositionProjection] = [:]
    @State private var baseline: [String: CompositionProjection] = [:]
    @State private var baselineSelection: [String: Set<String>]?
    @State private var baselineOwner: RefreshOwner?
    @State private var preparedInput: CompositionRuntime.PreparedCompositionInput?
    @State private var preparedOwner: RefreshOwner?
    @State private var displayedOwner: RefreshOwner?
    @State private var selections: [String: Set<String>] = [:]
    @State private var clocks: [String: CompositionClock] = [:]
    @State private var collapsed = Set<String>()
    @State private var tabs: [String: String] = [:]
    @State private var canvasAnchors: [String: CGPoint] = [:]
    @State private var issue: String?
    @State private var validatedComposition: CompositionDefinition?
    @State private var validatedBookID: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var requestedProjection: ProjectionRequest?
    @State private var refreshGeneration: UInt64 = 0
    @State private var isActive = false
    @State private var pendingTimeCommand: WorkspaceAICommand?
    @State private var pendingMapCommand: WorkspaceAICommand?
    @State private var pendingMapParts = Set<String>()
    @State private var mapFitRequests: [String: CompositionMapFitRequest] = [:]
    @State private var mapViewports: [String: ReadingMapViewport] = [:]
    // Camera intent belongs to this workspace/scope, not to a disposable map
    // child. Saving a chat republishes the book but must not reset its view.
    @State private var mapCameras: [String: MapCameraPosition] = [:]
    @State private var viewportGeneration: UInt64 = 0
    @State private var stagePresentationTask: Task<Void, Never>?

    private struct RefreshOwner: Equatable, Sendable {
        let libraryRoot: String
        let bookID: String
        let sourceHash: String
        let publicationStamp: LibraryPublicationStamp?
        let revision: Int
        let definition: CompositionDefinition
        let context: ReadingContext
        let boundary: KnowledgeReadBoundary
        let currentScope: CompositionCurrentScope
        let boundaryUnitID: String?
        let avoidsSpoilers: Bool
        let componentScopeID: UUID?
    }
    private struct ProjectionResult: Sendable {
        let prepared: CompositionRuntime.PreparedCompositionInput
        let baseline: [String: CompositionProjection]
        let projections: [String: CompositionProjection]
    }
    private struct ProjectionRequest {
        let owner: RefreshOwner
        let selection: [String: Set<String>]
        let times: [String: TemporalQueryPoint]
        let windows: [String: TemporalQueryWindow]
        let mapModes: [String: CompositionMapTimeMode]
    }

    private var composition: CompositionDefinition? { definition?.composition }
    private var points: [String: TemporalQueryPoint] { clocks.compactMapValues(\.point) }
    private var windows: [String: TemporalQueryWindow] { clocks.compactMapValues(\.window) }
    private var mapModes: [String: CompositionMapTimeMode] { clocks.mapValues(\.mapMode) }
    private var readingContext: ReadingContext { contextOverride ?? (embedded ? store.currentReadingContext : store.componentReadingContext) }

    private var workspaceContent: some View {
        GeometryReader { geometry in
            Group {
                if let issue { fallback(issue) }
                else if store.book == nil { fallback("请先从书库打开一本书，再查看这个组合。") }
                else if let composition, validatedComposition == composition, validatedBookID == store.bookID,
                        let displayedOwner, matches(displayedOwner, store: store) {
                    if !embedded, composition.canvasMapPart != nil {
                        canvas(composition, size: CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 80)))
                            .padding(.top, 72).padding(.bottom, 8)
                    } else { ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !embedded { workspaceHeader }
                            layout(composition.rootID, in: composition, width: max(240, geometry.size.width - (embedded ? 32 : 56)))
                        }.padding(.leading, embedded ? 8 : 20).padding(.trailing, embedded ? 24 : 36)
                            .padding(.top, embedded ? 8 : 92).padding(.bottom, embedded ? 8 : 28)
                    }.scrollIndicators(.visible).environment(\.workspacePageScroll, true) }
                } else if composition != nil { ProgressView("正在准备组件…") }
                else { fallback("这个组件尚未提供可显示的布局。原书、笔记和已保存配置都保留。") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var sourceObservedContent: some View {
        workspaceContent.background(embedded ? Color.clear : Palette.canvas).readingTextContext(.knowledge)
            .task { isActive = true; refresh() }
            .onDisappear { if !embedded, store.renderedCompositionState?.contextID == store.readingVisibilityContextID { store.renderedCompositionState = nil }; isActive = false; stagePresentationTask?.cancel(); cancelRefresh(); clearPrepared(); pendingTimeCommand = nil; clearMapCommand() }
            .onChange(of: store.workspaceAICommand) { _, command in receiveViewCommand(command) }
            .onChange(of: store.currentBookRevision) { _, _ in refresh() }
            .onChange(of: store.book?.publicationStamp) { _, _ in refresh() }
            .onChange(of: store.book?.sourceHash) { _, _ in mapCameras = [:]; refresh() }
            .onChange(of: store.selectedUnitID) { _, _ in mapCameras = [:]; refresh() }
            .onChange(of: store.book?.temporalKnowledge?.profile?.avoidsSpoilers) { _, _ in refresh() }
            .onChange(of: store.currentReadingContext) { _, _ in refresh() }
    }
    var body: some View {
        sourceObservedContent
            .onChange(of: store.componentDataScopeID) { _, _ in mapCameras = [:]; refresh() }
            .onChange(of: contextOverride) { _, _ in reset() }
            .onChange(of: currentScope) { _, _ in reset() }
            .onChange(of: store.libraryRootURL) { _, _ in reset() }
            .onChange(of: store.bookID) { _, _ in reset() }
            .onChange(of: definition) { _, _ in reset() }
            .onChange(of: selections) { _, _ in refresh(retainingContent: true) }
            .onChange(of: clocks) { _, _ in refresh(includeBaseline: false, retainingContent: true) }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2").foregroundStyle(Palette.accent)
            Text(definition?.title ?? "组合阅读").font(.system(size: 21, weight: .semibold, design: .serif))
            Spacer(minLength: 8)
            if ReadingWorkbench.isWorkbench(definition), let definition {
                Button { store.prepareWorkbenchContinuation(definition) } label: { Label("继续整理", systemImage: "sparkles").frame(minHeight: 48) }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("准备一条读到这里的补充请求；先检查已有资料和缺口，保留你的修正，查看后发送。")
                    .disabled(store.isQueryBusy || store.editorDirty)
            }
            if !selections.values.allSatisfy(\.isEmpty) || !clocks.isEmpty {
                Button { selections = [:]; clocks = [:] } label: { Label("全部内容", systemImage: "arrow.counterclockwise").frame(minHeight: 48) }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("清除本页选择和时间筛选")
            }
            Button { store.route = "reader" } label: { Label("原文", systemImage: "book").frame(minHeight: 48) }
                .buttonStyle(ReadingToolbarButtonStyle()).help("返回原文阅读")
        }.padding(.horizontal, 16).padding(.vertical, 4).readingGlass(radius: 22)
    }

    @ViewBuilder private func fallback(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up.slash").font(.system(size: 36)).foregroundStyle(Palette.accent)
            Text("暂时无法显示这个组合").font(.title2.weight(.medium))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 560)
            Button { store.route = "reader" } label: { Label("回到原文", systemImage: "arrow.uturn.backward").frame(minWidth: 160, minHeight: 48) }
                .buttonStyle(ReadingToolbarButtonStyle(selected: true))
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reset() {
        stagePresentationTask?.cancel(); stagePresentationTask = nil
        clearPrepared(); clearMapCommand(); mapViewports = [:]; mapCameras = [:]; selections = [:]; clocks = [:]; collapsed = []; tabs = [:]; canvasAnchors = [:]; refresh()
    }
    private func clearPrepared() { preparedInput = nil; preparedOwner = nil; requestedProjection = nil }
    private func cancelRefresh() {
        refreshTask?.cancel(); refreshTask = nil; requestedProjection = nil; refreshGeneration &+= 1
    }
    private func receiveViewCommand(_ command: WorkspaceAICommand?) {
        if command?.id != pendingMapCommand?.id { clearMapCommand() }
        guard let command,
              isActive, !embedded, definition?.id == store.route, !store.hasWorkspaceAuxiliary,
              let composition, let owner = displayedOwner, matches(owner, store: store) else { return }
        if command.name == "map_fit_objects" {
            // Filtering can acknowledge its data projection before MapKit has
            // published the new viewport. Keep this command for that handoff.
            guard refreshTask == nil else { return }
            guard let args = try? JSONSerialization.jsonObject(with: command.arguments) as? [String: Any] else { return }
            let ids = Set(args["objectIDs"] as? [String] ?? [])
            // An event need not have a marching route. Its already-projected
            // explicit place references can locate it on a place-only map.
            // Never consult withheld book records or infer an actor's location.
            let linkedPlaces = Set(projections.values.flatMap(\.items).filter {
                $0.kind == "event" && ids.contains($0.objectID ?? $0.id)
            }.flatMap { $0.references["places"] ?? [] })
            var targets: [String: Set<String>] = [:]
            let parts = composition.parts.filter { part in
                guard part.primitive == .map, mapViewports[part.id] != nil, let projection = projections[part.sourceID] else { return false }
                let routes = part.routeSourceID.flatMap { projections[$0]?.mapRoutes } ?? projection.mapRoutes
                let direct = projection.mapPoints.contains { ids.contains($0.targetID) } || routes.contains { $0.eventID.map(ids.contains) == true }
                let focus = direct ? ids : ids.union(linkedPlaces)
                guard direct || projection.mapPoints.contains(where: { focus.contains($0.targetID) }) else { return false }
                targets[part.id] = focus; return true
            }
            guard !parts.isEmpty else {
                if store.renderedCompositionState?.observationStatus == .pending { return }
                store.acknowledgeViewCommand(command, status: "unsupported", message: "当前已显示地图没有这些对象的可靠位置；未扩大原文或时间范围。")
                return
            }
            pendingMapCommand = command; pendingMapParts = Set(parts.map(\.id))
            mapFitRequests = Dictionary(uniqueKeysWithValues: parts.map { ($0.id, .init(id: command.id, objectIDs: targets[$0.id] ?? ids, generation: viewportGeneration)) })
            return
        }
        guard ["view_set_time_window", "view_show_event"].contains(command.name), let window = command.timeWindow else { return }
        let groups: Set<String>
        if command.name == "view_show_event", let eventID = command.eventID {
            // Resolve the target against the unfiltered projection. A prior
            // clock must not make a valid saved stage disappear from selection.
            let timelines = composition.parts.filter { part in
                part.primitive == .timeline && baseline[part.sourceID]?.items.contains(where: {
                    ($0.objectID ?? $0.id) == eventID && ReadingEventPresentationPlan.presentationWindow(recorded: $0.extent, source: $0.sourceExtent, preferredAxis: window.axis) == window
                }) == true
            }
            let linkedGroups = Set(timelines.map(\.timeGroup))
            guard linkedGroups.count == 1, let group = linkedGroups.first,
                  composition.parts.contains(where: { $0.primitive == .map && $0.timeGroup == group }) else {
                store.acknowledgeViewCommand(command, status: "unsupported", message: "当前组合没有同一时间组的事件时间轴和地图；未猜测或更改其他时间组。")
                return
            }
            groups = linkedGroups
            for part in timelines { selections[part.selectionGroup] = [eventID] }
        } else {
            groups = Set(composition.sources.compactMap { source -> String? in
                let extents = baseline[source.id]?.items.flatMap { [$0.extent, $0.sourceExtent].compactMap { $0 } } ?? []
                return TemporalAxis.available(extents).contains(window.axis) ? source.timeGroup : nil
            })
        }
        guard !groups.isEmpty else {
            store.acknowledgeViewCommand(command, status: "unsupported", message: "当前组合没有本次时间体系的数据；未改变筛选。")
            return
        }
        pendingTimeCommand = command
        for group in groups {
            clocks[group] = CompositionClock(axis: window.axis, lower: window.from, upper: window.to,
                cursor: window.cursor, mapMode: clocks[group]?.mapMode ?? .instant)
        }
        refresh(includeBaseline: false, retainingContent: true)
    }
    private func clearMapCommand() { pendingMapCommand = nil; pendingMapParts = []; mapFitRequests = [:] }
    private func finishMapCommand(_ id: UUID, partID: String, error: String?) {
        guard let command = pendingMapCommand, command.id == id, store.workspaceAICommand?.id == id,
              pendingMapParts.contains(partID), let request = mapFitRequests[partID],
              isActive, !embedded, definition?.id == store.route,
              let owner = displayedOwner, matches(owner, store: store) else { return }
        if let error = error ?? (request.generation == viewportGeneration ? nil : "地图范围已经变化。") {
            store.acknowledgeViewCommand(command, status: "conflict", message: "地图调整未完成：" + error)
            clearMapCommand(); return
        }
        pendingMapParts.remove(partID)
        if pendingMapParts.isEmpty {
            store.acknowledgeViewCommand(command, message: "组合地图已按当前投影中有依据的位置完成调整；没有改写资料或扩大时间与原文范围。")
            clearMapCommand()
        }
    }
    private func finishTimeCommand(error: String? = nil) {
        guard let command = pendingTimeCommand else { return }
        pendingTimeCommand = nil
        guard store.workspaceAICommand?.id == command.id, isActive, !embedded, definition?.id == store.route else { return }
        if let error { store.acknowledgeViewCommand(command, status: "conflict", message: "组合时间筛选未完成：" + error) }
        else if let window = command.timeWindow {
            store.temporalAxis = window.axis; store.timeFrom = window.from; store.timeTo = window.to; store.timeCursor = window.cursor
            store.acknowledgeViewCommand(command, message: "组合内同一时间基准的地图与时间轴已完成筛选；原始资料未改写。")
        }
    }
    private func matches(_ owner: RefreshOwner, store: AppStore) -> Bool {
        guard let book = store.book, store.libraryRootURL.path == owner.libraryRoot,
              book.id == owner.bookID, book.sourceHash == owner.sourceHash,
              store.currentBookRevision == owner.revision, composition == owner.definition,
              readingContext == owner.context, (embedded ? nil : store.componentDataScopeID) == owner.componentScopeID,
              store.selectedUnitID == owner.boundaryUnitID,
              (book.temporalKnowledge?.profile?.avoidsSpoilers ?? true) == owner.avoidsSpoilers,
              currentScope == owner.currentScope else { return false }
        // temporalBoundary is a function of this publication, selected unit and
        // spoiler policy. Compare those inputs without rebuilding its full-book
        // unit whitelist for every body evaluation or cursor frame. The exact
        // frozen boundary remains part of owner/prepared input.
        // A non-nil stamp identifies the captured publication. Nil never proves
        // snapshot equality: the caller also requires the active generation and
        // revision/context/boundary event gates above before publishing.
        if let stamp = owner.publicationStamp { return book.publicationStamp == stamp }
        return book.publicationStamp == nil
    }
    private func refresh(includeBaseline: Bool = true, retainingContent: Bool = false) {
        guard isActive else { cancelRefresh(); return }
        guard let book = store.book, let composition else {
            cancelRefresh()
            clearPrepared(); displayedOwner = nil
            projections = [:]; baseline = [:]; baselineSelection = nil; baselineOwner = nil; validatedComposition = nil; validatedBookID = nil; issue = nil; return
        }
        if embedded, selections.isEmpty, let id = readingContext.objectID {
            for source in composition.sources { selections[source.selectionGroup] = [id] }
        }
        let selection = selections, times = points, ranges = windows, modes = mapModes
        // Explicit commands and SwiftUI's selection/clock observers can ask
        // for the same projection. Do not cancel/re-publish it after its time
        // command has already acknowledged, invalidating a following map fit.
        if let requested = requestedProjection, matches(requested.owner, store: store),
           requested.selection == selection, requested.times == times,
           requested.windows == ranges, requested.mapModes == modes {
            // A repeated command still needs its own acknowledgment. When a
            // worker is running it will acknowledge after commit; otherwise
            // the identical projection has already committed.
            if refreshTask == nil { finishTimeCommand() }
            return
        }
        cancelRefresh()
        if !embedded { publishPreparation(.pending) }
        let owner: RefreshOwner
        let retainedPrepared: CompositionRuntime.PreparedCompositionInput?
        if let prior = preparedOwner, matches(prior, store: store) { owner = prior; retainedPrepared = preparedInput }
        else {
            clearPrepared()
            retainedPrepared = nil
            owner = RefreshOwner(libraryRoot: store.libraryRootURL.path, bookID: book.id, sourceHash: book.sourceHash,
                publicationStamp: book.publicationStamp, revision: store.currentBookRevision, definition: composition,
                context: readingContext, boundary: store.temporalBoundary, currentScope: currentScope,
                boundaryUnitID: store.selectedUnitID, avoidsSpoilers: book.temporalKnowledge?.profile?.avoidsSpoilers ?? true,
                componentScopeID: embedded ? nil : store.componentDataScopeID)
        }
        let generation = refreshGeneration
        requestedProjection = ProjectionRequest(owner: owner, selection: selection, times: times, windows: ranges, mapModes: modes)
        let sourceSnapshot = embedded ? nil : store.activeComponentView?.snapshot
        let baselineMatches = baselineOwner.map { matches($0, store: store) } ?? false
        let retainedBaseline = !includeBaseline && baselineSelection == selection && baselineMatches ? baseline : nil
        if !retainingContent {
            displayedOwner = nil
            projections = [:]; baseline = [:]; baselineSelection = nil; baselineOwner = nil; validatedComposition = nil; validatedBookID = nil
        }
        issue = nil
        refreshTask = Task { [weak store] in
            let worker = Task.detached(priority: .userInitiated) {
                let prepared = try retainedPrepared ?? CompositionRuntime.prepare(composition, in: book, context: owner.context,
                    currentScope: owner.currentScope, boundary: owner.boundary, sourceSnapshot: sourceSnapshot)
                let baseline = try retainedBaseline ?? CompositionRuntime.project(prepared, selections: selection)
                try Task.checkCancellation()
                let projections: [String: CompositionProjection]
                if times.isEmpty && ranges.isEmpty { projections = baseline }
                else { projections = try CompositionRuntime.project(prepared, selections: selection, times: times, windows: ranges, mapModes: modes) }
                try Task.checkCancellation()
                return ProjectionResult(prepared: prepared, baseline: baseline, projections: projections)
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, isActive, refreshGeneration == generation, selections == selection, points == times, windows == ranges, mapModes == modes,
                      let store, matches(owner, store: store) else { return }
                preparedInput = result.prepared; preparedOwner = owner; displayedOwner = owner
                baseline = result.baseline; baselineSelection = selection; baselineOwner = owner; projections = result.projections
                validatedComposition = composition; validatedBookID = book.id; issue = nil; refreshTask = nil
                mapViewports = [:]; viewportGeneration &+= 1
                // The prior generation may have reported ready while these
                // projections were preparing. Acknowledge the new time data
                // only with its map observation pending, so an immediate fit
                // waits for this generation instead of rejecting empty maps.
                if !embedded { publishCurrentMapState(.pending) }
                finishTimeCommand()
            } catch is CancellationError {
                if refreshGeneration == generation { refreshTask = nil; requestedProjection = nil }
            } catch {
                guard !Task.isCancelled, isActive, refreshGeneration == generation, selections == selection, points == times, windows == ranges, mapModes == modes,
                      let store, matches(owner, store: store) else { return }
                displayedOwner = nil
                projections = [:]; baseline = [:]; baselineSelection = nil; baselineOwner = nil; validatedComposition = nil; validatedBookID = nil
                issue = error.localizedDescription; refreshTask = nil; requestedProjection = nil
                publishPreparation(.failed)
                finishTimeCommand(error: error.localizedDescription)
            }
        }
    }
    private func publishPreparation(_ status: ReadingWorkspaceObservationStatus) {
        guard !embedded, isActive, definition?.id == store.route else { return }
        guard composition?.parts.contains(where: { $0.primitive == .map }) == true else { store.renderedCompositionState = nil; return }
        store.renderedCompositionState = .init(contextID: store.readingVisibilityContextID, selectedIDs: [], maps: [], clocks: [], observationStatus: status)
    }
    private func publishMap(_ value: ReadingMapViewport?, status: ReadingWorkspaceObservationStatus, partID: String, generation: UInt64) {
        guard !embedded, isActive, definition?.id == store.route, refreshTask == nil, generation == viewportGeneration,
              let owner = displayedOwner, matches(owner, store: store) else { return }
        if let value { mapViewports[partID] = value } else { mapViewports[partID] = nil }
        // No stale observation while a camera is moving. Other parts cannot
        // turn the missing observation into an assertion that the map is empty.
        publishCurrentMapState(status)
        if status == .ready || status == .empty, pendingMapCommand == nil,
           let command = store.workspaceAICommand, command.name == "map_fit_objects",
           store.workspaceAIResponses[command.id] == nil {
            receiveViewCommand(command)
        }
    }
    private func publishCurrentMapState(_ status: ReadingWorkspaceObservationStatus) {
        // The projection's clock and selection are committed even while its
        // new map awaits a camera observation. Keep that renderer-owned state
        // so a following action does not silently choose a different axis.
        let windows = clocks.keys.sorted().compactMap { key -> ReadingViewTimeWindow? in
            guard let clock = clocks[key], let axis = clock.axis, let from = clock.lower, let to = clock.upper, let current = clock.cursor else { return nil }
            return ReadingViewTimeWindow(groupID: key, axis: axis, from: from, to: to, current: current)
        }
        store.renderedCompositionState = RenderedCompositionState(contextID: store.readingVisibilityContextID,
            selectedIDs: Array(Set(selections.values.flatMap { $0 })).sorted(),
            maps: mapViewports.keys.sorted().compactMap { mapViewports[$0] }, clocks: windows,
            observationStatus: status == .empty && !mapViewports.isEmpty ? .ready : status)
    }
    private func select(_ id: String, group: String) {
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) {
            if NSEvent.modifierFlags.contains(.command) {
                var values = selections[group] ?? []
                if values.contains(id) { values.remove(id) } else { values.insert(id) }
                selections[group] = values
            } else { selections[group] = [id] }
        }
    }
    private func presentStage(_ id: String, from part: CompositionPart) {
        let groups = Set(composition?.parts.filter { candidate in
            candidate.primitive == .timeline && baseline[candidate.sourceID]?.items.contains(where: { ($0.objectID ?? $0.id) == id }) == true
        }.map(\.timeGroup) ?? [])
        // An embedded or independently grouped timeline keeps its local
        // controls. Do not reinterpret it as a single shared map goal.
        guard groups.count == 1, store.activeComponentView?.snapshot != nil else {
            if let item = baseline[part.sourceID]?.items.first(where: { ($0.objectID ?? $0.id) == id }),
               let window = ReadingEventPresentationPlan.sourceWindow(item.sourceExtent) {
                clocks[part.timeGroup] = CompositionClock(axis: window.axis, lower: window.from, upper: window.to,
                    cursor: window.cursor, mapMode: clocks[part.timeGroup]?.mapMode ?? .instant)
                select(id, group: part.selectionGroup)
            }
            return
        }
        stagePresentationTask?.cancel()
        stagePresentationTask = Task { [weak store] in
            guard let store else { return }
            do { _ = try await store.presentUserReadingEvent(id) }
            catch is CancellationError { }
            catch { if !Task.isCancelled { store.activity = "阶段切换未完成：" + error.localizedDescription } }
        }
    }

    private func canvas(_ composition: CompositionDefinition, size: CGSize) -> some View {
        let root = composition.layout.first { $0.id == composition.rootID }!
        let mapPart = composition.canvasMapPart!
        let cards = Array(root.children.dropFirst())
        let controls = CompositionCanvasLayout.controls(in: size)
        let visible = Set(cards.filter { id in composition.layout.first(where: { $0.id == id }).map { canvasCardIsVisible($0, in: composition) } ?? false })
        let frames = CompositionCanvasLayout.frames(in: composition, viewport: size, collapsed: collapsed, visible: visible, anchors: canvasAnchors)
        return ZStack(alignment: .topLeading) {
            if let projection = projections[mapPart.sourceID] {
                compositionMap(mapPart, projection: projection, height: size.height, canvas: true, occlusions: [controls] + cards.compactMap { frames[$0] })
                    .accessibilityIdentifier("composition-map-canvas")
            }
            ForEach(cards, id: \.self) { id in
                if let node = composition.layout.first(where: { $0.id == id }), canvasCardIsVisible(node, in: composition) {
                    let frame = frames[id] ?? .zero
                    Group {
                        if node.kind == .part {
                            layout(id, in: composition, width: frame.width, floating: true,
                                dismiss: node.presentation == .contextual ? { dismiss(node, in: composition) } : nil, pinnedHeader: true)
                        } else {
                            ScrollView {
                                layout(id, in: composition, width: frame.width, floating: true,
                                    dismiss: node.presentation == .contextual ? { dismiss(node, in: composition) } : nil)
                            }.scrollIndicators(.visible)
                        }
                    }.frame(width: frame.width, height: frame.height)
                        .background(Palette.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .readingGlass(radius: 24, prominent: true)
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityIdentifier("composition-floating-" + id)
                }
            }
            HStack(spacing: 6) {
                Button { selections = [:]; canvasAnchors = [:]; clocks = [:] } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                }.buttonStyle(ReadingQuietButtonStyle()).help("取消选择和时间筛选，显示本范围全部资料")
                    .accessibilityLabel("显示全部内容")
                    .contextMenu {
                        if let view = definition, view.previousLayout != nil {
                            Button("恢复上次布局", systemImage: "rectangle.2.swap") {
                                Task { await store.restoreReadingComponentLayout(view.id) }
                            }
                        }
                    }
                Button { store.route = "reader" } label: { Label("原文", systemImage: "book").frame(minHeight: 44).padding(.horizontal, 8) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("回到当前阅读位置")
            }.padding(4).frame(width: controls.width, height: controls.height).readingGlass(radius: 28)
                .position(x: controls.midX, y: controls.midY)
        }.frame(width: size.width, height: size.height).clipped()
            .environment(\.workspacePageScroll, false)
    }
    private func canvasCardIsVisible(_ node: CompositionLayoutNode, in composition: CompositionDefinition) -> Bool {
        guard node.presentation == .contextual else { return true }
        return composition.parts(inLayout: node.id).contains { part in
            let ids = selections[part.selectionGroup] ?? []
            return projections[part.sourceID]?.items.contains { ids.contains($0.objectID ?? $0.documentID ?? $0.id) } == true
        }
    }
    private func dismiss(_ node: CompositionLayoutNode, in composition: CompositionDefinition) {
        for part in composition.parts(inLayout: node.id) { selections[part.selectionGroup] = []; canvasAnchors[part.selectionGroup] = nil }
    }

    private func layout(_ id: String, in composition: CompositionDefinition, width: CGFloat, floating: Bool = false, dismiss: (() -> Void)? = nil, pinnedHeader: Bool = false) -> AnyView {
        guard let node = composition.layout.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
        let children = node.children
        switch node.kind {
        case .part:
            guard let part = composition.parts.first(where: { $0.id == node.partID }) else { return AnyView(EmptyView()) }
            return AnyView(partCard(part, width: width, floating: floating, dismiss: dismiss, pinnedHeader: pinnedHeader))
        case .column:
            return AnyView(VStack(alignment: .leading, spacing: 18) {
                ForEach(children, id: \.self) { layout($0, in: composition, width: width, floating: floating, dismiss: dismiss) }
            })
        case .row:
            let available = max(1, width - CGFloat(max(0, children.count - 1)) * 18)
            let weights = children.map { child in composition.layout.first { $0.id == child }?.fraction ?? 1 }
            let total = max(0.001, weights.reduce(0, +))
            if width < 740 || weights.contains(where: { available * CGFloat($0 / total) < 260 }) {
                return AnyView(VStack(alignment: .leading, spacing: 18) {
                    ForEach(children, id: \.self) { layout($0, in: composition, width: width, floating: floating, dismiss: dismiss) }
                })
            }
            return AnyView(HStack(alignment: .top, spacing: 18) {
                ForEach(Array(children.enumerated()), id: \.element) { index, child in
                    let childWidth = available * CGFloat(weights[index] / total)
                    layout(child, in: composition, width: childWidth, floating: floating, dismiss: dismiss).frame(width: childWidth)
                }
            })
        case .tabs:
            let selected = tabs[id].flatMap { children.contains($0) ? $0 : nil } ?? children.first
            return AnyView(VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(children, id: \.self) { child in
                            Button { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { tabs[id] = child } } label: {
                                Text(layoutTitle(child, in: composition)).lineLimit(1).frame(minWidth: 72, minHeight: 48)
                            }.buttonStyle(ReadingToolbarButtonStyle(selected: selected == child))
                        }
                    }.padding(5)
                }.readingGlass(radius: 20)
                if let selected { layout(selected, in: composition, width: width, floating: floating, dismiss: dismiss) }
            })
        case .overlay:
            // The first child owns the canvas. Later children float over it;
            // a compact window stacks them rather than hiding the canvas.
            if width < 740 {
                return AnyView(VStack(spacing: 18) { ForEach(children, id: \.self) { child in
                    if let node = composition.layout.first(where: { $0.id == child }), canvasCardIsVisible(node, in: composition) {
                        layout(child, in: composition, width: width)
                    }
                } })
            }
            return AnyView(ZStack {
                if let first = children.first { layout(first, in: composition, width: width) }
                ForEach(Array(children.dropFirst()), id: \.self) { child in
                    if let node = composition.layout.first(where: { $0.id == child }), canvasCardIsVisible(node, in: composition) {
                    let dock = composition.layout.first { $0.id == child }?.dock ?? .bottomTrailing
                    layout(child, in: composition, width: min(350, width * 0.4))
                        .frame(width: min(350, width * 0.4)).padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(dock))
                    }
                }
            }.frame(minHeight: 440))
        }
    }
    private func layoutTitle(_ id: String, in composition: CompositionDefinition) -> String {
        guard let node = composition.layout.first(where: { $0.id == id }) else { return "内容" }
        if let part = composition.parts.first(where: { $0.id == node.partID }) { return title(part) }
        return node.children.first.map { layoutTitle($0, in: composition) } ?? "内容"
    }
    private func alignment(_ dock: FloatingPanelDock) -> Alignment {
        switch dock {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        case .bottomCenter: return .bottom
        }
    }

    private func title(_ part: CompositionPart) -> String {
        if !part.title.isEmpty { return part.title }
        switch part.primitive {
        case .objectList: return "书中要素"
        case .objectDetail: return "要素详情"
        case .sourceExcerpt: return "原文依据"
        case .markdown: return "相关笔记"
        case .timeline: return "时间"
        case .map: return "地图"
        case .relations: return "关系"
        case .documentGraph: return "文档导图"
        case .table: return "对象对照"
        }
    }
    private func icon(_ part: CompositionPart) -> String {
        switch part.primitive {
        case .objectList: return "rectangle.stack"
        case .objectDetail: return "text.rectangle"
        case .sourceExcerpt: return "quote.opening"
        case .markdown: return "doc.text"
        case .timeline: return "clock"
        case .map: return "map"
        case .relations: return "point.3.filled.connected.trianglepath.dotted"
        case .documentGraph: return "point.3.connected.trianglepath.dotted"
        case .table: return "tablecells"
        }
    }
    private func partCard(_ part: CompositionPart, width: CGFloat, floating: Bool = false, dismiss: (() -> Void)? = nil, pinnedHeader: Bool = false) -> some View {
        let projection = projections[part.sourceID]
        let source = baseline[part.sourceID]
        let details = VStack(alignment: .leading, spacing: 0) {
                if let projection {
                    primitive(part, projection: projection, baseline: source ?? projection, width: width, floating: floating)
                    if projection.partial, projection.items.count < projection.total {
                        Text("当前显示 \(projection.items.count) 项，共 \(projection.total) 项。")
                            .font(.caption).foregroundStyle(.secondary).padding(14)
                    }
                    if !projection.diagnostics.isEmpty {
                        Text(projection.diagnostics.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(14)
                    }
                } else { CompositionEmptyState(text: "正在准备内容…", icon: icon(part)) }
        }
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon(part)).foregroundStyle(Palette.accent)
                Text(title(part)).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    if let dismiss { dismiss(); return }
                    withAnimation(ReadingMotion.animation(reduce: reduceMotion)) {
                        if collapsed.contains(part.id) { collapsed.remove(part.id) } else { collapsed.insert(part.id) }
                    }
                } label: { Image(systemName: dismiss != nil ? "xmark" : collapsed.contains(part.id) ? "plus" : "minus").frame(width: 48, height: 48) }
                    .buttonStyle(ReadingQuietButtonStyle()).contentShape(Rectangle()).help(dismiss != nil ? "关闭详情，或点击地图空白处收起" : collapsed.contains(part.id) ? "展开\(title(part))" : "收起\(title(part))")
                    .accessibilityLabel(dismiss != nil ? "关闭\(title(part))" : collapsed.contains(part.id) ? "展开\(title(part))" : "收起\(title(part))")
            }.padding(.leading, 18).padding(.trailing, 6).frame(minHeight: 60)
            if !collapsed.contains(part.id) {
                Divider().opacity(0.4)
                if pinnedHeader { ScrollView { details }.scrollIndicators(.visible) }
                else { details }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        return Group {
            if floating { content }
            else { content.readingGlass(radius: 24) }
        }
    }

    @ViewBuilder private func primitive(_ part: CompositionPart, projection: CompositionProjection, baseline: CompositionProjection, width: CGFloat, floating: Bool = false) -> some View {
        let selected = selections[part.selectionGroup] ?? []
        switch part.primitive {
        case .objectList:
            CompositionObjectList(items: projection.items, selected: selected) { select($0, group: part.selectionGroup) }
        case .objectDetail:
            CompositionObjectDetails(items: projection.items, selected: selected)
        case .table:
            CompositionObjectTable(items: projection.items, columns: part.columns ?? [], selected: selected) { select($0, group: part.selectionGroup) }
        case .sourceExcerpt:
            CompositionExcerpts(items: projection.items)
        case .markdown:
            CompositionMarkdown(items: projection.items, selected: selected)
        case .map:
            compositionMap(part, projection: projection, height: embedded ? 220 : 420)
        case .timeline:
            CompositionTimeline(items: baseline.items, selected: selected,
                clock: Binding(get: { clocks[part.timeGroup] ?? CompositionClock() }, set: { clocks[part.timeGroup] = $0 }), compact: floating,
                select: { select($0, group: part.selectionGroup) },
                selectStage: !embedded && composition?.parts.contains(where: { $0.primitive == .map && $0.timeGroup == part.timeGroup }) == true ? { presentStage($0, from: part) } : nil)
        case .relations, .documentGraph:
            CompositionGraph(partID: part.id, viewID: definition?.id ?? "composition", projection: projection,
                selected: selected, documents: part.primitive == .documentGraph, width: width,
                select: { select($0, group: part.selectionGroup) }, deselect: { selections[part.selectionGroup] = [] })
        }
    }
    private func compositionMap(_ part: CompositionPart, projection: CompositionProjection, height: CGFloat, canvas: Bool = false, occlusions: [CGRect] = []) -> some View {
            VStack(alignment: .leading, spacing: canvas ? 0 : 8) {
                if !canvas {
                if clocks[part.timeGroup]?.window != nil {
                    Picker("人物位置", selection: Binding(get: { clocks[part.timeGroup]?.mapMode ?? .instant }, set: { mode in
                        var clock = clocks[part.timeGroup] ?? CompositionClock(); clock.mapMode = mode; clocks[part.timeGroup] = clock
                    })) {
                        Text("此刻位置").tag(CompositionMapTimeMode.instant)
                        Text("这段时间的已知足迹").tag(CompositionMapTimeMode.windowFootprints)
                    }.pickerStyle(.menu).padding(.horizontal, 16).frame(minHeight: 48)
                }
                }
                let routes = part.routeSourceID.flatMap { projections[$0]?.mapRoutes } ?? projection.mapRoutes
                CompositionMap(camera: Binding(get: { mapCameras[part.id] ?? .automatic }, set: { mapCameras[part.id] = $0 }),
                    partID: part.id, visibilityGeneration: viewportGeneration, occlusions: occlusions, reportViewport: { publishMap($0, status: $1, partID: part.id, generation: viewportGeneration) },
                    fitRequest: mapFitRequests[part.id], finishFit: { id, error in finishMapCommand(id, partID: part.id, error: error) },
                    points: projection.mapPoints, routes: routes, selected: selections[part.selectionGroup] ?? [], height: height, canvas: canvas,
                    select: { select($0, group: part.selectionGroup) },
                    deselect: { selections[part.selectionGroup] = []; canvasAnchors[part.selectionGroup] = nil },
                    selectedLocation: { if canvasAnchors[part.selectionGroup] != $0 { canvasAnchors[part.selectionGroup] = $0 } })
                if !canvas {
                Text(clocks[part.timeGroup]?.mapMode == .windowFootprints && clocks[part.timeGroup]?.window != nil
                     ? "人物仅显示所选区间内时间明确、有独立原文出处的足迹；时间待考的记录不作确定位置。"
                     : clocks[part.timeGroup]?.point != nil
                         ? "人物仅显示光标时刻有独立出处的位置；固定地点的坐标不代表人物曾经到访。"
                         : "全时段显示有独立出处的人物出现记录；固定地点的坐标不代表人物曾经到访。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
                .overlay(alignment: .bottomTrailing) {
                    if canvas, clocks[part.timeGroup]?.window != nil {
                        Picker("人物位置", selection: Binding(get: { clocks[part.timeGroup]?.mapMode ?? .instant }, set: { mode in
                            var clock = clocks[part.timeGroup] ?? CompositionClock(); clock.mapMode = mode; clocks[part.timeGroup] = clock
                        })) {
                            Text("此刻位置").tag(CompositionMapTimeMode.instant)
                            Text("这段时间的已知足迹").tag(CompositionMapTimeMode.windowFootprints)
                        }.pickerStyle(.menu).padding(10).readingGlass(radius: 20).padding(.trailing, 12).padding(.bottom, 54)
                    }
                }
    }
}

private struct CompositionEmptyState: View {
    var text: String
    var icon: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 27)).foregroundStyle(Palette.accent.opacity(0.65))
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }.padding(28).frame(maxWidth: .infinity, minHeight: 150)
    }
}

private struct CompositionObjectTable: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var typography: ReadingTypographySettings
    let items: [CompositionItem]
    let columns: [CompositionTableColumn]
    let selected: Set<String>
    var select: (String) -> Void
    @State private var onlySelected = false
    @State private var detailID: String?
    @State private var evidenceID: String?
    private var visible: [CompositionItem] { onlySelected ? items.filter { selected.contains($0.id) } : items }
    private var valueColumns: [CompositionTableColumn] { columns.filter { $0.field != "name" } }
    private var nameTitle: String { columns.first { $0.field == "name" }?.title ?? "对象" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("仅看所选", isOn: $onlySelected).toggleStyle(.checkbox)
                Spacer(minLength: 8)
                Text("⌘ 点选可同时选择多个对象").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(minHeight: 44)
            if visible.isEmpty {
                CompositionEmptyState(text: onlySelected ? "先从同组列表、图或表中选择要比较的对象。" : "当前范围还没有这个类型的对象。", icon: "tablecells")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(visible) { item in tableRow(item) }
                        } header: {
                            HStack(alignment: .top, spacing: 0) {
                                Text(nameTitle).frame(width: 190, alignment: .leading)
                                ForEach(valueColumns, id: \.field) { column in Text(columnTitle(column)).frame(width: 220, alignment: .leading) }
                                Text("对象依据").frame(width: 160, alignment: .leading)
                            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(14).background(Palette.paper)
                        }
                    }
                }.frame(height: min(480, max(220, CGFloat(visible.count) * 116 + 50)))
            }
            Text("空值表示未记录；依据按对象保存，未单独标注每个字段的来源。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 14)
        }.onChange(of: items.map(\.id)) { _, ids in
            if let detailID, !ids.contains(detailID) { self.detailID = nil }
            if let evidenceID, !ids.contains(evidenceID) { self.evidenceID = nil }
        }
    }
    private func columnTitle(_ column: CompositionTableColumn) -> String {
        if let title = column.title { return title }
        let key = column.field.hasPrefix("properties.") ? String(column.field.dropFirst(11)) : column.field
        return store.book?.types.first { $0.id == items.first?.typeID }?.fields.first { $0.key == key }?.label
            ?? ["name": "对象", "summary": "说明", "kind": "类别", "typeID": "类型", "origin": "笔记来源", "dateText": "原书时间", "phaseOrder": "阶段"][key] ?? key
    }
    private func tableRow(_ item: CompositionItem) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button { select(item.id) } label: {
                    HStack(alignment: .top, spacing: 7) {
                        if selected.contains(item.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                        Text(item.title).font(typography.font(for: .knowledge, weight: .medium)).multilineTextAlignment(.leading).lineLimit(3)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(ReadingQuietButtonStyle())
                Button("完整内容") { detailID = item.id }.font(.caption).buttonStyle(ReadingQuietButtonStyle()).frame(minHeight: 36)
                    .popover(isPresented: Binding(get: { detailID == item.id }, set: { if !$0 { detailID = nil } })) {
                        CompositionObjectDetails(items: items.filter { $0.id == item.id }, selected: [item.id]).frame(width: 480, height: 480)
                    }
            }.frame(width: 190, alignment: .leading)
            ForEach(valueColumns, id: \.field) { column in
                let value = displayValue(column.field, item: item)
                Text(value.map { String($0.prefix(600)) } ?? "未记录").font(typography.font(for: .knowledge))
                    .foregroundStyle(value == nil ? Color.secondary : Palette.ink).lineLimit(5).textSelection(.enabled)
                    .frame(width: 220, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 8) {
                if item.evidence.isEmpty { Text("暂无原文依据").font(.caption).foregroundStyle(.secondary) }
                else {
                    Button("查看 \(item.evidence.count) 处依据") { evidenceID = item.id }
                        .font(.caption).buttonStyle(ReadingQuietButtonStyle()).frame(minHeight: 44)
                        .popover(isPresented: Binding(get: { evidenceID == item.id }, set: { if !$0 { evidenceID = nil } })) {
                            ScrollView { CompositionEvidenceList(evidence: items.first { $0.id == item.id }?.evidence ?? []).padding(18) }
                                .frame(width: 460, height: 440)
                        }
                }
                if let match = item.fields["temporalMatch"], ["unknown", "possible"].contains(match) {
                    Text(match == "unknown" ? "时间未明" : "时间待考").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(width: 160, alignment: .leading)
        }.padding(14).frame(minHeight: 100, alignment: .topLeading)
            .background(selected.contains(item.id) ? Palette.accent.opacity(0.07) : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.opacity(0.5)).frame(height: 0.5) }
    }
    private func displayValue(_ field: String, item: CompositionItem) -> String? {
        if field == "properties.dateText", item.kind == "event", let extent = item.extent { return TemporalDatePresentation.summary(extent) }
        guard let value = CompositionRuntime.tableValue(field, in: item) else { return nil }
        if field == "kind" { return ["entity": "要素", "event": "事件", "document": "笔记"][value] ?? "要素" }
        if field == "typeID" { return store.book?.types.first { $0.id == value }?.name ?? ["event": "事件", "document": "笔记"][value] ?? "要素" }
        if field == "origin" { return ["user": "我的笔记", "saved-answer": "保存的 AI 回答", "ai": "保存的 AI 回答", "import": "导入笔记"][value] ?? value }
        return value
    }
}

private struct CompositionObjectList: View {
    let items: [CompositionItem]
    let selected: Set<String>
    var select: (String) -> Void
    @State private var search = ""
    private var filtered: [CompositionItem] { items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "magnifyingglass").readingSearchIcon()
                TextField("查找要素", text: $search).readingSearchInput()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 48, height: 48) }.buttonStyle(ReadingQuietButtonStyle()).accessibilityLabel("清空搜索") }
            }.padding(.horizontal, 14).frame(minHeight: 48).background(Palette.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).padding(12)
            if filtered.isEmpty { CompositionEmptyState(text: search.isEmpty ? "当前范围还没有这类要素。" : "没有匹配的要素。", icon: "rectangle.stack") }
            else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filtered) { item in
                            let id = item.objectID ?? item.documentID ?? item.id
                            Button { select(id) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    RoundedRectangle(cornerRadius: 10).fill(Palette.accent.opacity(0.1)).frame(width: 40, height: 40)
                                        .overlay { Image(systemName: item.kind == "event" ? "flag" : item.documentID != nil ? "doc.text" : "square.stack").foregroundStyle(Palette.accent) }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(2)
                                        if !item.summary.isEmpty { Text(item.summary).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if selected.contains(id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                                }.padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                    .background(Palette.accent.opacity(selected.contains(id) ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 15)).contentShape(Rectangle())
                            }.buttonStyle(ReadingQuietButtonStyle())
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }.frame(maxHeight: 420)
            }
        }
    }
}

private struct CompositionObjectDetails: View {
    @EnvironmentObject private var store: AppStore
    let items: [CompositionItem]
    let selected: Set<String>
    @State private var showsInspector = false
    private var item: CompositionItem? { items.first { selected.contains($0.objectID ?? $0.documentID ?? $0.id) } ?? (items.count == 1 ? items.first : nil) }
    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.title).font(.system(size: 27, weight: .semibold, design: .serif)).textSelection(.enabled)
                    if let objectID = item.objectID, item.kind == "entity" || item.kind == "event" {
                        HStack {
                            KnowledgeOwnershipBadge(id: objectID, kind: item.kind == "event" ? .event : .entity)
                            Spacer()
                            Button { showsInspector = true } label: { Label("核对与修正", systemImage: "square.and.pencil").frame(minHeight: 40) }
                                .buttonStyle(ReadingQuietButtonStyle()).help("打开共享资料；修正后这里和其他组件同步更新。")
                                .popover(isPresented: $showsInspector) { ObjectInspector(id: objectID, onClose: { showsInspector = false }).frame(width: 470, height: 580) }
                        }
                    }
                    if !item.summary.isEmpty { MarkdownText(markdown: item.summary) }
                    if let match = item.fields["temporalMatch"], ["possible", "unknown"].contains(match) {
                        Label(match == "possible" ? "可能在这一时期" : "时间尚未确定", systemImage: "clock.badge.questionmark").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(item.fields.keys.filter { $0 != "temporalMatch" }.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(fieldLabel(key, item: item)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            if key == "dateText", item.kind == "event", let extent = item.extent {
                                Text(TemporalDatePresentation.summary(extent)).help(extent.explanation ?? "保留原书历法与原有确定性，没有换算或补造日期。")
                            } else { MarkdownText(markdown: fieldValue(key, value: item.fields[key] ?? "")) }
                        }
                    }
                    if let extent = item.extent, !extent.sourceText.isEmpty { Label(extent.sourceText, systemImage: "clock").font(.callout).foregroundStyle(.secondary) }
                    CompositionEvidenceList(evidence: item.evidence)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 460)
        } else { CompositionEmptyState(text: "选择一个要素，查看它的内容和原文依据。", icon: "text.rectangle") }
    }
    private func fieldLabel(_ key: String, item: CompositionItem) -> String {
        store.book?.types.first { $0.id == item.typeID }?.fields.first { $0.key == key }?.label
            ?? ["dateText": "原书时间", "kind": "类别", "phaseOrder": "阶段", "origin": "笔记来源"][key] ?? key
    }
    private func fieldValue(_ key: String, value: String) -> String {
        key == "origin" ? (["user": "我的笔记", "ai": "保存的 AI 回答", "import": "导入笔记"][value] ?? value) : value
    }
}

private struct CompositionEvidenceList: View {
    @EnvironmentObject private var store: AppStore
    var evidence: [Evidence]
    @State private var shown = 4
    var body: some View {
        if !evidence.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(evidence.prefix(shown).enumerated()), id: \.offset) { _, evidence in
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownText(markdown: evidence.quote).readingTextContext(.source)
                        Button { store.follow(evidence) } label: {
                            Label(store.book?.units.first { $0.id == evidence.unitID }?.locator ?? "查看原文", systemImage: "arrow.uturn.backward").frame(minHeight: 48)
                        }.buttonStyle(ReadingToolbarButtonStyle()).foregroundStyle(Palette.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if shown < evidence.count {
                    Button { shown += 4 } label: {
                        Label("再显示 \(min(4, evidence.count - shown)) 处依据（共 \(evidence.count) 处）", systemImage: "chevron.down").frame(minHeight: 48)
                    }.buttonStyle(ReadingToolbarButtonStyle())
                }
            }.onChange(of: evidence) { _, _ in shown = 4 }
        }
    }
}

private struct CompositionExcerpts: View {
    var items: [CompositionItem]
    private var evidence: [Evidence] {
        var seen = Set<Evidence>()
        return items.flatMap(\.evidence).filter { seen.insert($0).inserted }
    }
    var body: some View {
        if evidence.isEmpty { CompositionEmptyState(text: "当前选择没有可定位的原文依据。", icon: "quote.opening") }
        else { ScrollView { CompositionEvidenceList(evidence: evidence).padding(16) }.frame(maxHeight: 440) }
    }
}

private struct CompositionMarkdown: View {
    @EnvironmentObject private var store: AppStore
    let items: [CompositionItem]
    let selected: Set<String>
    @State private var chosen: String?
    @State private var markdown: String?
    @State private var issue: String?
    @State private var loadedRequest: DocumentRequest?
    private struct DocumentRequest: Hashable {
        let libraryRoot: URL
        let bookID: String
        let sourceHash: String
        let documentID: String
        let relativePath: String
        let updatedAt: Date
    }
    private var ids: [String] {
        var seen = Set<String>()
        return items.compactMap(\.documentID).filter { seen.insert($0).inserted }
    }
    private var documentID: String? { chosen.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first(where: selected.contains) ?? ids.first }
    private var document: DocumentRecord? { store.book?.activeDocuments.first { $0.id == documentID } }
    private var loadRequest: DocumentRequest? {
        guard let book = store.book, let document else { return nil }
        return DocumentRequest(libraryRoot: store.libraryRootURL, bookID: book.id, sourceHash: book.sourceHash,
            documentID: document.id, relativePath: document.relativePath, updatedAt: document.updatedAt)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ids.count > 1 {
                Picker("笔记", selection: Binding(get: { documentID ?? "" }, set: { chosen = $0 })) {
                    ForEach(ids, id: \.self) { id in Text(items.first { $0.documentID == id }?.title ?? "笔记").tag(id) }
                }.labelsHidden().pickerStyle(.menu).frame(minHeight: 48).padding(.horizontal, 16)
            }
            if let document {
                HStack {
                    Text(document.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(2)
                    Spacer()
                    Button { Task { await store.openDocument(document) } } label: { Image(systemName: "arrow.up.right").frame(width: 48, height: 48) }
                        .buttonStyle(ReadingQuietButtonStyle()).help("打开这篇笔记").accessibilityLabel("打开这篇笔记")
                }.padding(.horizontal, 18)
                if loadedRequest == loadRequest, let issue { Text(issue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(20) }
                else if loadedRequest == loadRequest, let markdown { ScrollView { MarkdownText(markdown: markdown).readingTextContext(.notes).padding(20) }.frame(maxHeight: 460) }
                else { ProgressView().frame(maxWidth: .infinity, minHeight: 150) }
            } else { CompositionEmptyState(text: "这里显示已关联、主动保存的 Markdown 笔记。", icon: "doc.text") }
        }.task(id: loadRequest) { await load() }.onChange(of: selected) { _, _ in chosen = nil }
    }
    private func load() async {
        markdown = nil; issue = nil; loadedRequest = nil
        guard let request = loadRequest, let document, ids.contains(document.id) else { return }
        let repository = store.repository
        do {
            let value = try await repository.readDocument(bookID: request.bookID, document: document)
            try Task.checkCancellation()
            guard loadRequest == request else { return }
            markdown = value; loadedRequest = request
        } catch is CancellationError {} catch {
            if !Task.isCancelled, loadRequest == request { issue = error.localizedDescription; loadedRequest = request }
        }
    }
}

private struct CompositionMapFitRequest: Equatable {
    let id: UUID
    let objectIDs: Set<String>
    let generation: UInt64
}

private struct CompositionMap: View {
    @Environment(\.workspaceCanvasBlocked) private var workspaceBlocked
    @Environment(\.workspaceCanvasExclusionRects) private var workspaceExclusions
    @Binding var camera: MapCameraPosition
    let partID: String
    let visibilityGeneration: UInt64
    let occlusions: [CGRect]
    var reportViewport: (ReadingMapViewport?, ReadingWorkspaceObservationStatus) -> Void
    var fitRequest: CompositionMapFitRequest?
    var finishFit: (UUID, String?) -> Void
    let points: [CompositionMapPoint]
    let routes: [SpatialRoute]
    let selected: Set<String>
    var height: CGFloat = 420
    var canvas = false
    var select: (String) -> Void
    var deselect: () -> Void = {}
    var selectedLocation: (CGPoint?) -> Void = { _ in }
    @State private var inspectedRoute: SpatialRoute?
    @State private var cameraRegion: MKCoordinateRegion?
    @State private var moving = false
    @State private var markerNodes: [SpatialMarkerNode] = []
    @State private var markerSeeds: [SpatialMarkerSeed] = []
    @State private var markerGroup: [SpatialMarkerSeed]?
    @State private var legendSize: CGSize = .zero
    @State private var markerEpoch: UInt64 = 0
    @State private var selectedMarker: SpatialMarkerSeed?
    @State private var pendingFitID: UUID?
    private var seeds: [SpatialMarkerSeed] { SpatialMarkerSeeds.make(points: points, routes: routes) }
    private var nodes: [SpatialMarkerNode] { markerSeeds == seeds ? markerNodes : SpatialMarkerPacking.bootstrap(seeds, selectedObjectIDs: selected, selectedRouteID: inspectedRoute?.relationID) }
    var body: some View {
        if points.isEmpty && routes.isEmpty { CompositionEmptyState(text: "当前范围和时间没有已确认的位置。人物仅显示有出处的出现地点。", icon: "map").task(id: visibilityGeneration) { reportViewport(nil, .empty) } }
        else {
            GeometryReader { geometry in MapReader { proxy in
            Map(position: $camera) {
                SpatialMapRoutes(routes: routes, inspected: $inspectedRoute, selectEvent: select, showsMarkers: false)
                SpatialMapAnnotations(nodes: nodes) { node in
                    if node.isGroup { inspectedRoute = nil; markerGroup = node.members }
                    else if let seed = node.members.first { activate(seed, using: proxy, offset: .init(x: node.offsetX, y: node.offsetY)) }
                }
            }
                .background(CompositionPageScrollInput())
                .mapControls { MapCompass(); MapScaleView() }.frame(height: height).clipShape(RoundedRectangle(cornerRadius: canvas ? 0 : 18))
                    .help(canvas ? "拖动或双指平移地图，捏合缩放；点标记看详情，点空白收起。" : "双指滑动浏览整页；拖动平移地图，捏合缩放地图。")
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        SpatialMarkerLegend(seeds: seeds).padding(.leading, 12).padding(.top, 12)
                        SpatialRouteTimeNotice(routes: routes)
                    }
                }
                .onPreferenceChange(SpatialMarkerLegendSize.self) { size in legendSize = size; publishViewport(using: proxy, geometry: geometry) }
                .overlay(alignment: .topTrailing) {
                    if let group = markerGroup {
                        SpatialMarkerGroupCard(members: group, select: { activate($0, using: proxy) }, zoom: {
                            markerGroup = nil
                            if let region = spatialMarkerGroupRegion(group) { camera = .region(region) }
                        }, close: { markerGroup = nil }).padding(.top, canvas ? 70 : 8).padding(.trailing, 12)
                    }
                }
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    guard canvas, !selected.isEmpty || markerGroup != nil || inspectedRoute != nil else { return }
                    // Native annotation buttons keep their own click. Only a
                    // tap away from all annotation targets is canvas dismissal.
                    guard !nodes.contains(where: { node in
                        guard let p = proxy.convert(node.coordinate.mapCoordinate, to: .local) else { return false }
                        let x = p.x + node.offsetX, y = p.y + node.offsetY
                        return CGRect(x: x - (node.showsTitle ? 18 : 36), y: y - 24, width: node.showsTitle ? 172 : 72, height: 48).contains(tap.location)
                    }) else { return }
                    markerGroup = nil; inspectedRoute = nil; selectedLocation(nil); deselect()
                })
                .onMapCameraChange(frequency: .continuous) { _ in
                    if !moving { moving = true; reportViewport(nil, .pending) }
                    if canvas { reportLocation(using: proxy) }
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    cameraRegion = context.region; moving = false
                    // Keep the actual camera while replacing annotations; an
                    // automatic fit must not zoom itself into a merged badge.
                    if camera == .automatic { camera = .camera(context.camera) }
                    rebuildMarkers(using: proxy, size: geometry.size)
                    markerEpoch &+= 1
                    publishViewport(using: proxy, geometry: geometry)
                    if let id = pendingFitID { pendingFitID = nil; finishFit(id, nil) }
                }
                .task(id: markerEpoch) {
                    guard markerEpoch > 0 else { return }
                    // Retry only the settled screen transform, never book
                    // queries or AI requests. A new camera cancels this task.
                    for _ in 0..<6 {
                        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                        if rebuildMarkers(using: proxy, size: geometry.size) { publishViewport(using: proxy, geometry: geometry); return }
                    }
                }
                .onChange(of: workspaceBlocked) { _, _ in publishViewport(using: proxy, geometry: geometry) }
                .onChange(of: workspaceExclusions) { _, _ in publishViewport(using: proxy, geometry: geometry) }
                .onChange(of: occlusions) { _, _ in publishViewport(using: proxy, geometry: geometry) }
                .onChange(of: visibilityGeneration) { _, _ in
                    // Switching calendar/source clocks can keep identical
                    // annotations and camera geometry. Still retry the new
                    // generation's screen transform; no camera-end or seed
                    // change is otherwise guaranteed to publish readiness.
                    rebuildMarkers(using: proxy, size: geometry.size); markerEpoch &+= 1
                    publishViewport(using: proxy, geometry: geometry)
                }
                .onChange(of: fitRequest) { _, request in fit(request, geometry: geometry) }
                .onChange(of: geometry.size) { _, _ in rebuildMarkers(using: proxy, size: geometry.size); markerEpoch &+= 1; publishViewport(using: proxy, geometry: geometry) }
                .onChange(of: seeds) { _, _ in markerGroup = nil; rebuildMarkers(using: proxy, size: geometry.size); markerEpoch &+= 1; publishViewport(using: proxy, geometry: geometry) }
                .onChange(of: markerGroup) { _, _ in publishViewport(using: proxy, geometry: geometry) }
                .onChange(of: inspectedRoute) { _, _ in rebuildMarkers(using: proxy, size: geometry.size); markerEpoch &+= 1; publishViewport(using: proxy, geometry: geometry) }
                .onChange(of: selected) { _, ids in
                    rebuildMarkers(using: proxy, size: geometry.size)
                    markerEpoch &+= 1
                    if canvas {
                        reportLocation(using: proxy)
                        if let point = screenPoint(ids, using: proxy), CGRect(origin: .zero, size: geometry.size).contains(point) {
                            // Selecting a visible marker keeps the map still.
                        } else if !ids.isEmpty, screenPoint(ids, using: proxy) != nil { locate(ids) }
                    } else { locate(ids) }
                }.onChange(of: points) { _, _ in
                    publishViewport(using: proxy, geometry: geometry)
                    if !camera.positionedByUser { if selected.isEmpty { camera = .automatic } else { locate(selected) } }
                }
            } }.frame(height: height).padding(canvas ? 0 : 8)
                .overlay(alignment: .topTrailing) {
                    if let route = inspectedRoute {
                        VStack(spacing: 0) {
                            HStack {
                                Text("行动与原文依据").font(.subheadline.weight(.medium))
                                Spacer()
                                Button { inspectedRoute = nil } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                                    .buttonStyle(ReadingQuietButtonStyle()).help("关闭路线详情").accessibilityLabel("关闭路线详情")
                            }.padding(.horizontal, 12).padding(.top, 4)
                            SpatialRouteDetails(route: route)
                        }.frame(width: 380, height: min(520, max(220, height - (canvas ? 370 : 32))))
                            .readingGlass(radius: 22).shadow(color: .black.opacity(0.12), radius: 16, y: 5)
                            .padding(.top, canvas ? 70 : 8).padding(.trailing, 12)
                            .accessibilityIdentifier("composition-route-details")
                    }
                }
        }
    }
    private func fit(_ request: CompositionMapFitRequest?, geometry: GeometryProxy) {
        pendingFitID = nil
        guard let request else { return }
        guard !workspaceBlocked, request.generation == visibilityGeneration else {
            finishFit(request.id, "地图不可操作或内容已变化。"); return
        }
        let matches = points.filter { request.objectIDs.contains($0.targetID) }.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            + routes.filter { $0.eventID.map(request.objectIDs.contains) == true }.flatMap { $0.coordinates.map(\.mapCoordinate) }
        guard let south = matches.map(\.latitude).min(), let north = matches.map(\.latitude).max(),
              let west = matches.map(\.longitude).min(), let east = matches.map(\.longitude).max() else {
            finishFit(request.id, "这些对象不在当前地图投影内。"); return
        }
        let northwest = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: west))
        let southeast = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: east))
        let minimum = MKMapSize.world.width * 0.3 / 360
        let contentWidth = max(minimum, abs(southeast.x - northwest.x) * 1.3)
        let contentHeight = max(minimum, abs(southeast.y - northwest.y) * 1.3)
        guard let available = SpatialViewportVisibility.availableRect(in: CGRect(origin: .zero, size: geometry.size),
            excluding: mapExclusions(geometry), padding: 28, contentAspectRatio: contentWidth / contentHeight), available.width >= 60, available.height >= 60 else {
            finishFit(request.id, "地图可见空间被悬浮卡片遮挡，请先收起卡片；未把遮挡当作可见。"); return
        }
        let scale = max(contentWidth / available.width, contentHeight / available.height)
        let size = MKMapSize(width: geometry.size.width * scale, height: geometry.size.height * scale)
        // Place the fitted content in usable space, not underneath a floating
        // inspector. Map points include Mercator projection and retain aspect.
        let center = MKMapPoint(x: (northwest.x + southeast.x) / 2 - (available.midX - geometry.size.width / 2) * scale,
                                y: (northwest.y + southeast.y) / 2 - (available.midY - geometry.size.height / 2) * scale)
        let rect = MKMapRect(origin: MKMapPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), size: size)
        let target = MapCameraPosition.rect(rect)
        if camera == target, !moving { finishFit(request.id, nil) }
        else { pendingFitID = request.id; camera = target }
    }
    @discardableResult private func rebuildMarkers(using proxy: MapProxy, size: CGSize) -> Bool {
        guard !moving, let region = cameraRegion else { return false }
        let values = seeds
        guard let layout = spatialMarkerLayout(seeds: values, proxy: proxy, size: size, selected: selected,
            routeID: inspectedRoute?.relationID, showTitles: region.span.longitudeDelta < 1.5) else { return false }
        if markerNodes != layout { markerNodes = layout }
        if markerSeeds != values { markerSeeds = values }
        return true
    }
    private func activate(_ seed: SpatialMarkerSeed, using proxy: MapProxy, offset: CGPoint = .zero) {
        markerGroup = nil
        selectedMarker = seed
        if let routeID = seed.routeID, let route = routes.first(where: { $0.relationID == routeID }) {
            inspectedRoute = route
            if let id = route.eventID { select(id) }
        } else if let id = seed.objectID {
            inspectedRoute = nil
            selectedLocation(canvas ? proxy.convert(seed.coordinate.mapCoordinate, to: .local).map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) } : nil)
            select(id)
        }
    }
    private func publishViewport(using proxy: MapProxy, geometry: GeometryProxy) {
        guard !workspaceBlocked, inspectedRoute == nil, markerGroup == nil else { reportViewport(nil, .obscured); return }
        guard !moving, let region = cameraRegion else { reportViewport(nil, .pending); return }
        guard seeds.isEmpty || seeds.contains(where: { proxy.convert($0.coordinate.mapCoordinate, to: .local) != nil }) else { reportViewport(nil, .pending); return }
        let viewport = CGRect(origin: .zero, size: geometry.size)
        let exclusions = mapExclusions(geometry)
        let visibleNodes = nodes.filter { node in
            guard let screen = proxy.convert(node.coordinate.mapCoordinate, to: .local) else { return false }
            return SpatialViewportVisibility.contains(.init(x: screen.x + node.offsetX, y: screen.y + node.offsetY), in: viewport, excluding: exclusions)
        }
        let objects = visibleNodes.filter { !$0.isGroup }.compactMap { $0.members.first?.objectID }
        let groups = visibleNodes.filter(\.isGroup).map { node in
            ReadingMapMarkerGroup(id: node.id, objectIDs: Array(Set(node.members.compactMap(\.objectID))).sorted(), routeIDs: Array(Set(node.members.compactMap(\.routeID))).sorted())
        }
        let visibleRoutes = routes.filter { route in
            let path = route.coordinates.compactMap { proxy.convert($0.mapCoordinate, to: .local) }
            // Missing projection points cannot prove a continuous visible path.
            return path.count == route.coordinates.count && SpatialViewportVisibility.intersects(path, viewport: viewport, excluding: exclusions)
        }.map(\.relationID)
        reportViewport(ReadingMapViewport(partID: partID, latitude: region.center.latitude, longitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta,
            objectIDs: Array(Set(objects)).sorted(), visibleRouteIDs: Array(Set(visibleRoutes)).sorted(), projectedRouteIDs: Array(Set(routes.map(\.relationID))).sorted(), markerGroups: groups), .ready)
    }
    private func mapExclusions(_ geometry: GeometryProxy) -> [CGRect] {
        let origin = geometry.frame(in: .global).origin
        return occlusions + workspaceExclusions.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            + [CGRect(x: 12, y: 12, width: legendSize.width, height: legendSize.height),
               CGRect(x: 12, y: legendSize.height + 28, width: 160, height: routes.contains(where: { $0.timeMatch == .unknown }) ? 40 : 0)]
    }
    private func screenPoint(_ ids: Set<String>, using proxy: MapProxy) -> CGPoint? {
        // An event can be recorded at several places. Keep the exact marker
        // clicked by the reader, rather than jumping to that event's first place.
        if let marker = selectedMarker, seeds.contains(where: { $0.id == marker.id }),
           marker.objectID.map(ids.contains) == true || (inspectedRoute?.eventID.map(ids.contains) == true && marker.routeID == inspectedRoute?.relationID) {
            return proxy.convert(marker.coordinate.mapCoordinate, to: .local)
        }
        guard let point = points.first(where: { ids.contains($0.targetID) }) else { return nil }
        return proxy.convert(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), to: .local)
    }
    private func reportLocation(using proxy: MapProxy) { selectedLocation(screenPoint(selected, using: proxy)) }
    private func locate(_ ids: Set<String>) {
        if let point = points.first(where: { ids.contains($0.targetID) }) {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 3)))
        }
    }
}

private struct CompositionClock: Equatable {
    var axis: String?
    var lower: Double?
    var upper: Double?
    var cursor: Double?
    var mapMode: CompositionMapTimeMode = .instant
    var point: TemporalQueryPoint? {
        guard let axis, let cursor else { return nil }; return TemporalAxis(axis).point(cursor)
    }
    var window: TemporalQueryWindow? {
        guard let axis, let lower, let upper else { return nil }; return TemporalAxis(axis).window(from: lower, to: upper)
    }
}

private struct CompositionTimeline: View {
    @EnvironmentObject private var typography: ReadingTypographySettings
    let items: [CompositionItem]
    let selected: Set<String>
    @Binding var clock: CompositionClock
    var compact = false
    var select: (String) -> Void
    var selectStage: ((String) -> Void)? = nil
    private var extents: [[TemporalExtent]] { items.map { [$0.extent, $0.sourceExtent].compactMap { $0 } } }
    private var axes: [String] { TemporalAxis.available(extents.flatMap { $0 }) }
    private var axis: String { clock.axis.flatMap { axes.contains($0) ? $0 : nil } ?? TemporalAxis.preferred(for: extents) ?? "" }
    private func value(_ item: CompositionItem, end: Bool = false) -> Double? {
        TemporalAxis(axis).value(axis == "narrative-domain:source-order" ? item.sourceExtent ?? item.extent : item.extent, end: end)
    }
    private var phases: [CompositionItem] {
        items.filter { $0.references["parentEvent"]?.count == 1 && Int($0.fields["phaseOrder"] ?? "") != nil }
            .sorted { lhs, rhs in
                let a = lhs.references["parentEvent"]?.first ?? "", b = rhs.references["parentEvent"]?.first ?? ""
                return (a, Int(lhs.fields["phaseOrder"] ?? "") ?? 0, lhs.id) < (b, Int(rhs.fields["phaseOrder"] ?? "") ?? 0, rhs.id)
            }
    }
    private var bounds: ClosedRange<Double> {
        let values = items.flatMap { [value($0), value($0, end: true)].compactMap { $0 } }
        return (values.min() ?? 0)...max(values.min() ?? 0, values.max() ?? 1)
    }
    private var lower: Double { min(bounds.upperBound, max(bounds.lowerBound, clock.lower ?? bounds.lowerBound)) }
    private var upper: Double { min(bounds.upperBound, max(lower, clock.upper ?? bounds.upperBound)) }
    private var cursor: Double { min(upper, max(lower, clock.cursor ?? lower)) }
    private var events: [KnowledgeEvent] {
        items.compactMap { item in
            guard let start = value(item) else { return nil }
            return KnowledgeEvent(id: item.objectID ?? item.id, name: item.title, startYear: Int(start), endYear: value(item, end: true).map(Int.init))
        }
    }
    var body: some View {
        if axes.isEmpty { CompositionEmptyState(text: "还没有可比较的时间记录。原书纪年会保留，不擅自换算为公历。", icon: "clock") }
        else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("时间轴", selection: Binding(get: { axis }, set: { clock = CompositionClock(axis: $0, mapMode: clock.mapMode) })) {
                        ForEach(axes, id: \.self) { Text(TemporalAxis($0).title).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize(horizontal: true, vertical: false).frame(minHeight: 44)
                    if !phases.isEmpty {
                        GeometryReader { geometry in
                            let chipWidth = min(208, max(112, geometry.size.width * 0.6))
                            ScrollView(.horizontal) {
                                HStack(spacing: 6) {
                                    ForEach(phases) { item in
                                        Button {
                                            guard let window = ReadingEventPresentationPlan.sourceWindow(item.sourceExtent) else { return }
                                            if let selectStage { selectStage(item.objectID ?? item.id) }
                                            else {
                                                clock = CompositionClock(axis: window.axis, lower: window.from,
                                                    upper: window.to, cursor: window.cursor, mapMode: clock.mapMode)
                                                select(item.objectID ?? item.id)
                                            }
                                        } label: {
                                            Text(item.fields["phaseOrder", default: ""] + " " + item.title)
                                                .lineLimit(1).truncationMode(.tail).frame(width: chipWidth, alignment: .leading)
                                        }
                                        .buttonStyle(ReadingToolbarButtonStyle())
                                        .disabled(item.sourceExtent == nil)
                                        .accessibilityLabel("查看阶段：" + item.title)
                                        .help(item.title + "\n按这一阶段的原文出处筛选地图与行动；不会改写已有日期")
                                    }
                                }
                            }.scrollIndicators(.hidden)
                        }.frame(minWidth: 80).frame(height: 44)
                    } else { Spacer(minLength: 0) }
                    if clock.point != nil {
                        Button { clock = CompositionClock() } label: { Text("全时段").fixedSize().frame(minHeight: 44) }.buttonStyle(ReadingToolbarButtonStyle())
                    } else { Text("全时段").font(.caption).foregroundStyle(.secondary).fixedSize() }
                }
                TimelineRangeControl(lower: Binding(get: { lower }, set: { update(lower: $0) }),
                    upper: Binding(get: { upper }, set: { update(upper: $0) }), bounds: bounds,
                    events: events, selectedID: selected.sorted().first, select: select,
                    cursor: Binding(get: { cursor }, set: { update(cursor: $0) }), label: label)
                if !compact {
                    Text(axis == "narrative-domain:source-order" ? "按原文出处先后筛选，不等同于史事日期；阶段可点选。" : "两端筛选事件和行动箭头；光标查看人物此时的位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !compact, let item = items.first(where: { selected.contains($0.objectID ?? $0.id) }) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.title).font(.system(size: 17, weight: .medium))
                        if let extent = item.extent {
                            Text(TemporalDatePresentation.summary(extent)).font(.caption).foregroundStyle(.secondary)
                                .help(extent.explanation ?? "保留原书历法与原有确定性，没有换算或补造日期。")
                        }
                        if !item.summary.isEmpty { Text(item.summary).font(typography.font(for: .knowledge)).lineLimit(4) }
                        CompositionEvidenceList(evidence: item.evidence)
                    }.padding(.top, 10)
                }
            }.padding(compact ? 12 : 18)
                .help(axis == "narrative-domain:source-order" ? "按原文出处先后筛选，不等同于史事日期；阶段可点选。" : "两端筛选事件和行动箭头；光标查看人物此时的位置。")
        }
    }
    private func label(_ value: Double) -> String { TemporalAxis(axis).label(value) }
    private func update(lower nextLower: Double? = nil, upper nextUpper: Double? = nil, cursor nextCursor: Double? = nil) {
        let temporal = TemporalAxis(axis), extents = self.extents.flatMap { $0 }
        let lo = min(upper, max(bounds.lowerBound, nextLower.map { temporal.snapped($0, among: extents) } ?? lower))
        let hi = max(lo, min(bounds.upperBound, nextUpper.map { temporal.snapped($0, among: extents) } ?? upper))
        let position = nextCursor.map { temporal.snapped($0, among: extents) } ?? cursor
        clock = CompositionClock(axis: axis, lower: lo, upper: hi, cursor: min(hi, max(lo, position)), mapMode: clock.mapMode)
    }
}

private struct CompositionGraph: View {
    @EnvironmentObject private var store: AppStore
    let partID: String
    let viewID: String
    let projection: CompositionProjection
    let selected: Set<String>
    let documents: Bool
    let width: CGFloat
    var select: (String) -> Void
    var deselect: () -> Void
    @State private var positions: [String: CGPoint] = [:]
    @State private var showsRelationEvidence = false
    @State private var shownRelations = 24
    private struct SourcePosition: Hashable { var x: Double; var y: Double }
    private var items: [GraphItem] {
        let origins: [String: SourcePosition] = Dictionary(uniqueKeysWithValues: projection.items.compactMap { item -> (String, SourcePosition)? in
            guard documents, let physical = store.book?.nodes.first(where: { node in
                if let id = item.documentID { return node.targetID == id || (node.documentIDs ?? []).contains(id) }
                return node.id == item.id
            }) else { return nil }
            return (item.id, SourcePosition(x: physical.x, y: physical.y))
        })
        let sharedOrigins = Dictionary(grouping: origins.keys, by: { origins[$0]! })
        return projection.items.enumerated().map { index, item in
            let angle = Double(index) * 2.399963229728653, radius = max(150, sqrt(Double(index + 1)) * 115)
            let sourcePoint = origins[item.id].map { origin -> CGPoint in
                let siblings = (sharedOrigins[origin] ?? []).sorted()
                let slot = siblings.firstIndex(of: item.id) ?? 0
                // One physical node may mount several Markdown documents. The
                // composed graph projects one card per document, so give cards
                // sharing that origin stable local slots; never rewrite nodes.
                return CGPoint(x: origin.x + Double(slot % 3) * 280, y: origin.y + Double(slot / 3) * 180)
            }
            let point = positions[item.id] ?? sourcePoint ?? CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            let uncertainty = item.fields["temporalMatch"] == "unknown" ? "时间未明" : item.fields["temporalMatch"] == "possible" ? "时间待考" : "书中要素"
            return GraphItem(id: item.id, targetID: item.objectID ?? item.documentID ?? item.id, title: item.title,
                subtitle: item.documentID == nil ? uncertainty : "Markdown", x: point.x, y: point.y,
                documentIDs: item.documentID.map { [$0] } ?? [])
        }
    }
    private var lines: [GraphLine] {
        let ids = Set(items.map(\.id))
        return projection.edges.filter { ids.contains($0.fromID) && ids.contains($0.toID) }.map { edge in
            let uncertainty = edge.temporalMatch == .possible ? " · 时间待考" : edge.temporalMatch == .unknown ? " · 时间未明" : ""
            return GraphLine(id: edge.id, from: edge.fromID, to: edge.toID, label: edge.label + uncertainty)
        }
    }
    var body: some View {
        if items.isEmpty { CompositionEmptyState(text: documents ? "当前范围没有已保存的文档节点。" : "当前选择和时间没有可显示的关系。", icon: "point.3.connected.trianglepath.dotted") }
        else {
            VStack(alignment: .leading, spacing: 8) {
            GraphSurface(items: items, lines: lines, selectedID: selected.sorted().first, select: select,
                open: { id in
                    if let document = store.book?.activeDocuments.first(where: { $0.id == id }), projection.items.contains(where: { $0.documentID == id }) {
                        Task { await store.openDocument(document) }
                    } else { select(id) }
                }, move: { id, x, y in positions[id] = CGPoint(x: x, y: y); return true },
                deselect: deselect, title: "composition.\(viewID).\(partID)", isEnabled: !store.isBusy, ambientMotion: !documents)
                .frame(height: max(340, min(520, width * 0.65))).clipShape(RoundedRectangle(cornerRadius: 18)).padding(8)
                .onChange(of: store.bookID) { _, _ in positions = [:] }
            if !documents, !projection.edges.isEmpty {
                DisclosureGroup("关系与依据 · \(projection.edges.count)", isExpanded: $showsRelationEvidence) {
                    if showsRelationEvidence {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(projection.edges.prefix(shownRelations))) { edge in
                                DisclosureGroup {
                                    CompositionEvidenceList(evidence: edge.evidence)
                                } label: {
                                    Text(relationTitle(edge)).font(.system(size: 14)).textSelection(.enabled)
                                }
                            }
                            if shownRelations < projection.edges.count {
                                Button("继续显示关系依据") { shownRelations += 24 }.buttonStyle(ReadingQuietButtonStyle()).frame(minHeight: 44)
                            }
                        }.padding(.top, 10)
                    }
                }.font(.caption).padding(.horizontal, 16).padding(.bottom, 12)
            }
            }.onChange(of: projection.edges.map(\.id)) { _, _ in shownRelations = 24 }
        }
    }
    private func relationTitle(_ edge: CompositionEdge) -> String {
        let from = projection.items.first { $0.id == edge.fromID }?.title ?? "当前对象"
        let to = projection.items.first { $0.id == edge.toID }?.title ?? "当前对象"
        let uncertainty = edge.temporalMatch == .possible ? " · 时间待考" : edge.temporalMatch == .unknown ? " · 时间未明" : ""
        return from + " → " + edge.label + " → " + to + uncertainty
    }
}
