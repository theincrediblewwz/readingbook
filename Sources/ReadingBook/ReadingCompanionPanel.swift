import SwiftUI
import ReadingCore

/// One contextual panel shared by source reading and declared plugin views.
struct ReadingCompanionPanel: View {
    @EnvironmentObject var store: AppStore
    var section: String = "context"
    var scope: String = "current"
    var onClose: (() -> Void)?
    var showsHeader = true
    @State private var removal: ReadingItemRemoval?
    private var items: ReadingContextItems {
        guard let book = store.book else { return ReadingContextItems() }
        if scope == "book" {
            let state = book.readingExperience ?? ReadingExperienceState()
            return ReadingContextItems(anchors: state.anchors, mentions: state.mentions, entities: book.entities, events: book.events, layers: state.layers, alignments: state.alignments, decisions: state.decisions)
        }
        return store.readingContextItems
    }
    private var effectiveSection: String { section == "context" ? store.readingCompanionSection : section }
    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { HStack(spacing: 10) {
                Label("伴读", systemImage: "text.book.closed").font(.headline)
                Spacer()
                if section == "context" { Menu {
                    Button("解释与译文") { store.readingCompanionSection = "layers" }
                    Button("原文中的对象") { store.readingCompanionSection = "mentions" }
                    Button("资料对读") { store.readingCompanionSection = "references" }
                    Button("停下来想一想") { store.readingCompanionSection = "decisions" }
                } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).frame(width: 40, height: 40).help("选择伴读内容") }
                if !(store.book?.readingExperience?.trash ?? []).isEmpty {
                    Menu {
                        ForEach(store.book?.readingExperience?.trash ?? []) { item in Button("恢复 \(item.title)") { Task { await store.restoreReadingItem(item.id) } }.disabled(store.isBusy) }
                    } label: { Image(systemName: "arrow.uturn.backward") }.menuStyle(.borderlessButton).frame(width: 40, height: 40).help("恢复已移除的伴读")
                }
                if let onClose { Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("收起伴读") }
            }.padding(.horizontal, 16).padding(.top, 8) }
            if !showsHeader {
                HStack {
                    Picker("伴读内容", selection: $store.readingCompanionSection) {
                        Text("此处伴读").tag("context")
                        Text("解释与译文").tag("layers"); Text("原文对象").tag("mentions"); Text("资料对读").tag("references"); Text("思考卡").tag("decisions")
                    }.labelsHidden().accessibilityLabel("伴读内容").pickerStyle(.menu)
                    Spacer(minLength: 6)
                    if !(store.book?.readingExperience?.trash ?? []).isEmpty {
                        Menu { ForEach(store.book?.readingExperience?.trash ?? []) { item in Button("恢复 \(item.title)") { Task { await store.restoreReadingItem(item.id) } }.disabled(store.isBusy) } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).help("恢复已移除的伴读")
                    }
                }.padding(.horizontal, 16)
            }
            HStack(alignment: .top) {
                Text(scope == "book" ? "全书增强内容" : store.readingContextDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Button { store.askAboutReadingContext() } label: { Label("问这里", systemImage: "bubble.left") }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error = store.readingExperienceError { Text(error).font(.caption).foregroundStyle(Palette.copper) }
                    if effectiveSection == "mentions" { objectSection }
                    else if effectiveSection == "references" { referenceSection }
                    else if effectiveSection == "decisions" { decisionSection }
                    else { layerSection }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog("移除这条阅读增强？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { item in
            Button("移除", role: .destructive) { Task { await store.removeReadingItem(item.id, kind: item.kind) } }
        } message: { item in Text("\(item.title)\n原书和已保存的 Markdown 保留。") }
    }
    @ViewBuilder private var layerSection: some View {
        if items.layers.isEmpty {
            empty("让 AI 为这段书准备合适的伴读内容", detail: "古文可生成译文、名物注释；数学可生成定义、证明线索。类型由书的内容决定。")
        }
        ForEach(items.layers) { layer in
            VStack(alignment: .leading, spacing: 10) {
                itemHeader(layer.title, label: layer.sourceLabel, id: layer.id, kind: "layer")
                MarkdownText(markdown: layer.markdown)
                provenance(layer.provenance)
                anchorButtons(layer.sourceAnchorIDs)
                Button("整理成我的 Markdown 草稿") { store.newReadingNote(title: layer.title, markdown: layer.markdown + "\n\n_\(layer.sourceLabel)_", anchorIDs: layer.sourceAnchorIDs) }.buttonStyle(.borderless).font(.caption)
            }.readingCompanionCard()
        }
        if !items.alignments.isEmpty { referenceSection }
    }
    @ViewBuilder private var referenceSection: some View {
        if items.alignments.isEmpty { empty("资料对读", detail: "把同一书内相关段落放在一起，分别回到出处。外部资料需有来源，AI 的解释会单独标识。") }
        ForEach(items.alignments) { alignment in
            VStack(alignment: .leading, spacing: 10) {
                itemHeader(alignment.title, label: "资料对齐 · \(alignment.status == "proposed" ? "待核对" : alignment.status)", id: alignment.id, kind: "alignment")
                MarkdownText(markdown: alignment.markdown)
                provenance(alignment.provenance)
                anchorButtons(alignment.sourceAnchorIDs)
                Button("整理成 Markdown 草稿") { store.newReadingNote(title: alignment.title, markdown: alignment.markdown, anchorIDs: alignment.sourceAnchorIDs) }.buttonStyle(.borderless).font(.caption)
            }.readingCompanionCard()
        }
    }
    @ViewBuilder private var objectSection: some View {
        if items.entities.isEmpty && items.events.isEmpty { empty("原文中的对象", detail: "名称和引用都对应同一个对象。人物、地点、定理、概念等由 AI 按书建立。") }
        ForEach(items.entities) { entity in
            DisclosureGroup(isExpanded: Binding(get: { store.selectedObjectID == entity.id }, set: { store.selectedObjectID = $0 ? entity.id : nil })) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entity.summary).font(.system(size: 14)).textSelection(.enabled)
                    if !entity.aliases.isEmpty { Text("别名：" + entity.aliases.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(entity.properties.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top) { Text(key).foregroundStyle(.secondary); Text(entity.properties[key] ?? "").textSelection(.enabled) }.font(.caption)
                    }
                    appearances(entity.id, evidence: entity.evidence)
                    relatedObjects(entity.id)
                }.padding(.top, 10)
            } label: {
                HStack { Image(systemName: entity.latitude == nil ? "square.stack" : "mappin"); Text(entity.name).font(.subheadline.weight(.semibold)); Spacer(); Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.caption).foregroundStyle(.secondary) }
            }.readingCompanionCard()
        }
        ForEach(items.events) { event in
            VStack(alignment: .leading, spacing: 10) {
                Text(event.name).font(.subheadline.weight(.semibold)); Text(event.dateText).font(.caption).foregroundStyle(.secondary)
                Text(event.summary).font(.system(size: 14)).textSelection(.enabled)
                appearances(event.id, evidence: event.evidence)
                if !event.placeIDs.isEmpty {
                    Button("在时间与地图中查看") { store.selectedObjectID = event.id; store.readingScopeCurrent = true; store.activate(.map) }.buttonStyle(.borderless).font(.caption)
                }
            }.readingCompanionCard()
        }
    }
    @ViewBuilder private var decisionSection: some View {
        if items.decisions.isEmpty { empty("停下来想一想", detail: "历史可先做选择再看后果；数学可先判断推理路径，再展开解析。思考只保留在本机，主动保存才形成 Markdown。") }
        ForEach(items.decisions) { card in
            ReadingDecisionView(card: card, onRemove: { removal = ReadingItemRemoval(id: card.id, kind: "decision", title: card.title) })
        }
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(Palette.accent)
            Text(title).font(.subheadline.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            Button { store.enhanceCurrentSource() } label: { Label(store.isBusy ? "正在处理…" : "增强当前片段", systemImage: "sparkles") }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.isBusy)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func itemHeader(_ title: String, label: String, id: String, kind: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)); Text(label).font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Menu { Button("移除增强条目", role: .destructive) { removal = ReadingItemRemoval(id: id, kind: kind, title: title) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 32, height: 32)
        }
    }
    @ViewBuilder private func provenance(_ value: ReadingProvenance?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 4) {
                Text([value.label, value.workTitle, value.locator].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                if let string = value.url, let url = URL(string: string), ["http", "https"].contains(url.scheme ?? "") { Link("查看标明的来源", destination: url).font(.caption) }
            }
        }
    }
    private func anchorButtons(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ids, id: \.self) { id in
                if let anchor = store.readingExperienceIndex.anchors.first(where: { $0.id == id }) ?? store.book?.readingExperience?.anchors.first(where: { $0.id == id }) {
                    Button { store.focusReadingAnchor(id) } label: { Label(String(anchor.quote.prefix(100)), systemImage: "arrow.uturn.backward").font(.caption).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
            }
        }
    }
    private func appearances(_ id: String, evidence: [Evidence]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原文出现处").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(evidence.prefix(24).enumerated()), id: \.offset) { _, source in
                Button { store.follow(source) } label: { Text(source.quote).font(.caption).lineLimit(3).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
        }
    }
    private func relatedObjects(_ id: String) -> some View {
        let relations = (store.book?.relations ?? []).filter { $0.fromID == id || $0.toID == id }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(relations.prefix(16)) { relation in
                let other = relation.fromID == id ? relation.toID : relation.fromID
                Button { store.showReadingObject(other) } label: { Label("\(relation.label) · \(store.objectTitle(other))", systemImage: "point.3.connected.trianglepath.dotted").font(.caption).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }
    }
}

private struct ReadingItemRemoval: Identifiable { let id: String; let kind: String; let title: String }

private struct ReadingDecisionView: View {
    @EnvironmentObject var store: AppStore
    let card: DecisionCard
    var onRemove: () -> Void
    @State private var choice: String?
    @State private var thought = ""
    @State private var revealed = false
    private var draftKey: String { "decision-draft-\(store.bookID ?? "")-\(card.id)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(card.title).font(.subheadline.weight(.semibold)); Spacer(); Menu { Button("移除", role: .destructive, action: onRemove) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 32, height: 32) }
            Text(card.sourceLabel).font(.caption2).foregroundStyle(.secondary)
            MarkdownText(markdown: card.contextMarkdown)
            ForEach(card.options) { option in
                Button { choice = option.id } label: {
                    HStack(alignment: .top, spacing: 10) { Image(systemName: choice == option.id ? "checkmark.circle.fill" : "circle"); Text(option.title).font(.subheadline); Spacer(minLength: 0) }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(Palette.accent.opacity(choice == option.id ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                if choice == option.id { MarkdownText(markdown: option.markdown) }
            }
            TextField("我这样判断的理由…", text: $thought, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            if revealed { MarkdownText(markdown: card.historicalOutcomeMarkdown) }
            Button(revealed ? "收起解析" : "看原书结果与解析") { revealed.toggle() }.disabled(choice == nil).buttonStyle(.borderless)
            Button("保存我的思考为 Markdown 草稿") {
                let selected = card.options.first { $0.id == choice }?.title ?? "尚未选择"
                let outcome = revealed ? "\n\n## 原书结果与解析\n\n\(card.historicalOutcomeMarkdown)" : ""
                store.newReadingNote(title: card.title, markdown: "\(card.contextMarkdown)\n\n## 我的选择\n\n\(selected)\n\n\(thought)\(outcome)\n\n_\(card.sourceLabel)_", anchorIDs: card.sourceAnchorIDs)
            }.font(.caption).buttonStyle(.borderless)
        }.readingCompanionCard().id(card.id)
        .onAppear {
            let draft = UserDefaults.standard.dictionary(forKey: draftKey) ?? [:]
            choice = (draft["choice"] as? String).flatMap { id in card.options.contains { $0.id == id } ? id : nil }
            thought = draft["thought"] as? String ?? ""; revealed = draft["revealed"] as? Bool ?? false
        }
        .onChange(of: choice) { _, _ in persistThought() }
        .onChange(of: thought) { _, _ in persistThought() }
        .onChange(of: revealed) { _, _ in persistThought() }
    }
    private func persistThought() { UserDefaults.standard.set(["choice": choice ?? "", "thought": String(thought.prefix(100_000)), "revealed": revealed] as [String: Any], forKey: draftKey) }
}

struct ReadingExperienceWorkspaceView: View {
    @EnvironmentObject var store: AppStore
    var section: String
    var definition: ViewDefinition?
    var body: some View {
        ReadingCompanionPanel(section: section, scope: definition?.scope ?? "current")
            .frame(maxWidth: 900).padding(22).readingGlass(radius: 22)
            .padding(.horizontal, 76).padding(.top, 96).padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
    }
}

private extension View {
    func readingCompanionCard() -> some View { padding(14).background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 14)) }
}
