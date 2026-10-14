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

struct SpatialTimelineView: View {
    @EnvironmentObject var store: AppStore
    @State private var camera: MapCameraPosition = .automatic
    @State private var showingEvents = false
    @State private var editingRange = false
    @State private var fromText = ""
    @State private var toText = ""
    @State private var rangeError = ""
    @State private var eventQuery = ""
    private var filteredEvents: [KnowledgeEvent] {
        store.visibleEvents.filter { eventQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(eventQuery) || $0.dateText.localizedCaseInsensitiveContains(eventQuery) || $0.participantIDs.contains(where: { store.objectTitle($0).localizedCaseInsensitiveContains(eventQuery) }) }
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
        // Focus may expand a selected event by two years. Keep that within the
        // axis so the labels, handles and accessibility value always agree.
        return (Double(first) - 5)...(Double(last) + 5)
    }
    var body: some View {
        VStack(spacing: 0) {
            CompactWorkspaceHeader("时空", subtitle: "\(store.visibleEvents.count) 个事件 · \(points.count) 个标记") {
                Button { showingEvents.toggle() } label: { Label("事件", systemImage: "list.bullet") }
                    .popover(isPresented: $showingEvents) { eventList }
                Menu {
                    Toggle("保留时间待考事件", isOn: $store.showUndated)
                    Button("地图适合全部标记") { camera = .automatic }
                } label: { Image(systemName: "line.3.horizontal.decrease") }.help("时间与地图选项")
            }
            Map(position: $camera) {
                ForEach(points) { point in
                    Annotation("", coordinate: point.coordinate) {
                        mapMarker(point)
                    }
                }
            }.mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
                .overlay(alignment: .topLeading) {
                    if points.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("暂无可定位的地点").font(.subheadline.weight(.medium))
                            Text(store.visibleEvents.isEmpty ? "当前时间范围没有事件，可调整端点或查看全部时间。" : "事件仍保留在清单中；有依据的坐标补齐后显示在地图。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(12).frame(maxWidth: 280, alignment: .leading).readingGlass().padding(12)
                    }
                }
                .onChange(of: store.selectedObjectID) { _, id in
                    if let point = points.first(where: { $0.targetID == id }) {
                        withAnimation { camera = .region(MKCoordinateRegion(center: point.coordinate, span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))) }
                    }
                }
            timeRange
        }.onAppear { normalizeRange() }
            .onChange(of: store.bookID) { _, _ in normalizeRange(); showingEvents = false; editingRange = false; eventQuery = "" }
            .onChange(of: bounds) { previous, _ in
                // An explicit "all" window follows newly discovered dates;
                // a manually narrowed window keeps the reader's selection.
                if store.timeFrom == previous.lowerBound, store.timeTo == previous.upperBound { fitTime() }
                else { normalizeRange() }
            }
    }
    private func mapMarker(_ point: ReadingMapPoint) -> some View {
        let selected = store.selectedObjectID == point.targetID
        return Button { selectEvent(point.targetID) } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? "flag.fill" : "circle.fill").font(.system(size: selected ? 13 : 8))
                    .foregroundStyle(selected ? Palette.surface : Palette.accent)
                    .frame(width: selected ? 29 : 17, height: selected ? 29 : 17)
                    .background(selected ? Palette.accent : Palette.surface, in: Circle())
                    .overlay(Circle().stroke(Palette.accent.opacity(0.5), lineWidth: 1))
                if selected {
                    Text(point.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(point.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(selected ? 7 : 3)
                .background(selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help("\(point.title) · \(point.subtitle)").accessibilityLabel("\(point.title)，\(point.subtitle)")
    }
    private var timeRange: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    fromText = String(Int(store.timeFrom)); toText = String(Int(store.timeTo)); rangeError = ""; editingRange = true
                } label: {
                    HStack(spacing: 5) {
                        Text("\(TimelineRangeControl.yearLabel(Int(store.timeFrom))) — \(TimelineRangeControl.yearLabel(Int(store.timeTo)))").monospacedDigit()
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                }.buttonStyle(.plain).font(.caption).help("输入精确起止年份")
                    .popover(isPresented: $editingRange) { rangeEditor }
                Spacer(minLength: 4)
                if store.showUndated, store.book?.events.contains(where: { $0.startYear == nil }) == true {
                    Text("含时间待考").font(.caption2).foregroundStyle(.secondary)
                }
                Button("全部") { fitTime() }.font(.caption).controlSize(.mini)
            }
            TimelineRangeControl(lower: $store.timeFrom, upper: $store.timeTo, bounds: bounds, events: store.book?.events ?? [], selectedID: store.selectedObjectID, select: selectEvent)
        }.padding(.horizontal, 18).padding(.top, 9).padding(.bottom, 6).background(Palette.surface)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 0.5) }
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
            }
        }.padding(16).frame(width: 310)
    }
    private var eventList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("当前范围的事件").font(.headline); Spacer(); Button { showingEvents = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭事件清单") }
            TextField("查找事件、时间或参与者", text: $eventQuery).textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredEvents) { event in
                            Button { selectEvent(event.id) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Circle().fill(store.selectedObjectID == event.id ? Palette.copper : Palette.accent.opacity(0.4)).frame(width: 6, height: 6).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(event.name).font(.subheadline.weight(.medium))
                                        Text(event.dateText).font(.caption).foregroundStyle(.secondary)
                                        if !event.participantIDs.isEmpty { Text(event.participantIDs.map { store.objectTitle($0) }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.selectedObjectID == event.id ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(event.id)
                        }
                        if store.visibleEvents.isEmpty { Text("当前范围没有事件。调整端点或显示全部时间。").font(.caption).foregroundStyle(.secondary).padding(16) }
                        else if filteredEvents.isEmpty { Text("没有匹配的事件。请调整搜索词。").font(.caption).foregroundStyle(.secondary).padding(16) }
                    }
                }.onAppear { if let id = store.selectedObjectID { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: store.selectedObjectID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }.padding(14).frame(width: 330, height: 380)
    }
    private func normalizeRange() {
        store.timeFrom = min(bounds.upperBound, max(bounds.lowerBound, store.timeFrom))
        store.timeTo = max(store.timeFrom, min(bounds.upperBound, max(bounds.lowerBound, store.timeTo)))
    }
    private func selectEvent(_ id: String) {
        store.focus(id)
        if let point = points.first(where: { $0.targetID == id }) {
            withAnimation { camera = .region(MKCoordinateRegion(center: point.coordinate, span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))) }
        }
    }
    private func fitTime() { store.timeFrom = bounds.lowerBound; store.timeTo = bounds.upperBound }
}

struct EntityCardsView: View {
    @EnvironmentObject var store: AppStore
    var typeIDs: [String]
    @State private var filter = ""
    @State private var query = ""
    @State private var inspectedEntity: KnowledgeEntity?
    private var entities: [KnowledgeEntity] {
        (store.book?.entities ?? []).filter { (typeIDs.isEmpty || typeIDs.contains($0.typeID)) && (filter.isEmpty || $0.typeID == filter) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactWorkspaceHeader("卡片", subtitle: "\(entities.count) 张") {
                TextField("查找卡片", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 90, maxWidth: 200)
                Menu {
                    Picker("类型", selection: $filter) {
                        Text("全部类型").tag("")
                        ForEach((store.book?.types ?? []).filter { typeIDs.isEmpty || typeIDs.contains($0.id) }) { type in Text(type.name).tag(type.id) }
                    }
                } label: { Image(systemName: filter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }.help("筛选卡片类型")
            }
            if entities.isEmpty {
                if !query.isEmpty || !filter.isEmpty { EmptyState(title: "没有匹配的卡片", detail: "调整搜索词或类型筛选，已保存的卡片仍会保留。", icon: "magnifyingglass") }
                else { EmptyState(title: "卡片会随着阅读长出来", detail: "AI 会依据内容创建人物、概念、定理或自定义类型，并保留每张卡片的原文依据。", icon: "rectangle.stack") }
            }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(entities) { entity in
                            Button { store.focus(entity.id); inspectedEntity = entity } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Image(systemName: store.book?.types.first { $0.id == entity.typeID }?.icon ?? "square.stack").font(.title3).foregroundStyle(Palette.accent); Spacer(); Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.caption2).foregroundStyle(.secondary) }
                                    Text(entity.name).font(.system(size: 20, design: .serif))
                                    Text(entity.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                                    HStack { Text("\(entity.evidence.count) 处原文依据").font(.caption2).foregroundStyle(.tertiary); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Palette.accent) }
                                }.softPanel().overlay(RoundedRectangle(cornerRadius: 14).stroke(store.selectedObjectID == entity.id ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }.padding(16)
                }
            }
        }.popover(item: $inspectedEntity) { entity in
            ObjectInspector(id: entity.id, onClose: { inspectedEntity = nil }).environmentObject(store).frame(width: 330, height: 500)
        }.onChange(of: store.bookID) { _, _ in inspectedEntity = nil; query = ""; filter = "" }
            .onChange(of: typeIDs) { _, ids in if !ids.isEmpty && !ids.contains(filter) { filter = "" } }
    }
}

struct DocumentGraphView: View {
    @EnvironmentObject var store: AppStore
    @State private var inspectedID: String?
    private var nodes: [CanvasNode] {
        guard let book = store.book else { return [] }
        let hidden = Set(book.trashedDocuments.map(\.id))
        return book.nodes.filter { !hidden.contains($0.targetID) }
    }
    var body: some View {
        Group {
            if let book = store.book, !nodes.isEmpty {
                let sourceBookID = book.id
                let nodeIDs = Set(nodes.map(\.id))
                GraphSurface(
                    items: nodes.map { node in GraphItem(id: node.id, targetID: node.targetID, title: store.objectTitle(node.targetID), subtitle: book.activeDocuments.contains { $0.id == node.targetID } ? "Markdown" : "知识节点", x: node.x, y: node.y) },
                    lines: book.edges.filter { nodeIDs.contains($0.fromID) && nodeIDs.contains($0.toID) }.map { GraphLine(id: $0.id, from: $0.fromID, to: $0.toID, label: $0.label) },
                    selectedID: store.selectedObjectID, select: store.focus,
                    open: { id in
                        if book.activeDocuments.contains(where: { $0.id == id }) || book.units.contains(where: { $0.id == id }) { store.openObject(id) }
                        else { inspectedID = id }
                    },
                    move: { id, x, y in
                        guard store.bookID == sourceBookID else { return false }
                        return await store.moveNode(id: id, x: x, y: y)
                    },
                    remove: { id in Task { guard store.bookID == sourceBookID else { return }; await store.removeCanvasNode(id) } },
                    connect: { from, to in
                        guard store.bookID == sourceBookID else { return false }
                        return await store.connectNodes(from: from, to: to, label: "延伸")
                    },
                    renameLine: { id, label in
                        guard store.bookID == sourceBookID else { return false }
                        return await store.renameCanvasEdge(id: id, label: label)
                    },
                    removeLine: { id in
                        guard store.bookID == sourceBookID else { return false }
                        return await store.removeConnection(id)
                    },
                    deselect: { store.selectedObjectID = nil },
                    inspect: { id in inspectedID = id },
                    createDocument: { store.newDocument() },
                    title: "思维导图", isEnabled: !store.isBusy
                ).id(sourceBookID)
            } else {
                EmptyState(title: "从第一篇理解开始", detail: "在“我的理解”写一篇笔记，或主动保存 AI 回答。双击节点打开文档，从节点边缘的圆点拖出连线。", icon: "point.3.connected.trianglepath.dotted")
            }
        }.popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil }
    }
}

struct RelationGraphView: View {
    @EnvironmentObject var store: AppStore
    @State private var inspectedID: String?
    private var items: [GraphItem] {
        guard let book = store.book else { return [] }
        let objects = book.entities.map { entity in (entity.id, entity.name, book.types.first(where: { $0.id == entity.typeID })?.name ?? "要素") } + book.events.map { ($0.id, $0.name, "事件") }
        return objects.prefix(160).enumerated().map { index, item in
            let angle = Double(index) * 2 * .pi / Double(max(1, min(160, objects.count)))
            let radius = max(200, Double(min(objects.count, 160)) * 21)
            return GraphItem(id: item.0, targetID: item.0, title: item.1, subtitle: item.2, x: radius + 70 + cos(angle) * radius, y: radius + 70 + sin(angle) * radius)
        }
    }
    private var lines: [GraphLine] {
        guard let book = store.book else { return [] }
        var lines = book.relations.map { GraphLine(id: $0.id, from: $0.fromID, to: $0.toID, label: $0.label) }
        for event in book.events {
            lines += event.placeIDs.map { GraphLine(id: "event-place|\(event.id)|\($0)", from: event.id, to: $0, label: "发生于") }
            lines += event.participantIDs.map { GraphLine(id: "event-person|\(event.id)|\($0)", from: $0, to: event.id, label: "参与") }
        }
        return lines
    }
    var body: some View {
        Group {
            if items.isEmpty { EmptyState(title: "关系来自阅读", detail: "AI 发现的依赖、参与、发生于等关系会在这里连接。双击节点查看卡片与原文。", icon: "point.3.filled.connected.trianglepath.dotted") }
            else { GraphSurface(items: items, lines: lines, selectedID: store.selectedObjectID, select: store.focus,
                                open: { inspectedID = $0 }, deselect: { store.selectedObjectID = nil }, inspect: { inspectedID = $0 },
                                title: "关系图谱", isEnabled: !store.isBusy).id(store.bookID) }
        }.popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil }
    }
}

struct KnowledgeLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var section = "documents"
    @State private var documentTexts: [String: String] = [:]
    private var documents: [DocumentRecord] {
        (store.book?.activeDocuments ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || documentTexts[$0.id]?.localizedCaseInsensitiveContains(query) == true }
    }
    private var insights: [ReadingInsight] {
        (store.book?.insights ?? []).filter { query.isEmpty || $0.markdown.localizedCaseInsensitiveContains(query) }
    }
    private var entities: [KnowledgeEntity] {
        (store.book?.entities ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            CompactWorkspaceHeader("知识库") {
                Picker("内容", selection: $section) {
                    Text("笔记").tag("documents"); Text("分析").tag("insights"); Text("要素").tag("entities")
                }.pickerStyle(.segmented).frame(width: 155).disabled(!query.isEmpty)
                TextField("搜索全部内容", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 90, maxWidth: 210)
                Button { store.newDocument() } label: { Image(systemName: "square.and.pencil") }.help("写下理解").disabled(store.isBusy)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !query.isEmpty { Text("搜索全部笔记、阅读分析与要素").font(.caption).foregroundStyle(.secondary) }
                    if section == "documents" || !query.isEmpty {
                        if !query.isEmpty { sectionLabel("笔记", count: documents.count) }
                        ForEach(documents) { document in
                            Button { Task { await store.openDocument(document) } } label: {
                                HStack(spacing: 11) {
                                    BrandGlyph(name: "note").frame(width: 19, height: 19).foregroundStyle(Palette.accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(document.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                        Text(document.origin == "user" ? "我的理解" : "主动保存的摘记").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Text(document.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Palette.accent)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.buttonStyle(.plain).contextMenu {
                                Button("加入导图") { Task { await store.addDocumentToGraph(document) } }.disabled(store.isBusy)
                                Button("移入回收站", role: .destructive) { store.requestDeletion(.document, id: document.id, title: document.title) }.disabled(store.isBusy)
                            }
                        }
                        if documents.isEmpty, query.isEmpty { Text("还没有保存笔记。可以主动保存 AI 回答，或写下自己的理解。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                    }
                    if section == "insights" || !query.isEmpty {
                        if !query.isEmpty { sectionLabel("阅读分析", count: insights.count) }
                        ForEach(insights) { insight in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    MarkdownText(markdown: insight.markdown)
                                    ViewThatFits(in: .horizontal) {
                                        insightActions(insight)
                                        VStack(alignment: .leading, spacing: 8) { insightSources(insight); Button("保存为文档") { Task { await store.saveInsight(insight) } }.disabled(store.isBusy) }
                                    }.font(.caption)
                                }.padding(.top, 10)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(insight.unitIDs.first.flatMap { id in store.book?.units.first { $0.id == id }?.locator } ?? "阅读分析").font(.subheadline.weight(.medium))
                                    Text(excerpt(insight.markdown)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.softPanel()
                        }
                        if insights.isEmpty, query.isEmpty { Text("精读保存的分析会出现在这里。展开条目查看全文与原文依据。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                    }
                    if section == "entities" || !query.isEmpty {
                        if !query.isEmpty { sectionLabel("要素", count: entities.count) }
                        ForEach(entities) { entity in
                            Button { store.focus(entity.id); inspectedID = entity.id } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: store.book?.types.first { $0.id == entity.typeID }?.icon ?? "square.stack").foregroundStyle(Palette.accent).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entity.name).font(.subheadline.weight(.medium))
                                        Text(entity.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if entities.isEmpty, query.isEmpty { Text("AI 创建的概念、人物或自定义要素会出现在这里。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                    }
                    if !query.isEmpty, documents.isEmpty, insights.isEmpty, entities.isEmpty { Text("没有找到匹配内容。").foregroundStyle(.secondary).padding(.vertical, 20) }
                }.padding(16).frame(maxWidth: 1000).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(Palette.canvas)
        }.popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.task(id: documentCacheKey) {
            documentTexts = [:]
            guard let book = store.book else { return }; var loaded: [String: String] = [:]
            do { for document in book.activeDocuments { try Task.checkCancellation(); loaded[document.id] = try await store.repository.readDocument(bookID: book.id, document: document) }; if !Task.isCancelled && store.book?.id == book.id { documentTexts = loaded } }
            catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil; query = "" }
    }
    @State private var inspectedID: String?
    private func sectionLabel(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }
    private func excerpt(_ markdown: String) -> String {
        let compact = markdown.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let match = compact.range(of: query, options: .caseInsensitive) else { return String(compact.prefix(120)) }
        let start = compact.index(match.lowerBound, offsetBy: -30, limitedBy: compact.startIndex) ?? compact.startIndex
        return (start == compact.startIndex ? "" : "…") + String(compact[start...].prefix(120))
    }
    private func insightSources(_ insight: ReadingInsight) -> some View {
        Menu("回到原文") {
            ForEach(insight.unitIDs, id: \.self) { id in
                Button(store.book?.units.first { $0.id == id }?.locator ?? "原文") { store.navigateToUnit(id); store.route = "reader" }
            }
        }
    }
    private func insightActions(_ insight: ReadingInsight) -> some View {
        HStack { insightSources(insight); Spacer(); Button("保存为文档") { Task { await store.saveInsight(insight) } }.disabled(store.isBusy) }
    }
    private var documentCacheKey: String { (store.book?.id ?? "") + (store.book?.activeDocuments.map { $0.id + String($0.updatedAt.timeIntervalSince1970) }.joined(separator: "|") ?? "") }
}
