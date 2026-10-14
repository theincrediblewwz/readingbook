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
    private var points: [ReadingMapPoint] {
        guard let book = store.book else { return [] }
        var result: [ReadingMapPoint] = []
        for event in store.visibleEvents {
            for place in book.entities.filter({ event.placeIDs.contains($0.id) }) {
                if let lat = place.latitude, let lon = place.longitude {
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
        return Double((years.min() ?? 0) - 5)...Double((years.max() ?? 2100) + 5)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("在时间里，看见空间").font(.system(size: 25, design: .serif)); Spacer()
                Text("\(store.visibleEvents.count) 个事件 · \(points.count) 个地图标记").font(.caption).foregroundStyle(.secondary)
                Button("全部时间") { fitTime() }
            }.padding(.horizontal, 25).padding(.vertical, 20)
            Map(position: $camera) {
                ForEach(points) { point in
                    Annotation(point.title, coordinate: point.coordinate) {
                        Button { store.focus(point.targetID) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "flag.fill").font(.subheadline).padding(9).background(store.selectedObjectID == point.targetID ? Palette.copper : Palette.accent, in: Circle()).foregroundStyle(.white)
                                Text(point.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(point.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(store.selectedObjectID == point.targetID ? Palette.copper : .clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
            }.mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
                .overlay(alignment: .topLeading) {
                    if points.isEmpty {
                        VStack(alignment: .leading, spacing: 7) { Text("等待有依据的地点").font(.subheadline.weight(.medium)); Text("AI 创建地点并标注坐标后，会在这里连接事件。\n未知或待考位置保留在卡片中。").font(.caption).foregroundStyle(.secondary) }.padding(16).readingGlass().padding(18)
                    }
                }
                .onChange(of: store.selectedObjectID) { _, id in
                    if let point = points.first(where: { $0.targetID == id }) { withAnimation { camera = .region(MKCoordinateRegion(center: point.coordinate, span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))) } }
                }
            VStack(spacing: 10) {
                HStack {
                    Label("\(yearLabel(Int(store.timeFrom))) — \(yearLabel(Int(store.timeTo)))", systemImage: "clock").font(.caption.monospacedDigit())
                    Spacer(); Toggle("保留时间待考事件", isOn: $store.showUndated).toggleStyle(.checkbox).font(.caption)
                }
                HStack(spacing: 15) {
                    Text("从").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { min(max(store.timeFrom, bounds.lowerBound), bounds.upperBound) }, set: { store.timeFrom = min($0, store.timeTo) }), in: bounds, step: 1)
                    Text("至").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { min(max(store.timeTo, bounds.lowerBound), bounds.upperBound) }, set: { store.timeTo = max($0, store.timeFrom) }), in: bounds, step: 1)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(store.visibleEvents) { event in
                                Button { store.focus(event.id) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(event.dateText).font(.caption).foregroundStyle(Palette.copper)
                                        Text(event.name).font(.subheadline.weight(.medium)).lineLimit(2)
                                        Text(event.participantIDs.map { store.objectTitle($0) }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: 170, alignment: .leading).padding(14).background(store.selectedObjectID == event.id ? Palette.accent.opacity(0.14) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).id(event.id)
                            }
                            if store.visibleEvents.isEmpty { Text("该时间范围还没有事件。开始精读后，AI 会判断是否需要创建时间线。").font(.caption).foregroundStyle(.secondary).padding(18) }
                        }
                    }.onChange(of: store.selectedObjectID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                }
            }.padding(20).background(.background)
        }.onAppear { fitTime() }
    }
    private func fitTime() { store.timeFrom = bounds.lowerBound; store.timeTo = bounds.upperBound }
    private func yearLabel(_ year: Int) -> String { year < 0 ? "公元前\(-year)年" : "\(year)年" }
}

struct EntityCardsView: View {
    @EnvironmentObject var store: AppStore
    var typeIDs: [String]
    @State private var filter = ""
    @State private var query = ""
    private var entities: [KnowledgeEntity] {
        (store.book?.entities ?? []).filter { (typeIDs.isEmpty || typeIDs.contains($0.typeID)) && (filter.isEmpty || $0.typeID == filter) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("书中的要素").font(.system(size: 28, design: .serif)); Spacer()
                Picker("类型", selection: $filter) { Text("全部类型").tag(""); ForEach(store.book?.types ?? []) { type in Text(type.name).tag(type.id) } }.frame(width: 150)
                TextField("查找名称与内容", text: $query).textFieldStyle(.roundedBorder).frame(width: 190)
            }.padding(.horizontal, 26).padding(.top, 24)
            if entities.isEmpty { EmptyState(title: "卡片会随着阅读长出来", detail: "AI 会依据内容创建人物、概念、定理或自定义类型，并保留每张卡片的原文依据。", icon: "rectangle.stack") }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(entities) { entity in
                            Button { store.focus(entity.id) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack { Image(systemName: store.book?.types.first { $0.id == entity.typeID }?.icon ?? "square.stack").font(.title3).foregroundStyle(Palette.accent); Spacer(); Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.caption2).foregroundStyle(.secondary) }
                                    Text(entity.name).font(.system(size: 23, design: .serif))
                                    Text(entity.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                                    HStack { Text("\(entity.evidence.count) 处原文依据").font(.caption2).foregroundStyle(.tertiary); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Palette.accent) }
                                }.softPanel().overlay(RoundedRectangle(cornerRadius: 18).stroke(store.selectedObjectID == entity.id ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 26).padding(.bottom, 26)
                }
            }
        }
    }
}

private struct GraphItem: Identifiable { var id: String; var targetID: String; var title: String; var subtitle: String; var x: Double; var y: Double }
private struct GraphLine: Identifiable { var id: String; var from: String; var to: String; var label: String }
private struct GraphSurface: View {
    var items: [GraphItem]
    var lines: [GraphLine]
    var selectedID: String?
    var select: (String) -> Void
    var move: ((String, Double, Double) -> Void)? = nil
    @State private var offsets: [String: CGSize] = [:]
    private var canvasWidth: Double { max(1000, (items.map(\.x).max() ?? 600) + 320) }
    private var canvasHeight: Double { max(650, (items.map(\.y).max() ?? 400) + 240) }
    private func point(_ item: GraphItem) -> CGPoint { let offset = offsets[item.id] ?? .zero; return CGPoint(x: item.x + 110 + offset.width, y: item.y + 45 + offset.height) }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for x in stride(from: 0.0, to: size.width, by: 24) { for y in stride(from: 0.0, to: size.height, by: 24) { context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.12))) } }
                    for line in lines {
                        guard let from = items.first(where: { $0.id == line.from }), let to = items.first(where: { $0.id == line.to }) else { continue }
                        let a = point(from), b = point(to); var path = Path(); path.move(to: a); path.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
                        context.stroke(path, with: .color(Palette.accent.opacity(0.35)), lineWidth: 1.4)
                        context.draw(Text(line.label).font(.system(size: 11)).foregroundColor(.secondary), at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 10))
                    }
                }.frame(width: canvasWidth, height: canvasHeight)
                ForEach(items) { item in
                    Button { select(item.targetID) } label: {
                        VStack(alignment: .leading, spacing: 8) { Text(item.subtitle).font(.caption2).foregroundStyle(Palette.accent); Text(item.title).font(.system(size: 16, weight: .medium, design: .serif)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading) }
                            .padding(15).frame(width: 220, height: 90).background(.background, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedID == item.targetID ? Palette.accent : .primary.opacity(0.12), lineWidth: selectedID == item.targetID ? 2 : 1)).shadow(color: .black.opacity(0.025), radius: 8, y: 3)
                    }.buttonStyle(.plain).position(point(item))
                        .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { value in offsets[item.id] = value.translation }.onEnded { value in
                            if let move { move(item.id, max(10, item.x + value.translation.width), max(10, item.y + value.translation.height)); offsets[item.id] = nil }
                        })
                }
            }.frame(width: canvasWidth, height: canvasHeight)
        }
    }
}

struct DocumentGraphView: View {
    @EnvironmentObject var store: AppStore
    @State private var from = ""
    @State private var to = ""
    @State private var label = "延伸"
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("理解的脉络").font(.system(size: 27, design: .serif)); Text("每个文档节点打开同一份 Markdown，拖动可整理位置。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("写下理解") { store.newDocument() } }.padding(24)
            if let book = store.book, !book.nodes.isEmpty {
                HStack {
                    Picker("从", selection: $from) { Text("选择起点").tag(""); ForEach(book.nodes) { node in Text(store.objectTitle(node.targetID)).tag(node.id) } }.frame(maxWidth: 220)
                    Picker("到", selection: $to) { Text("选择终点").tag(""); ForEach(book.nodes) { node in Text(store.objectTitle(node.targetID)).tag(node.id) } }.frame(maxWidth: 220)
                    TextField("关系", text: $label).frame(width: 90).textFieldStyle(.roundedBorder)
                    Button("连接") { Task { await store.connectNodes(from: from, to: to, label: label) } }.disabled(from.isEmpty || to.isEmpty || from == to || store.isBusy)
                    Spacer()
                }.padding(.horizontal, 24).padding(.bottom, 15)
                GraphSurface(items: book.nodes.map { node in GraphItem(id: node.id, targetID: node.targetID, title: store.objectTitle(node.targetID), subtitle: book.documents.contains { $0.id == node.targetID } ? "Markdown" : "知识节点", x: node.x, y: node.y) }, lines: book.edges.map { GraphLine(id: $0.id, from: $0.fromID, to: $0.toID, label: $0.label) }, selectedID: store.selectedObjectID, select: store.focus, move: { id, x, y in Task { await store.moveNode(id: id, x: x, y: y) } })
            } else { EmptyState(title: "从第一篇理解开始", detail: "写一篇笔记，或把 AI 的回答保存下来。文档会在这里成为可连接的节点。", icon: "point.3.connected.trianglepath.dotted") }
        }
    }
}

struct RelationGraphView: View {
    @EnvironmentObject var store: AppStore
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
        VStack(spacing: 0) {
            HStack { Text("事物如何连接").font(.system(size: 27, design: .serif)); Spacer(); Text("实体、事件与有依据的关系 · 最多展示 160 个节点").font(.caption).foregroundStyle(.secondary) }.padding(24)
            if items.isEmpty { EmptyState(title: "关系来自阅读", detail: "AI 发现的依赖、参与、发生于等关系会在这里连接。点击节点可以查看卡片与原文。", icon: "point.3.filled.connected.trianglepath.dotted") }
            else { GraphSurface(items: items, lines: lines, selectedID: store.selectedObjectID, select: store.focus) }
        }
    }
}

struct KnowledgeLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var documentTexts: [String: String] = [:]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text("把读过的，变成自己的").font(.system(size: 28, design: .serif)); Spacer(); Button("写下理解") { store.newDocument() } }
                TextField("搜索文档正文、阅读分析和要素", text: $query).textFieldStyle(.roundedBorder)
                Text("我的 Markdown").font(.headline)
                ForEach((store.book?.documents ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || documentTexts[$0.id]?.localizedCaseInsensitiveContains(query) == true }) { document in
                    Button { Task { await store.openDocument(document) } } label: { HStack { Image(systemName: "doc.text").foregroundStyle(Palette.accent); VStack(alignment: .leading, spacing: 6) { Text(document.title); Text(document.relativePath).font(.caption.monospaced()).foregroundStyle(.tertiary) }; Spacer(); Text(document.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary); Image(systemName: "arrow.up.right").foregroundStyle(Palette.accent) }.softPanel() }.buttonStyle(.plain)
                }
                if store.book?.documents.isEmpty != false { Text("还没有保存文档。你可以主动保存 AI 回答，或写下自己的理解。").font(.subheadline).foregroundStyle(.secondary) }
                Text("阅读分析").font(.headline).padding(.top, 10)
                ForEach((store.book?.insights ?? []).filter { query.isEmpty || $0.markdown.localizedCaseInsensitiveContains(query) }) { insight in
                    VStack(alignment: .leading, spacing: 14) { MarkdownText(markdown: insight.markdown); HStack { ForEach(insight.unitIDs, id: \.self) { id in Button(id) { store.selectedUnitID = id; store.route = "reader" }.font(.caption) }; Spacer(); Button("保存为文档") { Task { await store.saveInsight(insight) } }.font(.caption).disabled(store.isBusy) } }.softPanel()
                }
                if !query.isEmpty {
                    Text("相关要素").font(.headline)
                    ForEach((store.book?.entities ?? []).filter { $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }) { entity in Button(entity.name) { store.focus(entity.id) }.buttonStyle(.plain).foregroundStyle(Palette.accent) }
                }
            }.padding(30).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }.task(id: documentCacheKey) {
            documentTexts = [:]
            guard let book = store.book else { return }; var loaded: [String: String] = [:]
            do { for document in book.documents { try Task.checkCancellation(); loaded[document.id] = try await store.repository.readDocument(bookID: book.id, document: document) }; if !Task.isCancelled && store.book?.id == book.id { documentTexts = loaded } }
            catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    private var documentCacheKey: String { (store.book?.id ?? "") + (store.book?.documents.map { $0.id + String($0.updatedAt.timeIntervalSince1970) }.joined(separator: "|") ?? "") }
}
