import SwiftUI
import ReadingCore

/// A book-wide projection of saved objects and exact source mentions. The index
/// is rebuilt off the main actor after a project revision, never during body.
struct SourceIndexWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var typography: ReadingTypographySettings
    var definition: ViewDefinition?
    @State private var projection: SourceIndexProjection?
    @State private var visibleEntries: [SourceIndexedObject] = []
    @State private var query = ""
    @State private var typeFilter = "all"
    @State private var scope = "book"
    @State private var selectedID: String?
    @State private var selectedSourceID: String?
    @State private var directoryVisible = true
    @State private var measuredWindow = false
    @State private var loading = false
    @State private var filtering = false
    @State private var indexError: String?
    @State private var projectionToken = UUID()
    @State private var inspectedID: String?
    @State private var sourceLimit = 36
    @State private var evidenceExpanded = true
    @State private var detailTab = "sources"

    private var refreshKey: String { "\(store.bookID ?? ""):\(store.projectRevision)" }
    private var filterKey: String { "\(store.bookID ?? ""):\(projectionToken):\(query):\(typeFilter):\(scope):\(store.selectedUnitID ?? "")" }
    private var selectedEntry: SourceIndexedObject? { visibleEntries.first { $0.id == selectedID } }
    private var isCurrentProjection: Bool { projection?.bookID == store.bookID && projection?.sourceHash == store.book?.sourceHash }

    var body: some View {
        GeometryReader { geometry in
            let inlineDirectory = geometry.size.width >= 960
            VStack(spacing: 18) {
                toolbar
                if let error = store.readingExperienceError {
                    HStack(spacing: 10) {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 14)).foregroundStyle(Palette.copper).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button { store.readingExperienceError = nil } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("关闭伴读操作提示")
                    }.padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4).background(Palette.copper.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                HStack(alignment: .top, spacing: 20) {
                    if directoryVisible && inlineDirectory { directory.frame(width: 310) }
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 24).padding(.top, 96).padding(.bottom, 24)
                .overlay(alignment: .topLeading) {
                    if directoryVisible && !inlineDirectory {
                        directory.frame(width: 310, height: max(180, geometry.size.height - 216))
                            .padding(.leading, 24).padding(.top, 178).zIndex(2)
                    }
                }
                .onAppear {
                    if !measuredWindow { measuredWindow = true; directoryVisible = inlineDirectory; scope = definition?.scope == "current" ? "current" : "book" }
                }
                .onChange(of: geometry.size.width) { old, next in if old >= 960 && next < 960 { directoryVisible = false } }
        }.background(Palette.canvas)
            .task(id: refreshKey) { await rebuildIndex() }
            .task(id: filterKey) { await filterIndex() }
            .onChange(of: selectedID) { _, _ in selectedSourceID = nil; sourceLimit = 36 }
            .onChange(of: store.bookID) { _, _ in selectedID = nil; selectedSourceID = nil; inspectedID = nil; query = ""; typeFilter = "all"; projection = nil; projectionToken = UUID(); visibleEntries = [] }
            .popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
                if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 390, height: 580) }
            }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                Text("原文索引").font(.system(size: 27, weight: .semibold)).fixedSize()
                HStack(spacing: 12) { searchField.frame(minWidth: 190, maxWidth: .infinity); filterControls }.padding(8).readingGlass(radius: 18).frame(maxWidth: 900)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) { searchField.frame(minWidth: 160, maxWidth: .infinity); filterControls }.padding(8).readingGlass(radius: 18)
        }
    }
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称、别名与原文引句…", text: $query).font(.system(size: 15)).textFieldStyle(.plain)
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("清空原文索引搜索") }
        }.padding(.leading, 12).frame(minHeight: 44)
    }
    private var filterControls: some View {
        HStack(spacing: 8) {
            Picker("原文范围", selection: $scope) { Text("全书").tag("book"); Text("当前片段").tag("current") }
                .labelsHidden().accessibilityLabel("原文索引范围").pickerStyle(.segmented).frame(width: 176)
            Button { directoryVisible.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(ReadingToolbarButtonStyle(selected: directoryVisible)).help(directoryVisible ? "收起对象目录" : "展开对象目录")
            workspaceMenu
        }.controlSize(.large).font(.system(size: 14)).fixedSize(horizontal: true, vertical: false)
    }
    private var workspaceMenu: some View {
        Menu {
            Picker("内容类型", selection: $typeFilter) {
                Text("全部类型").tag("all")
                ForEach(projection?.types ?? []) { type in Text(type.title).tag(type.id) }
            }
            Divider()
            Button("增强当前片段") { store.enhanceCurrentSource() }.disabled(store.isBusy || store.selectedUnit == nil)
            Button("打开智能阅读") { store.route = "workflow" }
            let removed = store.book?.readingExperience?.trash ?? []
            Menu("恢复已移除伴读 · \(removed.count)") {
                ForEach(removed) { item in Button(item.title) { Task { await store.restoreReadingItem(item.id) } }.disabled(store.isBusy) }
            }.disabled(removed.isEmpty)
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize().help("增强、流程与伴读恢复")
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("对象目录").font(.system(size: 17, weight: .semibold))
                Text("\(visibleEntries.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if loading || filtering { ProgressView().controlSize(.small) }
                Button { directoryVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("收起对象目录")
            }.padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    typeButton("全部", id: "all")
                    ForEach(projection?.types ?? []) { type in typeButton(type.title, id: type.id) }
                }.padding(.horizontal, 14).padding(.bottom, 12)
            }
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(visibleEntries) { entry in directoryRow(entry) }
                    if visibleEntries.isEmpty && !loading && !filtering {
                        Text(query.isEmpty ? "此范围还没有可展示的对象。" : "没有匹配的对象或引句。").font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).padding(22)
                    }
                }.padding(10)
            }
            Text("已定位数量是已登记的精确提及，不是全书词频。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).padding(16)
        }.frame(maxHeight: .infinity).readingGlass(radius: 20)
    }
    private func directoryRow(_ entry: SourceIndexedObject) -> some View {
        Button { select(entry.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.icon).font(.system(size: 22)).foregroundStyle(Palette.accent).frame(width: 28, height: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name).font(.system(size: 16, weight: .medium)).lineLimit(2)
                    HStack(spacing: 7) { Text(entry.typeTitle).lineLimit(1); Text("·"); Text(entry.locatedCount > 0 ? "已定位 \(entry.locatedCount) 处" : entry.evidence.isEmpty ? "待定位" : "原文依据 \(entry.evidence.count) 条").monospacedDigit().lineLimit(1) }.font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(13).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .background(selectedID == entry.id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 13)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func typeButton(_ title: String, id: String) -> some View {
        Button { typeFilter = id } label: { Text(title).font(.system(size: 14, weight: typeFilter == id ? .semibold : .regular)).padding(.horizontal, 15).frame(minHeight: 40).background(typeFilter == id ? Palette.accent.opacity(0.10) : Palette.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(typeFilter == id ? Palette.accent.opacity(0.8) : .clear, lineWidth: 1)).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(typeFilter == id ? Palette.accent : .secondary)
    }

    @ViewBuilder private var detail: some View {
        if let entry = selectedEntry, isCurrentProjection {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        objectSummary(entry).id("object-top")
                        if let indexError { notice(indexError, symbol: "exclamationmark.circle") }
                        if scope == "current" { notice(store.selectedUnit?.locator ?? "尚未选择原文片段", symbol: "text.alignleft") }
                        detailTabs(entry)
                        if detailTab == "sources" { mentionSection(entry); evidenceSection(entry) }
                        else { objectFields(entry); relatedObjects(entry) }
                        Text("原句和依据都来自本书已保存的提取结果；未识别扫描页、歧义引句及尚未登记的提及不会被猜补。").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
                    }.padding(28).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
                }.onChange(of: selectedID) { _, _ in proxy.scrollTo("object-top", anchor: .top) }
            }.background(Palette.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line.opacity(0.8), lineWidth: 0.8))
        } else if loading {
            VStack(spacing: 18) { ProgressView(); Text("正在整理本书原文索引…").font(.system(size: 15)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 20) {
                EmptyState(title: indexError == nil ? "从原文找到对象的每一处线索" : "索引暂未更新", detail: indexError ?? "精读或增强后，人物、事件、地点、概念与定理会按书的真实类型显示。搜索名称或引句，查看已登记的原文出处。", icon: "text.magnifyingglass")
                Button { store.enhanceCurrentSource() } label: { Label("增强当前片段", systemImage: "sparkles") }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.isBusy || store.selectedUnit == nil)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func objectSummary(_ entry: SourceIndexedObject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Label(entry.typeTitle, systemImage: entry.icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.accent)
                Spacer(minLength: 0)
                objectMenu(entry)
            }
            Text(entry.name).font(.system(size: 31, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !entry.aliases.isEmpty { Text("别名：" + entry.aliases.joined(separator: " · ")).font(.system(size: 15)).foregroundStyle(.secondary).textSelection(.enabled) }
            if let date = entry.dateText { Label(date, systemImage: "calendar").font(.system(size: 15)).foregroundStyle(.secondary) }
            if !entry.summary.isEmpty { MarkdownText(markdown: entry.summary) }
            HStack(spacing: 18) {
                Label("已定位 \(entry.locatedCount) 处", systemImage: "scope")
                Label("原文依据 \(entry.evidence.count) 条", systemImage: "text.quote")
                if loading { Text("正在更新索引…").font(.system(size: 13)) }
            }.font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
    private func detailTabs(_ entry: SourceIndexedObject) -> some View {
        HStack(spacing: 18) {
            tabButton("出现位置 \(entry.locatedCount)", id: "sources")
            tabButton("属性与关联", id: "details")
            Spacer(minLength: 0)
            Button { createNote(entry) } label: { Label("写下理解", systemImage: "square.and.pencil") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || store.editorDirty || loading).help("打开新的 Markdown 草稿，附所选或首个可定位出处")
        }.overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1).allowsHitTesting(false) }
    }
    private func tabButton(_ title: String, id: String) -> some View {
        Button { detailTab = id } label: {
            Text(title).font(.system(size: 16, weight: detailTab == id ? .semibold : .regular)).padding(.horizontal, 8).frame(minHeight: 48)
                .overlay(alignment: .bottom) { if detailTab == id { Rectangle().fill(Palette.accent).frame(height: 3) } }.contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(detailTab == id ? Palette.accent : .secondary)
    }
    private func objectMenu(_ entry: SourceIndexedObject) -> some View {
        Menu {
            Button("查看卡片与编辑字段…") { inspectedID = entry.id }
            Button("围绕此对象记一笔") { createNote(entry) }.disabled(store.isBusy || store.editorDirty)
            Button("围绕此对象提问") { store.readingContextDocumentID = nil; store.focus(entry.id); store.askAboutReadingContext() }
            if entry.hasMapContent { Button("在时间与地图查看") { store.focus(entry.id); store.readingScopeCurrent = false; store.activate(.map) } }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize().disabled(loading).help("编辑、记笔记、提问与地图")
    }
    private func mentionSection(_ entry: SourceIndexedObject) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("原文中的出现位置", count: entry.locatedCount, caption: "已登记的精确提及，不代表全文词频；锚点按原文顺序排列，重复锚点只计一次。")
            if entry.mentions.isEmpty { notice("此范围尚无可精确定位的提及；下方原文依据仍可查看。", symbol: "scope") }
            ForEach(Array(entry.mentions.prefix(sourceLimit).enumerated()), id: \.element.id) { index, mention in mentionRow(mention, number: index + 1) }
            if entry.mentions.count > sourceLimit { Button("再显示 \(min(36, entry.mentions.count - sourceLimit)) 处") { sourceLimit += 36 }.buttonStyle(ReadingToolbarButtonStyle()) }
        }
    }
    private func mentionRow(_ mention: SourceIndexedMention, number: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 30, height: 30).background(Palette.accent.opacity(0.10), in: Circle()).padding(.top, 7)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    sourceHeader(mention.locator, badge: mention.valid ? "精确锚点" : "锚点待核对", accent: mention.valid, warning: mention.warning)
                    Spacer(minLength: 0)
                    Button { returnToMention(mention) } label: { Label("回原句", systemImage: "arrow.uturn.backward") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(!mention.valid)
                }
                Button { selectedSourceID = selectedSourceID == mention.id ? nil : mention.id } label: {
                    Group {
                        if let markdown = mention.richMarkdown {
                            // The complete source block reaches KaTeX. Folding
                            // affects its viewport, never a TeX/code delimiter.
                            MarkdownText(markdown: markdown).readingTextContext(.source).allowsHitTesting(false)
                                .frame(maxHeight: selectedSourceID == mention.id ? nil : 220, alignment: .top).clipped()
                        } else {
                            (Text(mention.before) + Text(mention.anchor.quote).foregroundColor(Palette.accent).bold() + Text(mention.after))
                                .font(typography.font(for: .source)).lineSpacing(7).lineLimit(selectedSourceID == mention.id ? nil : 6).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                        }
                    }.padding(16).background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line.opacity(0.7), lineWidth: 0.7)).contentShape(Rectangle())
                }.buttonStyle(.plain).help("展开此处的原文上下文")
                if selectedSourceID == mention.id, let unit = store.book?.units.first(where: { $0.id == mention.anchor.unitID }) {
                    DisclosureGroup("所在片段") { MarkdownText(markdown: unit.text).readingTextContext(.source).padding(.top, 12) }.font(.system(size: 14)).tint(Palette.accent)
                }
            }
        }
    }
    private func evidenceSection(_ entry: SourceIndexedObject) -> some View {
        DisclosureGroup(isExpanded: $evidenceExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(entry.evidence.prefix(sourceLimit))) { source in
                    VStack(alignment: .leading, spacing: 12) {
                        sourceHeader(source.locator, badge: "单元依据", accent: false, warning: source.warning)
                        quote(source.evidence.quote, expanded: selectedSourceID == source.id)
                        HStack {
                            Button { selectedSourceID = selectedSourceID == source.id ? nil : source.id } label: { Label(selectedSourceID == source.id ? "已选为笔记出处" : "选为笔记出处", systemImage: selectedSourceID == source.id ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless).font(.system(size: 13)).disabled(!source.unitExists).help("保留粗定位身份，不把这条依据冒充精确提及")
                            Spacer(minLength: 8)
                            Button { selectedSourceID = source.id; store.follow(source.evidence) } label: { Label("查看原文", systemImage: "arrow.uturn.backward") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(!source.unitExists)
                        }
                    }.padding(18).background(selectedSourceID == source.id ? Palette.accent.opacity(0.045) : Palette.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 15))
                }
                if entry.evidence.count > sourceLimit { Button("显示更多原文依据") { sourceLimit += 36 }.buttonStyle(ReadingToolbarButtonStyle()) }
                if entry.evidence.isEmpty { notice("尚未保存独立的原文依据。", symbol: "text.quote") }
            }.padding(.top, 16)
        } label: { sectionHeading("原文依据", count: entry.evidence.count, caption: "提取对象时保留的上下文引句；不混入精确提及的计数。") }.tint(Palette.accent)
    }
    private func objectFields(_ entry: SourceIndexedObject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if entry.properties.isEmpty && entry.related.isEmpty && entry.locationNote?.isEmpty != false { notice("此对象尚未保存额外属性或结构化关联。可从右上角菜单查看卡片并编辑字段。", symbol: "square.stack") }
            if !entry.properties.isEmpty {
                DisclosureGroup("对象属性 · \(entry.properties.count)") {
                    VStack(alignment: .leading, spacing: 18) { ForEach(entry.properties) { property in VStack(alignment: .leading, spacing: 7) { Text(property.label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary); MarkdownText(markdown: property.value) } } }.padding(.top, 16)
                }.font(.system(size: 16, weight: .medium)).tint(Palette.accent)
            }
            if let location = entry.locationNote, !location.isEmpty { Label(location, systemImage: "location").font(.system(size: 14)).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private func relatedObjects(_ entry: SourceIndexedObject) -> some View {
        if !entry.related.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("相关对象").font(.system(size: 18, weight: .semibold))
                ForEach(entry.related) { relation in
                    Button { selectRelated(relation.targetID) } label: {
                        HStack(spacing: 12) { Image(systemName: relation.icon).foregroundStyle(Palette.accent); Text(relation.name).font(.system(size: 15, weight: .medium)); Spacer(); Text(relation.label).font(.system(size: 13)).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary) }.padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 48).background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func sectionHeading(_ title: String, count: Int, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { HStack(spacing: 10) { Text(title).font(.system(size: 19, weight: .semibold)); Text("\(count)").font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary) }; Text(caption).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
    }
    private func sourceHeader(_ locator: String, badge: String, accent: Bool, warning: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(locator, systemImage: "book.pages").font(.system(size: 14, weight: .medium))
            Text(badge).font(.system(size: 12, weight: .medium)).foregroundStyle(accent ? Palette.accent : .secondary)
            if let warning { Label(warning, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(Palette.copper).lineSpacing(4) }
        }
    }
    @ViewBuilder private func quote(_ text: String, expanded: Bool) -> some View {
        if sourceIndexNeedsRichText(text) { MarkdownText(markdown: text).readingTextContext(.source) }
        else { Text(text).font(typography.font(for: .source)).lineSpacing(7).lineLimit(expanded ? nil : 6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func notice(_ text: String, symbol: String) -> some View { Label(text, systemImage: symbol).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true) }

    private func select(_ id: String) { selectedID = id; store.focus(id) }
    private func selectRelated(_ id: String) {
        guard projection?.entries.contains(where: { $0.id == id }) == true else { return }
        query = ""; typeFilter = "all"; scope = "book"; selectedID = id; detailTab = "sources"; store.focus(id)
    }
    private func returnToMention(_ mention: SourceIndexedMention) {
        guard let project = store.book, isCurrentProjection else { return }
        do {
            _ = try ReadingExperienceRuntime.resolve(mention.anchor, in: project)
            if !store.readingExperienceIndex.anchors.contains(where: { $0.id == mention.anchor.id }) { store.readingExperienceIndex.anchors.append(mention.anchor) }
            store.focusReadingAnchor(mention.anchor.id)
        } catch { indexError = "此处原句需要重新核对：" + error.localizedDescription }
    }
    private func createNote(_ entry: SourceIndexedObject) {
        guard let project = store.book, isCurrentProjection, !store.isBusy, !store.editorDirty,
              project.entities.contains(where: { $0.id == entry.id }) || project.events.contains(where: { $0.id == entry.id }) else { return }
        let chosenEvidence = entry.evidence.first(where: { $0.id == selectedSourceID && $0.unitExists })
        let source = chosenEvidence ?? entry.evidence.first(where: { $0.unitExists })
        var anchor = entry.mentions.first(where: { $0.id == selectedSourceID && $0.valid })?.anchor
            ?? (chosenEvidence == nil ? entry.mentions.first(where: { $0.valid })?.anchor : nil)
        if anchor == nil, let source { anchor = try? ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: source.evidence.unitID, quote: source.evidence.quote, in: project) }
        if let value = anchor, (try? ReadingExperienceRuntime.resolve(value, in: project)) == nil { indexError = "此对象的原文已变化，请等待索引刷新后再记笔记。"; return }
        if let anchor, !store.readingExperienceIndex.anchors.contains(where: { $0.id == anchor.id }) { store.readingExperienceIndex.anchors.append(anchor) }
        store.focus(entry.id)
        store.newReadingNote(title: "关于\(entry.name)的理解", markdown: entry.summary.isEmpty ? "" : "## 已保存的对象摘要\n\n" + entry.summary, anchorIDs: anchor.map { [$0.id] } ?? [])
        if anchor == nil, let source, store.editorDirty, store.selectedDocumentID == nil {
            // A legacy ambiguous citation stays a coarse unit reference. It is
            // never promoted into an exact anchor merely to make note creation work.
            var link = URLComponents(); link.scheme = "readingbook"; link.host = "book"; link.path = "/\(project.id)/unit/\(source.evidence.unitID)"
            store.draftEvidence = [source.evidence]
            store.editorMarkdown += "\n\n## 原文依据 · 单元定位\n\n> " + source.evidence.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n[查看所在原文](\(link.string ?? ""))\n"
        }
    }
    private func rebuildIndex() async {
        guard let project = store.book else { projection = nil; visibleEntries = []; loading = false; filtering = false; return }
        let key = refreshKey
        if projection?.bookID != project.id { projection = nil; visibleEntries = [] }
        loading = true; indexError = nil
        // Reading may publish several nearby revisions. Do not queue a full-book
        // scan for every frame or run cancelled scans concurrently.
        do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
        guard refreshKey == key, !Task.isCancelled else { return }
        let worker = Task.detached(priority: .userInitiated) { try await SourceIndexProjector.shared.build(project) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard refreshKey == key, store.bookID == project.id else { return }
            projection = result; projectionToken = UUID(); loading = false
        } catch is CancellationError { }
        catch { guard refreshKey == key else { return }; indexError = error.localizedDescription; loading = false; filtering = false }
    }
    private func filterIndex() async {
        guard let projection, projection.bookID == store.bookID else { filtering = false; return }
        let key = filterKey, input = query, type = typeFilter, current = scope == "current" ? store.selectedUnitID : nil
        let currentOnly = scope == "current"
        filtering = true
        let worker = Task.detached(priority: .userInitiated) { try projection.filtered(query: input, typeID: type, unitID: current, currentOnly: currentOnly) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard filterKey == key, store.bookID == projection.bookID, self.projection?.bookID == projection.bookID else { return }
            visibleEntries = result; filtering = false
            if !result.contains(where: { $0.id == selectedID }) { selectedID = result.first?.id }
        } catch is CancellationError { }
        catch { guard filterKey == key else { return }; indexError = error.localizedDescription; filtering = false }
    }
}

private struct SourceIndexedType: Identifiable, Sendable { var id: String; var title: String }
private struct SourceIndexedProperty: Identifiable, Sendable { var id: String; var label: String; var value: String }
private struct SourceIndexedRelation: Identifiable, Sendable { var id: String; var targetID: String; var name: String; var label: String; var icon: String }
private struct SourceIndexedMention: Identifiable, Sendable {
    var id: String { anchor.id }
    var anchor: SourceAnchor
    var locator: String
    var unitOrder: Int
    var location: Int
    var valid: Bool
    var warning: String?
    var before: String
    var after: String
    var richMarkdown: String? = nil
}
private struct SourceIndexedEvidence: Identifiable, Sendable {
    var id: String
    var evidence: Evidence
    var locator: String
    var unitOrder: Int
    var unitExists: Bool
    var warning: String?
}
private struct SourceIndexedObject: Identifiable, Sendable {
    var id: String
    var name: String
    var typeID: String
    var typeTitle: String
    var icon: String
    var aliases: [String]
    var summary: String
    var properties: [SourceIndexedProperty]
    var dateText: String? = nil
    var locationNote: String? = nil
    var hasMapContent: Bool
    var mentions: [SourceIndexedMention]
    var evidence: [SourceIndexedEvidence]
    var related: [SourceIndexedRelation]
    var searchText: String
    var locatedCount: Int { mentions.filter(\.valid).count }
}
private actor SourceIndexProjector {
    static let shared = SourceIndexProjector()
    func build(_ project: BookProject) throws -> SourceIndexProjection {
        // The core's legacy-evidence pass is synchronous. Serializing it keeps a
        // cancelled revision from competing with a newer revision for CPU.
        try Task.checkCancellation()
        return try SourceIndexProjection.build(project)
    }
}
private struct SourceIndexProjection: Sendable {
    var bookID: String
    var sourceHash: String
    var entries: [SourceIndexedObject]
    var types: [SourceIndexedType]

    static func build(_ project: BookProject) throws -> SourceIndexProjection {
        try Task.checkCancellation()
        let state = ReadingExperienceRuntime.indexEvidence(in: project)
        try Task.checkCancellation()
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let anchors = Dictionary(state.anchors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mentions = Dictionary(grouping: state.mentions, by: \.targetID)
        let typeIndex = Dictionary(project.types.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entityIndex = Dictionary(project.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let eventIndex = Dictionary(project.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [SourceIndexedObject] = []
        var paragraphCache: [String: [ReadingParagraph]] = [:]
        var richBlockCache: [String: String] = [:]
        var richUnitCache: [String: Bool] = [:]
        func richSource(_ anchor: SourceAnchor, unit: SourceUnit?, resolved: ResolvedSourceAnchor?, context: String) -> String? {
            let richContext = sourceIndexNeedsRichText(context)
            guard let unit, let resolved else { return richContext ? anchor.quote : nil }
            let richUnit = richUnitCache[unit.id] ?? sourceIndexNeedsRichText(unit.text)
            richUnitCache[unit.id] = richUnit
            guard richContext || richUnit else { return nil }
            if paragraphCache[unit.id] == nil { paragraphCache[unit.id] = (try? ReadingLedger.paragraphs(for: unit, in: project)) ?? [] }
            let blocks = (paragraphCache[unit.id] ?? []).filter { $0.utf8End > resolved.utf8Start && $0.utf8Start < resolved.utf8End }
            // A long ordinary fragment can bisect inline math. Fall back to
            // the untouched unit instead of inventing delimiter repairs.
            guard !blocks.isEmpty, !blocks.contains(where: { $0.kind == "fragment" || $0.kind == "unclosed-block" }) else { return unit.text }
            let key = unit.id + ":" + blocks.map(\.id).joined(separator: ",")
            let text = richBlockCache[key] ?? blocks.map(\.text).joined()
            richBlockCache[key] = text
            return richContext || sourceIndexNeedsRichText(text) ? text : nil
        }
        func projectedMentions(_ id: String) throws -> [SourceIndexedMention] {
            var seen = Set<String>(), result: [SourceIndexedMention] = []
            for mention in mentions[id] ?? [] {
                try Task.checkCancellation()
                guard seen.insert(mention.anchorID).inserted, let anchor = anchors[mention.anchorID] else { continue }
                let unit = units[anchor.unitID]
                let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: project)
                let qualityWarning = project.coverage[anchor.unitID]?.status == .needsReview || project.coverage[anchor.unitID]?.status == .failed ? "此片段的提取质量待核对。" : nil
                let warning = resolved == nil ? "锚点待核对：原文版本或引句已变化。" : unit?.warning ?? qualityWarning
                var before = "", after = ""
                if let unit, let resolved, let range = Range(resolved.range, in: unit.text) {
                    let prefix = unit.text[..<range.lowerBound], suffix = unit.text[range.upperBound...]
                    before = (prefix.count > 70 ? "…" : "") + String(prefix.suffix(70))
                    after = String(suffix.prefix(120)) + (suffix.count > 120 ? "…" : "")
                }
                let rich = richSource(anchor, unit: unit, resolved: resolved, context: before + anchor.quote + after)
                result.append(SourceIndexedMention(anchor: anchor, locator: unit?.locator ?? "原文片段不存在", unitOrder: unit?.order ?? .max, location: resolved?.utf16Location ?? anchor.utf16Location ?? .max, valid: resolved != nil, warning: warning, before: before, after: after, richMarkdown: rich))
            }
            return result.sorted { $0.unitOrder == $1.unitOrder ? ($0.location == $1.location ? $0.id < $1.id : $0.location < $1.location) : $0.unitOrder < $1.unitOrder }
        }
        func projectedEvidence(_ source: [Evidence], target: String) throws -> [SourceIndexedEvidence] {
            var seen = Set<Evidence>(), result: [SourceIndexedEvidence] = []
            for (index, evidence) in source.enumerated() {
                try Task.checkCancellation()
                guard seen.insert(evidence).inserted else { continue }
                let unit = units[evidence.unitID]
                let exact = (try? ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: evidence.unitID, quote: evidence.quote, in: project)) != nil
                result.append(SourceIndexedEvidence(id: target + ".evidence." + String(index), evidence: evidence, locator: unit?.locator ?? "原文片段不存在", unitOrder: unit?.order ?? .max, unitExists: unit != nil, warning: unit == nil ? "出处单元已缺失，需核对来源。" : !exact ? "引句不能唯一匹配；先查看所在原文单元。" : unit?.warning))
            }
            return result.sorted { $0.unitOrder == $1.unitOrder ? $0.id < $1.id : $0.unitOrder < $1.unitOrder }
        }
        func related(_ id: String) -> [SourceIndexedRelation] {
            var result: [SourceIndexedRelation] = []
            func append(_ target: String, label: String, relationID: String) {
                guard target != id, let name = entityIndex[target]?.name ?? eventIndex[target]?.name else { return }
                let icon = entityIndex[target].flatMap { typeIndex[$0.typeID]?.icon } ?? (eventIndex[target] == nil ? "square.stack" : "calendar")
                result.append(SourceIndexedRelation(id: relationID + "." + target, targetID: target, name: name, label: label, icon: icon))
            }
            for relation in project.relations where relation.fromID == id || relation.toID == id { append(relation.fromID == id ? relation.toID : relation.fromID, label: relation.label, relationID: relation.id) }
            if let event = eventIndex[id] {
                for target in event.placeIDs { append(target, label: "地点", relationID: "place") }
                for target in event.participantIDs { append(target, label: "参与者", relationID: "participant") }
            } else {
                for event in project.events where event.placeIDs.contains(id) || event.participantIDs.contains(id) { append(event.id, label: event.placeIDs.contains(id) ? "发生于此" : "相关事件", relationID: "event") }
            }
            var seen = Set<String>(); return result.filter { seen.insert($0.id).inserted }
        }
        for entity in project.entities {
            try Task.checkCancellation()
            let type = typeIndex[entity.typeID], sources = try projectedMentions(entity.id), evidence = try projectedEvidence(entity.evidence, target: entity.id)
            let fields = entity.properties.keys.sorted().filter { entity.properties[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.map { key in SourceIndexedProperty(id: key, label: type?.fields.first { $0.key == key }?.label ?? key, value: entity.properties[key] ?? "") }
            let search = ([entity.name, entity.summary] + entity.aliases + sources.map { $0.anchor.quote } + evidence.map { $0.evidence.quote }).joined(separator: "\n").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            entries.append(SourceIndexedObject(id: entity.id, name: entity.name, typeID: entity.typeID, typeTitle: type?.name ?? entity.typeID, icon: type?.icon ?? "square.stack", aliases: entity.aliases, summary: entity.summary, properties: fields, locationNote: entity.locationNote, hasMapContent: entity.latitude != nil && entity.longitude != nil, mentions: sources, evidence: evidence, related: related(entity.id), searchText: search))
        }
        for event in project.events {
            try Task.checkCancellation()
            let sources = try projectedMentions(event.id), evidence = try projectedEvidence(event.evidence, target: event.id)
            let search = ([event.name, event.summary, event.dateText] + sources.map { $0.anchor.quote } + evidence.map { $0.evidence.quote }).joined(separator: "\n").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            entries.append(SourceIndexedObject(id: event.id, name: event.name, typeID: "@event", typeTitle: "事件", icon: "calendar", aliases: [], summary: event.summary, properties: [], dateText: event.dateText, hasMapContent: event.startYear != nil || !event.placeIDs.isEmpty, mentions: sources, evidence: evidence, related: related(event.id), searchText: search))
        }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let usedTypes = Set(entries.map(\.typeID))
        var types = project.types.filter { usedTypes.contains($0.id) }.map { SourceIndexedType(id: $0.id, title: $0.name) }
        for id in usedTypes where !types.contains(where: { $0.id == id }) { types.append(SourceIndexedType(id: id, title: id == "@event" ? "事件" : id)) }
        return SourceIndexProjection(bookID: project.id, sourceHash: project.sourceHash, entries: entries, types: types.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }
    func filtered(query: String, typeID: String, unitID: String?, currentOnly: Bool) throws -> [SourceIndexedObject] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var result: [SourceIndexedObject] = []
        for var entry in entries {
            try Task.checkCancellation()
            guard typeID == "all" || entry.typeID == typeID else { continue }
            if currentOnly {
                guard let unitID else { continue }
                entry.mentions = entry.mentions.filter { $0.anchor.unitID == unitID }
                entry.evidence = entry.evidence.filter { $0.evidence.unitID == unitID }
                guard !entry.mentions.isEmpty || !entry.evidence.isEmpty else { continue }
                entry.searchText = ([entry.name, entry.summary] + entry.aliases + entry.mentions.map { $0.anchor.quote } + entry.evidence.map { $0.evidence.quote }).joined(separator: "\n").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }
            guard text.isEmpty || entry.searchText.contains(text) else { continue }
            result.append(entry)
        }
        return result
    }
}

private func sourceIndexNeedsRichText(_ text: String) -> Bool {
    text.contains("$") || text.contains("\\(") || text.contains("\\[") || text.contains("\\)") || text.contains("\\]")
        || text.contains("\\begin{") || text.contains("\\end{") || text.contains("`")
        || text.contains("**") || text.contains("](") || text.hasPrefix("# ") || text.contains("\n#")
        || text.contains("\n- ") || text.contains("\n1. ") || text.hasPrefix("|") || text.contains("\n|")
}
