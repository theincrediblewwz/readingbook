import SwiftUI
import ReadingCore

/// Charts are projections of saved evidence, never a second set of knowledge objects.
struct ReadingAtlasView: View {
    @EnvironmentObject var store: AppStore
    var definition: ViewDefinition?
    @State private var snapshot: ReadingAtlasSnapshot?
    @State private var section = "chapters"
    @State private var selectedBucket: String?
    @State private var inspectedID: String?
    private var refreshKey: String { "\(store.bookID ?? ""):\(store.projectRevision)" }
    var body: some View {
        VStack(spacing: 0) {
            CompactWorkspaceHeader(definition?.title ?? "全书总览") {
                Menu {
                    Picker("总览内容", selection: $section) { Text("章节与覆盖").tag("chapters"); Text("内容类型").tag("types"); Text("事件年代").tag("time"); Text("原文共现").tag("cooccurrence") }
                } label: { Label(sectionTitle, systemImage: "chart.bar.xaxis") }.menuStyle(.borderlessButton)
            }
            if let snapshot {
                if section == "cooccurrence" { cooccurrenceView(snapshot) }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            introduction(snapshot)
                            if section == "types" { typeChart(snapshot) }
                            else if section == "time" { timeChart(snapshot) }
                            else { chapterChart(snapshot) }
                        }.padding(28).frame(maxWidth: 1080).frame(maxWidth: .infinity)
                    }
                }
            } else { ProgressView("从已保存的原文依据生成总览…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(.top, 96).background(Palette.canvas)
        .task(id: refreshKey) {
            guard let project = store.book else { return }
            let work = Task.detached(priority: .userInitiated) { ReadingAtlasRuntime.build(project) }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, store.bookID == project.id else { return }
            snapshot = result
        }
        .popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 340, height: 520) }
        }
    }
    private var sectionTitle: String { ["chapters": "章节与覆盖", "types": "内容类型", "time": "事件年代", "cooccurrence": "原文共现"][section] ?? "全书总览" }
    private func introduction(_ snapshot: ReadingAtlasSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("由本书已保存的内容生成。点击图形返回章节、对象或出处；提取覆盖和理解质量分别判断。")
                .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
            if snapshot.invalidEvidenceCount > 0 { Text("有 \(snapshot.invalidEvidenceCount) 条失效原文依据未计入统计，请核对来源。").font(.caption).foregroundStyle(Palette.copper) }
        }
    }
    private func chapterChart(_ snapshot: ReadingAtlasSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("细线分别表示已核对单元、已收齐回执单元、完整译文覆盖。局部译注单独计数。").font(.system(size: 14)).foregroundStyle(.secondary)
            ForEach(snapshot.chapters) { chapter in
                Button {
                    if let id = chapter.unitIDs.first { store.navigateToUnit(id); store.route = "reader" }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(chapter.title).font(.system(size: 17, weight: .medium)).lineLimit(2); Spacer(); Text("\(chapter.unitIDs.count) 单元").font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary) }
                        coverageLine("核对", count: chapter.completedUnits, total: chapter.unitIDs.count, color: Palette.accent)
                        coverageLine("回执", count: chapter.receiptUnits, total: chapter.unitIDs.count, color: Palette.copper)
                        coverageLine("完整译文", count: chapter.translatedUnits, total: chapter.unitIDs.count, color: .blue)
                        Text("局部或完整译注涉及 \(chapter.translationTouchedUnits) 个单元").font(.caption2).foregroundStyle(.secondary)
                    }.padding(22).background(Palette.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line.opacity(0.7), lineWidth: 0.8)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
    private func coverageLine(_ title: String, count: Int, total: Int, color: Color) -> some View {
        HStack(spacing: 14) { Text(title).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading); ProgressView(value: Double(count), total: Double(max(1, total))).tint(color); Text("\(count)/\(total)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing) }
    }
    private func typeChart(_ snapshot: ReadingAtlasSnapshot) -> some View {
        let maximum = max(1, snapshot.typeCounts.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            if snapshot.typeCounts.isEmpty { Text("尚未提取内容类型；数学书可以是定理或概念，历史书可以是人物或地点。").foregroundStyle(.secondary) }
            ForEach(snapshot.typeCounts) { type in
                DisclosureGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], alignment: .leading, spacing: 8) {
                        ForEach(type.entityIDs, id: \.self) { id in Button(store.objectTitle(id)) { inspectedID = id }.buttonStyle(ReadingToolbarButtonStyle()) }
                    }.padding(.vertical, 12)
                } label: {
                    HStack(spacing: 12) { Text(type.title).font(.subheadline.weight(.medium)).frame(minWidth: 80, alignment: .leading); GeometryReader { geo in RoundedRectangle(cornerRadius: 5).fill(Palette.accent.gradient).frame(width: max(8, geo.size.width * CGFloat(type.count) / CGFloat(maximum))) }.frame(height: 18); Text(type.count, format: .number).font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing) }
                }.padding(16).background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
    private func timeChart(_ snapshot: ReadingAtlasSnapshot) -> some View {
        let maximum = max(1, snapshot.yearBuckets.map(\.count).max() ?? 1)
        let selected = snapshot.yearBuckets.first { $0.id == selectedBucket }
        let ids = selected?.eventIDs ?? snapshot.undatedEventIDs
        return VStack(alignment: .leading, spacing: 18) {
            Text("每个格子统计以起始年份归入的一组事件；深色代表保存的条目较多。它反映本书提取密度，跨年事件只计一次，不能代表真实世界事件发生率。").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                ForEach(snapshot.yearBuckets) { bucket in
                    Button { selectedBucket = bucket.id } label: {
                        VStack(alignment: .leading, spacing: 10) { Text("\(bucket.start) – \(bucket.end)").font(.caption.monospacedDigit()).lineLimit(1); Text("\(bucket.count)").font(.system(size: 26, weight: .medium)); Text("个事件").font(.caption2) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accent.opacity(0.08 + 0.28 * Double(bucket.count) / Double(maximum)), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(selectedBucket == bucket.id ? Palette.accent : .clear, lineWidth: 1.5)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Button("时间待考：\(snapshot.undatedEventIDs.count) 条，单独查看") { selectedBucket = nil }.buttonStyle(.borderless)
            ForEach(ids, id: \.self) { id in
                if let event = store.book?.events.first(where: { $0.id == id }) {
                    DisclosureGroup("\(event.dateText) · \(event.name)") { VStack(alignment: .leading, spacing: 12) { Text(event.summary).font(.subheadline); EvidenceList(evidence: event.evidence); Button("在时间与地图查看") { store.selectedObjectID = id; store.readingScopeCurrent = false; store.activate(.map) }.buttonStyle(.borderless) }.padding(.top, 12) }.padding(16).background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            if snapshot.yearBuckets.isEmpty { Text("没有可系年的事件。概念和证明不必强制生成时间轴。").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private func cooccurrenceView(_ snapshot: ReadingAtlasSnapshot) -> some View {
        let ids = Set(snapshot.cooccurrences.flatMap { [$0.fromID, $0.toID] }).sorted()
        let items = ids.enumerated().map { index, id in
            let angle = Double(index) * 2.399963229728653; let radius = max(150, sqrt(Double(index + 1)) * 105)
            return GraphItem(id: id, targetID: id, title: store.objectTitle(id), subtitle: "原文共现", x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let lines = snapshot.cooccurrences.map { GraphLine(id: $0.id, from: $0.fromID, to: $0.toID, label: "同片段 \($0.count)") }
        return VStack(spacing: 0) {
            Text(snapshot.cooccurrencesBounded ? "有界共现样本 · 同片段出现不代表真实关系。双击节点查看原文依据。" : "同片段共现 · 每条线表示两个对象具有相同原文单元的有效依据，不代表交往或逻辑依赖。")
                .font(.caption).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            if items.isEmpty { EmptyState(title: "尚无可核对的共现", detail: "至少两个对象在同一原文片段留下有效依据，才能形成共现线。", icon: "point.3.connected.trianglepath.dotted") }
            else { GraphSurface(items: items, lines: lines, selectedID: store.selectedObjectID, select: store.focus, open: { inspectedID = $0 }, title: "原文共现", isEnabled: !store.isBusy) }
        }
    }
}
