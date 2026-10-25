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
    @State private var projections: [String: CompositionProjection] = [:]
    @State private var baseline: [String: CompositionProjection] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var clocks: [String: CompositionClock] = [:]
    @State private var collapsed = Set<String>()
    @State private var tabs: [String: String] = [:]
    @State private var issue: String?
    @State private var validatedComposition: CompositionDefinition?
    @State private var validatedBookID: String?

    private var composition: CompositionDefinition? { definition?.composition }
    private var points: [String: TemporalQueryPoint] { clocks.compactMapValues(\.point) }
    private var readingContext: ReadingContext { contextOverride ?? store.currentReadingContext }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let issue { fallback(issue) }
                else if store.book == nil { fallback("请先从书库打开一本书，再查看这个组合。") }
                else if let composition, validatedComposition == composition, validatedBookID == store.bookID {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !embedded { workspaceHeader }
                            layout(composition.rootID, in: composition, width: max(240, geometry.size.width - (embedded ? 16 : 40)))
                        }.padding(.horizontal, embedded ? 8 : 20).padding(.top, embedded ? 8 : 92).padding(.bottom, embedded ? 8 : 28)
                    }
                } else if composition != nil { ProgressView("正在准备组件…") }
                else { fallback("这个组件尚未提供可显示的布局。原书、笔记和已保存配置都保留。") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(embedded ? Color.clear : Palette.canvas).readingTextContext(.knowledge)
            .task { refresh() }
            .onChange(of: store.projectRevision) { _, _ in refresh() }
            .onChange(of: store.currentReadingContext) { _, _ in refresh() }
            .onChange(of: contextOverride) { _, _ in reset() }
            .onChange(of: store.bookID) { _, _ in reset() }
            .onChange(of: definition) { _, _ in reset() }
            .onChange(of: selections) { _, _ in refresh() }
            .onChange(of: clocks) { _, _ in refresh(includeBaseline: false) }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2").foregroundStyle(Palette.accent)
            Text(definition?.title ?? "组合阅读").font(.system(size: 21, weight: .semibold, design: .serif))
            Spacer(minLength: 8)
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
        selections = [:]; clocks = [:]; collapsed = []; tabs = [:]; refresh()
    }
    private func refresh(includeBaseline: Bool = true) {
        guard let book = store.book, let composition else {
            projections = [:]; baseline = [:]; validatedComposition = nil; validatedBookID = nil; issue = nil; return
        }
        if embedded, selections.isEmpty, let id = readingContext.objectID {
            for source in composition.sources { selections[source.selectionGroup] = [id] }
        }
        do {
            try CompositionRuntime.validate(composition, in: book)
            if includeBaseline {
                baseline = try CompositionRuntime.project(composition, in: book, context: readingContext,
                    selections: selections, boundary: store.temporalBoundary)
            }
            if points.isEmpty { projections = baseline }
            else {
                projections = try CompositionRuntime.project(composition, in: book, context: readingContext,
                    selections: selections, times: points, boundary: store.temporalBoundary)
            }
            validatedComposition = composition; validatedBookID = book.id
            issue = nil
        } catch { projections = [:]; baseline = [:]; validatedComposition = nil; validatedBookID = nil; issue = error.localizedDescription }
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

    private func layout(_ id: String, in composition: CompositionDefinition, width: CGFloat) -> AnyView {
        guard let node = composition.layout.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
        let children = node.children
        switch node.kind {
        case .part:
            guard let part = composition.parts.first(where: { $0.id == node.partID }) else { return AnyView(EmptyView()) }
            return AnyView(partCard(part, width: width))
        case .column:
            return AnyView(VStack(alignment: .leading, spacing: 18) {
                ForEach(children, id: \.self) { layout($0, in: composition, width: width) }
            })
        case .row:
            let available = max(1, width - CGFloat(max(0, children.count - 1)) * 18)
            let weights = children.map { child in composition.layout.first { $0.id == child }?.fraction ?? 1 }
            let total = max(0.001, weights.reduce(0, +))
            if width < 740 || weights.contains(where: { available * CGFloat($0 / total) < 260 }) {
                return AnyView(VStack(alignment: .leading, spacing: 18) {
                    ForEach(children, id: \.self) { layout($0, in: composition, width: width) }
                })
            }
            return AnyView(HStack(alignment: .top, spacing: 18) {
                ForEach(Array(children.enumerated()), id: \.element) { index, child in
                    let childWidth = available * CGFloat(weights[index] / total)
                    layout(child, in: composition, width: childWidth).frame(width: childWidth)
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
                if let selected { layout(selected, in: composition, width: width) }
            })
        case .overlay:
            // The first child owns the canvas. Later children float over it;
            // a compact window stacks them rather than hiding the canvas.
            if width < 740 {
                return AnyView(VStack(spacing: 18) { ForEach(children, id: \.self) { layout($0, in: composition, width: width) } })
            }
            return AnyView(ZStack {
                if let first = children.first { layout(first, in: composition, width: width) }
                ForEach(Array(children.dropFirst()), id: \.self) { child in
                    let dock = composition.layout.first { $0.id == child }?.dock ?? .bottomTrailing
                    layout(child, in: composition, width: min(350, width * 0.4))
                        .frame(width: min(350, width * 0.4)).padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(dock))
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
        }
    }
    private func partCard(_ part: CompositionPart, width: CGFloat) -> some View {
        let projection = projections[part.sourceID]
        let source = baseline[part.sourceID]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon(part)).foregroundStyle(Palette.accent)
                Text(title(part)).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    withAnimation(ReadingMotion.animation(reduce: reduceMotion)) {
                        if collapsed.contains(part.id) { collapsed.remove(part.id) } else { collapsed.insert(part.id) }
                    }
                } label: { Image(systemName: collapsed.contains(part.id) ? "plus" : "minus").frame(width: 48, height: 48) }
                    .buttonStyle(.plain).contentShape(Rectangle()).help(collapsed.contains(part.id) ? "展开\(title(part))" : "收起\(title(part))")
                    .accessibilityLabel(collapsed.contains(part.id) ? "展开\(title(part))" : "收起\(title(part))")
            }.padding(.leading, 18).padding(.trailing, 6).frame(minHeight: 60)
            if !collapsed.contains(part.id) {
                Divider().opacity(0.4)
                if let projection {
                    primitive(part, projection: projection, baseline: source ?? projection, width: width)
                    if projection.partial, projection.items.count < projection.total {
                        Text("当前显示 \(projection.items.count) 项，共 \(projection.total) 项。")
                            .font(.caption).foregroundStyle(.secondary).padding(14)
                    }
                    if !projection.diagnostics.isEmpty {
                        Text(projection.diagnostics.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(14)
                    }
                } else { CompositionEmptyState(text: "正在准备内容…", icon: icon(part)) }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading).readingGlass(radius: 24)
    }

    @ViewBuilder private func primitive(_ part: CompositionPart, projection: CompositionProjection, baseline: CompositionProjection, width: CGFloat) -> some View {
        let selected = selections[part.selectionGroup] ?? []
        switch part.primitive {
        case .objectList:
            CompositionObjectList(items: projection.items, selected: selected) { select($0, group: part.selectionGroup) }
        case .objectDetail:
            CompositionObjectDetails(items: projection.items, selected: selected)
        case .sourceExcerpt:
            CompositionExcerpts(items: projection.items)
        case .markdown:
            CompositionMarkdown(items: projection.items, selected: selected)
        case .map:
            CompositionMap(points: projection.mapPoints, selected: selected, height: embedded ? 220 : 420) { select($0, group: part.selectionGroup) }
        case .timeline:
            CompositionTimeline(items: baseline.items, selected: selected,
                clock: Binding(get: { clocks[part.timeGroup] ?? CompositionClock() }, set: { clocks[part.timeGroup] = $0 }),
                select: { select($0, group: part.selectionGroup) })
        case .relations, .documentGraph:
            CompositionGraph(partID: part.id, viewID: definition?.id ?? "composition", projection: projection,
                selected: selected, documents: part.primitive == .documentGraph, width: width,
                select: { select($0, group: part.selectionGroup) }, deselect: { selections[part.selectionGroup] = [] })
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

private struct CompositionObjectList: View {
    let items: [CompositionItem]
    let selected: Set<String>
    var select: (String) -> Void
    @State private var search = ""
    private var filtered: [CompositionItem] { items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找要素", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 48, height: 48) }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
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
                            }.buttonStyle(.plain)
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
    private var item: CompositionItem? { items.first { selected.contains($0.objectID ?? $0.documentID ?? $0.id) } ?? (items.count == 1 ? items.first : nil) }
    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.title).font(.system(size: 27, weight: .semibold, design: .serif)).textSelection(.enabled)
                    if !item.summary.isEmpty { MarkdownText(markdown: item.summary) }
                    if let match = item.fields["temporalMatch"], ["possible", "unknown"].contains(match) {
                        Label(match == "possible" ? "可能在这一时期" : "时间尚未确定", systemImage: "clock.badge.questionmark").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(item.fields.keys.filter { $0 != "temporalMatch" }.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(fieldLabel(key, item: item)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            MarkdownText(markdown: fieldValue(key, value: item.fields[key] ?? ""))
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
    private var ids: [String] {
        var seen = Set<String>()
        return items.compactMap(\.documentID).filter { seen.insert($0).inserted }
    }
    private var documentID: String? { chosen.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first(where: selected.contains) ?? ids.first }
    private var document: DocumentRecord? { store.book?.activeDocuments.first { $0.id == documentID } }
    private var loadKey: String { (store.bookID ?? "") + "|" + (document?.id ?? "") + "|" + String(document?.updatedAt.timeIntervalSince1970 ?? 0) }
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
                        .buttonStyle(.plain).help("打开这篇笔记").accessibilityLabel("打开这篇笔记")
                }.padding(.horizontal, 18)
                if let issue { Text(issue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(20) }
                else if let markdown { ScrollView { MarkdownText(markdown: markdown).readingTextContext(.notes).padding(20) }.frame(maxHeight: 460) }
                else { ProgressView().frame(maxWidth: .infinity, minHeight: 150) }
            } else { CompositionEmptyState(text: "这里显示已关联、主动保存的 Markdown 笔记。", icon: "doc.text") }
        }.task(id: loadKey) { await load() }.onChange(of: selected) { _, _ in chosen = nil }
    }
    private func load() async {
        markdown = nil; issue = nil
        guard let bookID = store.bookID, let document, ids.contains(document.id) else { return }
        do {
            let value = try await store.repository.readDocument(bookID: bookID, document: document)
            try Task.checkCancellation()
            guard store.bookID == bookID, document.id == documentID else { return }
            markdown = value
        } catch is CancellationError {} catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
}

private struct CompositionMap: View {
    let points: [CompositionMapPoint]
    let selected: Set<String>
    var height: CGFloat = 420
    var select: (String) -> Void
    @State private var camera: MapCameraPosition = .automatic
    var body: some View {
        if points.isEmpty { CompositionEmptyState(text: "当前范围和时间没有已确认的位置。人物仅显示有出处的出现地点。", icon: "map") }
        else {
            Map(position: $camera) {
                ForEach(points) { point in
                    Annotation(point.title, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                        Button { select(point.targetID) } label: {
                            Image(systemName: point.kind == "presence" ? "person.fill" : "mappin")
                                .font(.system(size: 17, weight: .semibold)).foregroundStyle(selected.contains(point.targetID) ? Color.white : Palette.accent)
                                .frame(width: 48, height: 48).background(selected.contains(point.targetID) ? Palette.accent : Palette.paper, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2)).shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        }.buttonStyle(.plain).help(point.subtitle).accessibilityLabel(point.title + "，" + point.subtitle)
                    }
                }
            }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .mapControls { MapCompass(); MapScaleView() }.frame(height: height).clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(8).onChange(of: selected) { _, ids in
                    locate(ids)
                }.onChange(of: points) { _, _ in
                    if !camera.positionedByUser { if selected.isEmpty { camera = .automatic } else { locate(selected) } }
                }
        }
    }
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
    var point: TemporalQueryPoint? {
        guard let axis, let cursor, cursor.isFinite else { return nil }
        if axis == "narrative", (0...1_000_000_000).contains(cursor) { return .narrative(Int(cursor)) }
        if axis.hasPrefix("calendar:"), abs(cursor) <= 1_000_000_000_000 { return .date(TemporalDate(year: Int(cursor)), calendar: String(axis.dropFirst(9))) }
        return nil
    }
}

private struct CompositionTimeline: View {
    @EnvironmentObject private var typography: ReadingTypographySettings
    let items: [CompositionItem]
    let selected: Set<String>
    @Binding var clock: CompositionClock
    var select: (String) -> Void
    private var axes: [String] {
        var values = Set<String>()
        for item in items {
            if item.extent?.narrativeStart != nil { values.insert("narrative") }
            if let extent = item.extent, let calendar = extent.calendar, extent.start != nil { values.insert("calendar:" + calendar) }
        }
        return values.sorted()
    }
    private var axis: String { clock.axis.flatMap { axes.contains($0) ? $0 : nil } ?? axes.first ?? "" }
    private func value(_ extent: TemporalExtent?, end: Bool = false) -> Double? {
        guard let extent else { return nil }
        if axis == "narrative" { return (end ? extent.narrativeEnd : extent.narrativeStart).map(Double.init) }
        guard axis == "calendar:" + (extent.calendar ?? "") else { return nil }
        return (end ? extent.end : extent.start).map { Double($0.year) }
    }
    private var bounds: ClosedRange<Double> {
        let values = items.flatMap { [value($0.extent), value($0.extent, end: true)].compactMap { $0 } }
        return (values.min() ?? 0)...max((values.min() ?? 0) + 1, values.max() ?? 1)
    }
    private var lower: Double { min(bounds.upperBound, max(bounds.lowerBound, clock.lower ?? bounds.lowerBound)) }
    private var upper: Double { min(bounds.upperBound, max(lower, clock.upper ?? bounds.upperBound)) }
    private var cursor: Double { min(upper, max(lower, clock.cursor ?? lower)) }
    private var events: [KnowledgeEvent] {
        items.compactMap { item in
            guard let start = value(item.extent) else { return nil }
            return KnowledgeEvent(id: item.objectID ?? item.id, name: item.title, startYear: Int(start), endYear: value(item.extent, end: true).map(Int.init))
        }
    }
    var body: some View {
        if axes.isEmpty { CompositionEmptyState(text: "还没有可比较的时间记录。原书纪年会保留，不擅自换算为公历。", icon: "clock") }
        else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("时间轴", selection: Binding(get: { axis }, set: { clock = CompositionClock(axis: $0) })) {
                        ForEach(axes, id: \.self) { Text($0 == "narrative" ? "叙事顺序" : String($0.dropFirst(9))).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).frame(minHeight: 48)
                    Spacer()
                    if clock.point != nil {
                        Button { clock = CompositionClock() } label: { Text("全时段").frame(minHeight: 48) }.buttonStyle(ReadingToolbarButtonStyle())
                    } else { Text("全时段").font(.caption).foregroundStyle(.secondary) }
                }
                TimelineRangeControl(lower: Binding(get: { lower }, set: { update(lower: $0) }),
                    upper: Binding(get: { upper }, set: { update(upper: $0) }), bounds: bounds,
                    events: events, selectedID: selected.sorted().first, select: select,
                    cursor: Binding(get: { cursor }, set: { update(cursor: $0) }), label: label)
                if let item = items.first(where: { selected.contains($0.objectID ?? $0.id) }) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.title).font(.system(size: 17, weight: .medium))
                        if let extent = item.extent, !extent.sourceText.isEmpty { Text(extent.sourceText).font(.caption).foregroundStyle(.secondary) }
                        if !item.summary.isEmpty { Text(item.summary).font(typography.font(for: .knowledge)).lineLimit(4) }
                        CompositionEvidenceList(evidence: item.evidence)
                    }.padding(.top, 10)
                }
            }.padding(18)
        }
    }
    private func label(_ value: Double) -> String { axis == "narrative" ? "叙事 \(Int(value))" : TimelineRangeControl.yearLabel(Int(value)) }
    private func update(lower nextLower: Double? = nil, upper nextUpper: Double? = nil, cursor nextCursor: Double? = nil) {
        let lo = min(upper, max(bounds.lowerBound, nextLower ?? lower))
        let hi = max(lo, min(bounds.upperBound, nextUpper ?? upper))
        clock = CompositionClock(axis: axis, lower: lo, upper: hi, cursor: min(hi, max(lo, nextCursor ?? cursor)))
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
            return GraphItem(id: item.id, targetID: item.objectID ?? item.documentID ?? item.id, title: item.title,
                subtitle: item.documentID == nil ? "书中要素" : "Markdown", x: point.x, y: point.y,
                documentIDs: item.documentID.map { [$0] } ?? [])
        }
    }
    private var lines: [GraphLine] {
        let ids = Set(items.map(\.id))
        return projection.edges.filter { ids.contains($0.fromID) && ids.contains($0.toID) }.map { GraphLine(id: $0.id, from: $0.fromID, to: $0.toID, label: $0.label) }
    }
    var body: some View {
        if items.isEmpty { CompositionEmptyState(text: documents ? "当前范围没有已保存的文档节点。" : "当前选择和时间没有可显示的关系。", icon: "point.3.connected.trianglepath.dotted") }
        else {
            GraphSurface(items: items, lines: lines, selectedID: selected.sorted().first, select: select,
                open: { id in
                    if let document = store.book?.activeDocuments.first(where: { $0.id == id }), projection.items.contains(where: { $0.documentID == id }) {
                        Task { await store.openDocument(document) }
                    } else { select(id) }
                }, move: { id, x, y in positions[id] = CGPoint(x: x, y: y); return true },
                deselect: deselect, title: "composition.\(viewID).\(partID)", isEnabled: !store.isBusy, ambientMotion: !documents)
                .frame(height: max(340, min(520, width * 0.65))).clipShape(RoundedRectangle(cornerRadius: 18)).padding(8)
                .onChange(of: store.bookID) { _, _ in positions = [:] }
        }
    }
}
