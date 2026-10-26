import SwiftUI
import ReadingCore

/// Reader-facing setup; detailed processing receipts remain an on-demand view.
struct ReaderMethodView: View {
    @EnvironmentObject private var store: AppStore
    @State private var automatic = true
    @State private var methodIDs = Set<String>()
    @State private var scope: SmartReadingScope = .wholeBook
    @State private var pageStart = 1
    @State private var pageEnd = 1
    @State private var details = false
    @State private var guide = false
    @State private var requestHistory = false
    @State private var profileDraft = BookProfile()
    @State private var customGenre = ""
    @State private var execution = ReadingExecutionConfiguration()
    private var pending: Bool { store.book?.bookSchemes?.pending != nil }
    private var selection: SmartReadingSelection {
        SmartReadingSelection(scope: scope, pageStart: scope == .pageRange ? pageStart : nil,
                              pageEnd: scope == .pageRange ? pageEnd : nil,
                              preferredMethodIDs: automatic ? [] : methodIDs.sorted(), execution: execution)
    }
    private var selectionChanged: Bool {
        guard let book = store.book else { return true }
        return !SmartReadingRuntime.selectionMatchesFrozenContext(selection, in: book, currentUnitID: store.selectedUnitID,
            currentOffsetUTF16: store.chapterReadingOffset(in: book, unitID: store.selectedUnitID))
    }
    private var activeMethods: [ReadingMethod] {
        guard let book = store.book else { return [] }
        return (book.plan?.methodIDs ?? []).compactMap { id in book.methods.first { $0.id == id } }
    }
    private var customMethods: [ReadingMethod] {
        guard let book = store.book else { return [] }
        let defaults = Set(PluginEngine.recommendedMethods.map(\.id))
        return PluginEngine.recommendedMethods(in: book).filter { !defaults.contains($0.id) }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    introduction
                    stages
                    if geometry.size.width >= 1040 {
                        HStack(alignment: .top, spacing: 36) { setup.frame(maxWidth: .infinity); journey.frame(width: 280) }
                    } else { setup }
                    if pending { pendingCard } else if !activeMethods.isEmpty { activePlan }
                    readingPreferences
                    HStack(spacing: 14) {
                        Button { guide = true } label: { Label("使用指南", systemImage: "questionmark.circle") }
                        Button { details = true } label: { Label("查看处理详情", systemImage: "checklist") }
                        Spacer(minLength: 0)
                        Button { store.requestedWorkspaceRoute = "reader" } label: { Label("回原文阅读", systemImage: "book.pages") }
                    }.font(.system(size: 13)).buttonStyle(.borderless).foregroundStyle(.secondary)
                }.frame(maxWidth: 1060).padding(.horizontal, geometry.size.width < 800 ? 32 : 60)
                    .padding(.top, 116).padding(.bottom, 220).frame(maxWidth: .infinity, alignment: .top)
            }.background(Palette.canvas)
        }
        .onAppear(perform: load).onChange(of: store.bookID) { _, _ in load() }
        .sheet(isPresented: $guide) { ReadingGuideView(onClose: { guide = false }) }
        .sheet(isPresented: $requestHistory) { AIRequestHistoryView(state: store.aiProgressState).environmentObject(store) }
        .sheet(isPresented: $details) {
            VStack(spacing: 0) {
                HStack { Label("阅读处理详情", systemImage: "checklist").font(.headline); Spacer(); Button { details = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction).help("关闭处理详情") }.padding(14)
                Divider(); ReadingProcessingDetailsView().environmentObject(store)
            }.frame(minWidth: 660, idealWidth: 920, minHeight: 500, idealHeight: 700)
        }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("智能阅读", systemImage: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.accent)
                Spacer(minLength: 8)
                Button { requestHistory = true } label: { Label("请求记录", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("查看本书当前与以前的请求和操作")
            }
            Text("安心读，线索会慢慢连起来。").font(.system(size: 33, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
            Text("你决定读哪些内容，AI 为这本书选择合适的方法。\n分析在后台进行，原书始终在你手里。")
                .font(.system(size: 16)).foregroundStyle(.secondary).lineSpacing(7)
        }
    }
    private var stages: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { stage("1 选择方式与范围", active: true); Rectangle().fill(.secondary.opacity(0.2)).frame(width: 24, height: 1); stage("2 看一眼阅读方案", active: pending); Rectangle().fill(.secondary.opacity(0.2)).frame(width: 24, height: 1); stage("3 边读边分析", active: store.isSmartReadingRunning) }
            Text("选择方式与范围  →  确认方案  →  边读边分析").font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 4)
    }
    private func stage(_ title: String, active: Bool) -> some View { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(active ? Palette.accent : Color.secondary) }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("怎样读这本书", systemImage: "book.pages").font(.system(size: 17, weight: .semibold))
            Button { automatic = true; methodIDs = [] } label: {
                HStack(spacing: 15) {
                    Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("AI 自己决定").font(.system(size: 17, weight: .semibold))
                        Text("先看书名、目录和开头，选用或制定专属方法").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: automatic ? "checkmark.circle.fill" : "circle").foregroundStyle(automatic ? Palette.accent : Color.secondary.opacity(0.35))
                }.padding(18).frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
                    .background(Palette.accent.opacity(automatic ? 0.07 : 0.015), in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Palette.accent.opacity(automatic ? 0.5 : 0.1))).contentShape(RoundedRectangle(cornerRadius: 17))
            }.buttonStyle(.plain)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) { ForEach(PluginEngine.recommendedMethods) { methodChoice($0) } }
            Text("也可以组合书型。历史小说能同时关注人物、时空与叙事。").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            if !customMethods.isEmpty {
                DisclosureGroup("本书的自定义方法") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) { ForEach(customMethods) { methodChoice($0) } }.padding(.top, 12)
                }.font(.system(size: 13))
            }
            Divider().opacity(0.35)
            sectionHeading("阅读范围", detail: "这一次，想读到哪里？", icon: "scope")
            Picker("阅读范围", selection: $scope) { ForEach(SmartReadingScope.allCases, id: \.self) { Text($0.displayTitle).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            if scope == .currentChapter, store.book?.originalName.lowercased().hasSuffix(".pdf") == true {
                Text("按原书目录或已整理的目录确定章首、章尾；边界未确定时先整理目录。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if scope == .pageRange {
                HStack(spacing: 10) {
                    Text("从第"); TextField("开始页", value: $pageStart, format: .number).textFieldStyle(.roundedBorder).frame(width: 72)
                    Text("到第"); TextField("结束页", value: $pageEnd, format: .number).textFieldStyle(.roundedBorder).frame(width: 72); Text("页"); Spacer(minLength: 0)
                }.font(.system(size: 14))
                if store.book?.units.contains(where: { $0.page != nil }) != true { Text("这本书没有原书页码，请选择当前章或全书。").font(.caption).foregroundStyle(.secondary) }
            }
            executionOptions
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { rangeHint; Spacer(minLength: 0); prepareButton }
                VStack(alignment: .leading, spacing: 12) { rangeHint; prepareButton }
            }
        }.padding(27).readingGlass(radius: 25).disabled(!store.canStartReading)
    }
    private var rangeHint: some View { Text("暂停后可改范围；已保存内容保留").font(.system(size: 12)).foregroundStyle(.secondary) }
    private var executionOptions: some View {
        VStack(alignment: .leading, spacing: 22) {
            Divider().opacity(0.35)
            sectionHeading("怎样读", detail: "选择讲解的细致程度。", icon: "text.book.closed")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { precisionChoice(.standard); precisionChoice(.close) }
                VStack(spacing: 12) { precisionChoice(.standard); precisionChoice(.close) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("每次读多少").font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 8)
                    Text("每次交给 AI 的原文范围").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Picker("每次读多少", selection: $execution.granularity) {
                    ForEach(ReadingAnalysisGranularity.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
            }
            Divider().opacity(0.35)
            sectionHeading("随书组件", detail: "选上想看的，AI 会在阅读时一起整理。", icon: "square.grid.2x2")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach(ReadingExecutionConfiguration.offeredComponents, id: \.self) { kind in
                    Button {
                        if execution.componentKinds.contains(kind) { execution.componentKinds.removeAll { $0 == kind } }
                        else { execution.componentKinds.append(kind) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.icon).font(.system(size: 18)).foregroundStyle(Palette.accent).frame(width: 24)
                            Text(kind.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: execution.componentKinds.contains(kind) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(execution.componentKinds.contains(kind) ? Palette.accent : Color.secondary.opacity(0.3))
                        }.padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 56)
                            .background(Palette.accent.opacity(execution.componentKinds.contains(kind) ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityAddTraits(execution.componentKinds.contains(kind) ? .isSelected : [])
                }
            }
            DisclosureGroup("自定义阅读步骤") {
                VStack(spacing: 12) {
                    Label("阅读原文（基础）", systemImage: "book.pages").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach($execution.steps) { $step in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Toggle("启用步骤", isOn: $step.enabled).labelsHidden().toggleStyle(.checkbox)
                                TextField("要做什么", text: $step.title).textFieldStyle(.roundedBorder)
                                Button { execution.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("移除这一步")
                            }
                            HStack {
                                Picker("处理方式", selection: $step.actionID) {
                                    Text("内容讲解").tag("ai.analyze"); Text("整理要素").tag("facts.extract")
                                    Text("译注与解释").tag("reading.enrich"); Text("回顾").tag("reading.review")
                                    Text("查看引文出处").tag("citations.verify")
                                }.labelsHidden()
                                Picker("执行频率", selection: $step.frequency) {
                                    ForEach(ReadingStepFrequency.allCases, id: \.self) { Text($0.title).tag($0) }
                                }.labelsHidden()
                            }.controlSize(.small).padding(.leading, 26)
                        }
                    }
                    Button { execution.steps.append(ReadingExecutionStep(title: "补充一个阅读关注点")) } label: { Label("增加步骤", systemImage: "plus") }
                        .buttonStyle(.borderless).disabled(execution.steps.count >= 24)
                }.padding(.top, 12)
            }.font(.system(size: 13))
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("同时处理").font(.system(size: 14, weight: .medium))
                    Text("忙时仍可翻页阅读").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Stepper(value: $execution.maximumConcurrentRequests, in: 1...5) {
                    Text("最多 \(execution.maximumConcurrentRequests) 项").monospacedDigit()
                }.fixedSize().accessibilityLabel("AI 同时处理任务上限")
            }.font(.system(size: 13)).padding(.top, 2)
        }
    }
    private func sectionHeading(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Palette.accent).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func precisionChoice(_ precision: ReadingAnalysisPrecision) -> some View {
        let selected = execution.precision == precision
        return Button { execution.precision = precision } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(precision == .standard ? "自然阅读" : "逐段细读").font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Palette.accent : Color.secondary.opacity(0.3))
                }
                Text(precision == .standard ? "直接讲解内容，按需整理线索。" : "逐段留下简短释意，再连起来讲解。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(minWidth: 180, maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .background(Palette.accent.opacity(selected ? 0.09 : 0.03), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var prepareButton: some View {
        Button { store.prepareSmartReading(selection) } label: { Label(activeMethods.isEmpty ? "预读并制定方案" : "预读新方案", systemImage: "sparkles") }
            .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(store.book == nil || (!automatic && methodIDs.isEmpty) || pending || (try? execution.validate()) == nil)
    }
    private func methodChoice(_ method: ReadingMethod) -> some View {
        let label = ["genre.history": "历史", "genre.war": "战争", "genre.fiction": "小说", "genre.argument": "论述", "genre.textbook": "教材"][method.id] ?? method.name
        let icon = ["genre.history": "clock", "genre.war": "flag", "genre.fiction": "book.closed", "genre.argument": "text.alignleft", "genre.textbook": "graduationcap"][method.id] ?? "book.closed"
        return Button {
            automatic = false
            if methodIDs.contains(method.id) { methodIDs.remove(method.id) } else { methodIDs.insert(method.id) }
        } label: {
            HStack(spacing: 7) { Image(systemName: methodIDs.contains(method.id) && !automatic ? "checkmark.circle.fill" : icon); Text(label).lineLimit(2) }
                .font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(ReadingToolbarButtonStyle(selected: !automatic && methodIDs.contains(method.id)))
    }
    private var journey: some View {
        VStack(alignment: .leading, spacing: 27) {
            Text("接下来会发生什么").font(.system(size: 12)).foregroundStyle(.tertiary)
            journeyStep("01", "先了解这本书", "预读只用于选方法，还没有读完整本书。")
            journeyStep("02", "按合适的节奏读", "先选讲解的细致程度，再决定每次读一页、一章，或让 AI 安排。")
            journeyStep("03", "在组件里看见结果", "人物、战役与地点使用同一对象；适用时，地图、时间和关系同步呈现。")
            Button { store.requestedWorkspaceRoute = "reader" } label: { Label("先回原文，稍后再分析", systemImage: "book.pages") }.buttonStyle(.borderless).font(.system(size: 13))
        }.padding(.top, 20)
    }
    private func journeyStep(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.accent.opacity(0.6)).padding(.top, 4)
            VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 16, weight: .medium)); Text(text).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("预读方案已准备好", systemImage: "checkmark.circle").font(.system(size: 19, weight: .semibold)).foregroundStyle(Palette.accent)
            Text("看一眼 AI 选择的方法、类型和组件，确认后开始分析所选范围。").font(.system(size: 15)).foregroundStyle(.secondary)
            Button { store.openBookScheme() } label: { Label("查看并确认方案", systemImage: "arrow.right") }.buttonStyle(ReadingActionButtonStyle(prominent: true))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(26).readingGlass(radius: 24)
    }
    private var activePlan: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("正在使用的阅读方案", systemImage: "checkmark.seal").font(.system(size: 17, weight: .semibold)); Spacer(); Button { store.openBookScheme() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(ReadingToolbarButtonStyle()).help("查看完整方案") }
            Text(store.book?.plan?.rationale ?? "").font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
            Text("以下是方法参考；本轮实际步骤以上方可调整的步骤为准。").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(activeMethods) { method in
                DisclosureGroup("方法参考 · " + method.name) {
                    Text(method.goal).font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 8)
                    ForEach(Array(method.steps.enumerated()), id: \.offset) { _, step in Text("· " + step).font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 5) }
                }.font(.system(size: 15, weight: .medium))
            }
            HStack {
                Text(store.book?.smartReading?.scopeTitle ?? "继续前，先确认本轮分析范围。").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.isSmartReadingRunning { Button { store.pauseReading() } label: { Label("暂停分析", systemImage: "pause") }.buttonStyle(ReadingToolbarButtonStyle()) }
                else if selection.preferredMethodIDs != (store.book?.smartReading?.selection.preferredMethodIDs ?? []) {
                    prepareButton.disabled(!store.canStartReading)
                }
                else if selectionChanged {
                    Button { store.startSmartReadingWithExistingPlan(selection) } label: { Label("沿用方案，按新设置分析", systemImage: "play") }
                        .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(!store.canStartReading || (try? execution.validate()) == nil)
                        .help("更新范围、组件和步骤；更换读书方法请先预读新方案。")
                } else {
                    Button { store.startReading() } label: { Label("继续分析", systemImage: "play") }
                        .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(!store.canStartReading)
                }
            }
        }.padding(26).readingGlass(radius: 24)
    }
    private var readingPreferences: some View {
        DisclosureGroup("阅读偏好与自定义书型") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("避免提前揭示后文", isOn: $profileDraft.avoidsSpoilers).font(.system(size: 14))
                Text("开启后，时空与专属组件随当前阅读位置展示；关闭后可查看本书已生成的完整结果。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108))], alignment: .leading, spacing: 8) {
                    ForEach(BookGenre.allCases, id: \.self) { genre in
                        Button {
                            if profileDraft.genres.contains(genre) { profileDraft.genres.removeAll { $0 == genre } } else { profileDraft.genres.append(genre) }
                        } label: { Label(genre.readerTitle, systemImage: profileDraft.genres.contains(genre) ? "checkmark.circle.fill" : genre.readerIcon).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                            .buttonStyle(ReadingToolbarButtonStyle(selected: profileDraft.genres.contains(genre)))
                    }
                }
                ForEach(profileDraft.customGenres, id: \.self) { genre in
                    HStack { Label(genre, systemImage: "tag"); Spacer(); Button { profileDraft.customGenres.removeAll { $0 == genre } } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("移除这个书型偏好") }
                }
                HStack {
                    TextField("例如：传记、哲学、科学史", text: $customGenre).textFieldStyle(.roundedBorder).onSubmit(addGenre)
                    Button(action: addGenre) { Image(systemName: "plus") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(customGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profileDraft.customGenres.count >= 16)
                }
                HStack {
                    Text("偏好在保存后生效；实际方法仍以已确认方案为准。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("保存偏好") {
                        guard let id = store.bookID else { return }
                        let captured = profileDraft
                        Task { _ = await store.saveReaderBookProfile(captured, inBook: id) }
                    }.buttonStyle(ReadingToolbarButtonStyle(selected: true)).disabled(profileDraft == (store.book?.temporalKnowledge?.profile ?? BookProfile()))
                }
            }.padding(.top, 18).disabled(store.isBusy)
        }.font(.system(size: 14)).padding(22).readingGlass(radius: 22)
    }
    private func addGenre() {
        let value = String(customGenre.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !value.isEmpty, profileDraft.customGenres.count < 16, !profileDraft.customGenres.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        profileDraft.customGenres.append(value); customGenre = ""
    }
    private func load() {
        profileDraft = store.book?.temporalKnowledge?.profile ?? BookProfile(); customGenre = ""
        if let saved = store.book?.smartReading?.selection {
            scope = saved.scope; pageStart = saved.pageStart ?? 1; pageEnd = saved.pageEnd ?? pageStart
            methodIDs = Set(saved.preferredMethodIDs); automatic = methodIDs.isEmpty
            execution = saved.execution ?? ReadingExecutionConfiguration()
        } else {
            scope = .wholeBook; methodIDs = []; automatic = true; pageStart = store.selectedUnit?.page ?? 1
            pageEnd = min(pageStart + 9, store.book?.units.compactMap(\.page).max() ?? pageStart)
            execution = ReadingExecutionConfiguration()
        }
    }
}
