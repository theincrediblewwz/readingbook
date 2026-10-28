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
    @State private var chapterStartID: String?
    @State private var chapterEndID: String?
    @State private var chapters: [BookChapterRange] = []
    @State private var loadedChapterRequest: ChapterListRequest?
    @State private var chaptersError: String?
    @State private var isLoadingChapters = false
    @State private var details = false
    @State private var guide = false
    @State private var requestHistory = false
    @State private var analysisHistory = false
    @State private var profileDraft = BookProfile()
    @State private var customGenre = ""
    @State private var execution = ReadingExecutionConfiguration()
    @State private var legacyExecutionBaseline: ReadingExecutionConfiguration?
    @State private var continuationIntent: ReadingContinuationIntent = .continueMissing
    @State private var continuationPreview: ReadingContinuationPreview?
    @State private var previewRequest: ContinuationPreviewRequest?
    @State private var previewError: String?
    @State private var isPreviewing = false
    @State private var redoConfirmation: ContinuationConfirmation?
    private struct ContinuationPreviewRequest: Hashable {
        var libraryRoot: URL
        var bookID: String
        var sourceHash: String
        var revision: Int
        var currentUnitID: String?
        var currentOffsetUTF16: Int?
        var selection: SmartReadingSelection
        var intent: String
    }
    private struct ContinuationConfirmation: Identifiable {
        let id = UUID()
        let request: ContinuationPreviewRequest
        let selection: SmartReadingSelection
        let preview: ReadingContinuationPreview
    }
    private struct ChapterListRequest: Hashable {
        var libraryRoot: URL
        var bookID: String
        var sourceHash: String
        var revision: Int
    }
    private var pending: Bool { store.book?.bookSchemes?.pending != nil }
    private var selection: SmartReadingSelection {
        var result = SmartReadingSelection(scope: scope, pageStart: scope == .pageRange ? pageStart : nil,
            pageEnd: scope == .pageRange ? pageEnd : nil,
            preferredMethodIDs: automatic ? [] : methodIDs.sorted(), execution: selectedExecution)
        if scope == .chapterRange { result.chapterStartID = chapterStartID; result.chapterEndID = chapterEndID }
        return result
    }
    private var selectedExecution: ReadingExecutionConfiguration? {
        if continuationIntent == .continueMissing, let baseline = legacyExecutionBaseline, execution == baseline { return nil }
        return execution
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
    private var needsNewPlan: Bool {
        store.book?.plan == nil || selection.preferredMethodIDs != (store.book?.smartReading?.selection.preferredMethodIDs ?? [])
    }
    private var requestedPreview: ContinuationPreviewRequest? {
        guard let book = store.book else { return nil }
        guard chapterRangeReady else { return nil }
        let usesPosition = scope == .currentPage || scope == .currentChapter
        return ContinuationPreviewRequest(libraryRoot: store.libraryRootURL, bookID: book.id,
            sourceHash: book.sourceHash, revision: store.projectRevision,
            currentUnitID: usesPosition ? store.selectedUnitID : nil,
            currentOffsetUTF16: scope == .currentChapter ? store.chapterReadingOffset(in: book, unitID: store.selectedUnitID) : nil,
            selection: selection, intent: continuationIntent.rawValue)
    }
    private var currentPreview: ReadingContinuationPreview? {
        previewRequest == requestedPreview ? continuationPreview : nil
    }
    private var requestedChapters: ChapterListRequest? {
        guard scope == .chapterRange, let book = store.book else { return nil }
        return ChapterListRequest(libraryRoot: store.libraryRootURL, bookID: book.id,
            sourceHash: book.sourceHash, revision: store.projectRevision)
    }
    private var currentChapters: [BookChapterRange] {
        loadedChapterRequest == requestedChapters ? chapters : []
    }
    private var endChapters: [BookChapterRange] {
        guard let start = currentChapters.first(where: { $0.id == chapterStartID }) else { return [] }
        return currentChapters.filter { $0.level == start.level }
    }
    private var chapterRangeReady: Bool {
        guard scope == .chapterRange else { return true }
        return currentChapters.contains { $0.id == chapterStartID && $0.isComplete } &&
            endChapters.contains { $0.id == chapterEndID && $0.isComplete }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    introduction
                    if let wholeBookSummary = store.readingContinuationProgress?.wholeBookSummary {
                        SettingsContentGroup {
                            HStack(alignment: .center, spacing: 10) {
                                Label("全书已有内容", systemImage: "checkmark.circle").font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 0)
                                ReadingContinuationInfoButton(title: "已有内容与本次分析", detail: wholeBookSummary + "\n\n全书已有内容保留；下方预览会按本次范围、原文版本和分析要求判断哪些成果真正可以沿用。阅读位置和已有对象数量不代表本次要求已经完成。")
                            }.padding(.horizontal, 14).padding(.vertical, 8)
                        }
                    }
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
        .onChange(of: store.libraryRootURL) { _, _ in load() }
        .task(id: requestedPreview) { await refreshContinuationPreview() }
        .task(id: requestedChapters) { await loadContinuationChapters() }
        .onChange(of: chapterStartID) { _, _ in repairEndChapter() }
        .sheet(item: $redoConfirmation) { confirmation in
            ReadingContinuationConfirmationView(preview: confirmation.preview,
                canConfirm: canConfirm(confirmation), onCancel: { redoConfirmation = nil }) {
                    guard canConfirm(confirmation) else { return }
                    redoConfirmation = nil
                    store.startReadingContinuation(confirmation.selection, intent: .reanalyze, expectedPreview: confirmation.preview)
                }.environmentObject(store)
        }
        .sheet(isPresented: $guide) { ReadingGuideView(onClose: { guide = false }) }
        .sheet(isPresented: $requestHistory) { AIRequestHistoryView(state: store.aiProgressState).environmentObject(store) }
        .sheet(isPresented: $analysisHistory) { ReadingContinuationHistoryView().environmentObject(store) }
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
                Button { analysisHistory = true } label: { Label("分析历史", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("只读查看过去的任务与保留分析，不切换当前版本或调用模型。")
                    .accessibilityIdentifier("reading-continuation-open-history")
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
            if scope == .chapterRange { chapterRangeFields }
            sectionHeading("这次怎么处理", detail: "先看处理安排，再开始。切换选项不会请求模型。", icon: "arrow.triangle.branch")
            ReadingContinuationIntentPicker(selection: $continuationIntent)
            executionOptions
            continuationControls
        }.padding(27).readingGlass(radius: 25).disabled(!store.canStartReading)
    }
    private var rangeHint: some View { Text("暂停后可改范围；已保存内容保留").font(.system(size: 12)).foregroundStyle(.secondary) }
    private var chapterRangeFields: some View {
        SettingsContentGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("起止章节").font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                    ReadingContinuationInfoButton(title: "按真实章节选择", detail: "章节来自与当前原文版本一致的可信目录。开始章和结束章使用同一层级，章尾须已确定；范围以真实原文边界为准。这里不会按页数均分章节，也不会为了填充选项调用 AI。缺少边界时，可回原文读取或整理目录，或暂时使用页码与整书范围。")
                }
                if isLoadingChapters || loadedChapterRequest != requestedChapters {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取真实章节…").font(.system(size: 12)).foregroundStyle(.secondary) }
                } else if currentChapters.isEmpty {
                    HStack(spacing: 6) {
                        Text("暂无可用的可信章节范围").font(.system(size: 13)).foregroundStyle(.secondary)
                        if let chaptersError { ReadingContinuationInfoButton(title: "章节范围不可用", detail: chaptersError) }
                    }
                } else {
                    SettingsPaneFieldGrid(minimumColumnWidth: 180, spacing: 12) {
                        chapterPicker("从这一章", selection: $chapterStartID, choices: currentChapters)
                        chapterPicker("到这一章", selection: $chapterEndID, choices: endChapters)
                    }
                    if !chapterRangeReady {
                        Text("请选择同层级且章尾已确定的起止章节。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }.padding(14)
        }.accessibilityIdentifier("reading-continuation-chapter-range")
    }
    private func chapterPicker(_ title: String, selection: Binding<String?>, choices: [BookChapterRange]) -> some View {
        let showsLevels = Set(currentChapters.map(\.level)).count > 1
        return SettingsPaneField(title: title) {
            Picker(title, selection: selection) {
                if selection.wrappedValue == nil { Text("选择章节").tag(String?.none) }
                ForEach(choices) { chapter in
                    Text(chapterChoiceTitle(chapter, showsLevel: showsLevels)).tag(Optional(chapter.id)).disabled(!chapter.isComplete)
                }
            }.pickerStyle(.menu).labelsHidden().controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .accessibilityLabel(title).help("选择可信目录中的真实章节；预览会校验起止顺序和原文范围。")
        }
    }
    private func chapterChoiceTitle(_ chapter: BookChapterRange, showsLevel: Bool) -> String {
        let level = showsLevel ? "第 \(chapter.level + 1) 层 · " : ""
        return level + chapter.title + (chapter.isComplete ? "" : "（章尾未定）")
    }
    private var continuationControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if pending {
                Text("先采纳或放弃待确认方案，再安排本次分析。原有成果保持可用。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !chapterRangeReady {
                Text(isLoadingChapters ? "章节读取完成后可查看本次处理预览。" : "先选择有效的起止章节，或改用页码、当前章与整书范围。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if needsNewPlan {
                SettingsResponsiveActionLayout {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(activeMethods.isEmpty ? "先确定阅读方案" : "阅读方法已改变")
                            .font(.system(size: 14, weight: .medium))
                        Text("预读用于选择方法；确认方案后再查看覆盖和处理安排，不计入正文覆盖。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    prepareButton
                }
            } else {
                SettingsGroupSection(title: "本次处理预览 · 仅本地计算") {
                    VStack(alignment: .leading, spacing: 16) {
                        if let preview = currentPreview {
                            ReadingContinuationPreviewView(preview: preview)
                        } else if let previewError, !isPreviewing {
                            Label(previewError, systemImage: "exclamationmark.circle")
                                .font(.system(size: 13)).foregroundStyle(Palette.copper)
                                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("reading-continuation-preview-error")
                        } else {
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.small)
                                Text("正在核对本地已有成果…").font(.system(size: 13)).foregroundStyle(.secondary)
                            }.frame(minHeight: 40)
                        }
                        SettingsResponsiveActionLayout {
                            Label("原书、笔记和已有分析保留", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(action: startContinuation) {
                                Label(continuationButtonTitle, systemImage: continuationIntent == .reanalyze ? "arrow.clockwise" : "play.fill")
                            }.buttonStyle(SettingsActionButtonStyle(prominent: true))
                                .disabled(!store.canStartReading || currentPreview?.hasWork != true || isPreviewing)
                                .help(continuationIntent == .reanalyze ? "先确认精确范围，再生成保留旧版的新分析。" : "按本地预览继续，跳过可证明完成的兼容成果。")
                                .accessibilityIdentifier("reading-continuation-start")
                        }
                    }.padding(16)
                }
            }
            rangeHint
        }
    }
    private var continuationButtonTitle: String {
        guard let preview = currentPreview else { return "等待处理预览" }
        if !preview.hasWork { return "所选项目已齐，无需重复分析" }
        switch continuationIntent {
        case .continueMissing: return "开始继续补齐"
        case .supplement: return "开始继续并补充"
        case .reanalyze: return "检查重做范围…"
        }
    }
    private func refreshContinuationPreview() async {
        let requested = requestedPreview
        let intent = continuationIntent
        continuationPreview = nil; previewError = nil; previewRequest = nil; isPreviewing = false
        guard let requested, !pending, !needsNewPlan, chapterRangeReady, !store.isSmartReadingRunning else { return }
        isPreviewing = true
        do {
            // Coalesce page-field edits without doing source projection in body.
            try await Task.sleep(for: .milliseconds(180))
            let preview = try await store.previewReadingContinuation(requested.selection, intent: intent)
            guard !Task.isCancelled, requested == requestedPreview else { return }
            continuationPreview = preview; previewRequest = requested; isPreviewing = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, requested == requestedPreview else { return }
            previewError = error.localizedDescription; previewRequest = requested; isPreviewing = false
        }
    }
    private func startContinuation() {
        guard store.canStartReading, let preview = currentPreview, preview.hasWork,
              let request = requestedPreview else { return }
        if continuationIntent == .reanalyze {
            redoConfirmation = ContinuationConfirmation(request: request, selection: selection, preview: preview)
        } else {
            store.startReadingContinuation(selection, intent: continuationIntent, expectedPreview: preview)
        }
    }
    private func loadContinuationChapters() async {
        guard let requested = requestedChapters else { return }
        isLoadingChapters = true; chaptersError = nil
        do {
            let result = try await store.readingContinuationChapters()
            guard !Task.isCancelled, requested == requestedChapters else { return }
            chapters = result; loadedChapterRequest = requested; isLoadingChapters = false
            if !result.contains(where: { $0.id == chapterStartID && $0.isComplete }) {
                chapterStartID = result.first(where: \.isComplete)?.id
            }
            repairEndChapter()
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, requested == requestedChapters else { return }
            chapters = []; loadedChapterRequest = requested; chaptersError = error.localizedDescription; isLoadingChapters = false
        }
    }
    private func repairEndChapter() {
        guard let start = currentChapters.first(where: { $0.id == chapterStartID && $0.isComplete }) else {
            if loadedChapterRequest == requestedChapters { chapterEndID = nil }
            return
        }
        if !endChapters.contains(where: { $0.id == chapterEndID && $0.isComplete }) { chapterEndID = start.id }
    }
    private func canConfirm(_ confirmation: ContinuationConfirmation) -> Bool {
        continuationIntent == .reanalyze && store.canStartReading && confirmation.request == requestedPreview &&
            currentPreview?.fingerprint == confirmation.preview.fingerprint
    }
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
                    Text("讲解分段").font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 8)
                    Text("合在一起讲解的原文范围").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Picker("讲解分段", selection: $execution.granularity) {
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
                                Text("译注与解释").tag("reading.enrich"); Text("整体总结").tag("reading.review")
                                    Text("确认引文来源").tag("citations.verify")
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
            .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(store.book == nil || (!automatic && methodIDs.isEmpty) || pending || !chapterRangeReady || (try? execution.validate()) == nil)
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
            HStack {
                Label("正在使用的阅读方案", systemImage: "checkmark.seal").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 8)
                ReadingContinuationInfoButton(title: "阅读方案与方法参考", detail: activePlanDetail)
                Button { store.openBookScheme() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("查看完整方案")
            }
            Text(activeMethods.map(\.name).joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("上次任务范围 · " + (store.book?.smartReading?.scopeTitle ?? "尚未开始"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if store.isSmartReadingRunning { Button { store.pauseReading() } label: { Label("暂停分析", systemImage: "pause") }.buttonStyle(ReadingToolbarButtonStyle()) }
                else {
                    Text("在上方选择范围和处理方式，核对预览后开始。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(26).readingGlass(radius: 24)
    }
    private var activePlanDetail: String {
        let methods = activeMethods.map { method in
            ([method.name, method.goal] + method.steps.map { "· " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n\n")
        return [store.book?.plan?.rationale ?? "", "以下是方法参考；本次实际步骤以上方选择及处理预览为准。", methods]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
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
        continuationIntent = .continueMissing; continuationPreview = nil; previewRequest = nil
        previewError = nil; isPreviewing = false; redoConfirmation = nil; analysisHistory = false
        chapters = []; loadedChapterRequest = nil; chaptersError = nil; isLoadingChapters = false
        profileDraft = store.book?.temporalKnowledge?.profile ?? BookProfile(); customGenre = ""
        if let saved = store.book?.smartReading?.selection {
            scope = saved.scope; pageStart = saved.pageStart ?? 1; pageEnd = saved.pageEnd ?? pageStart
            chapterStartID = saved.chapterStartID; chapterEndID = saved.chapterEndID
            methodIDs = Set(saved.preferredMethodIDs); automatic = methodIDs.isEmpty
            if let configured = saved.execution {
                execution = configured; legacyExecutionBaseline = nil
            } else {
                var baseline = ReadingExecutionConfiguration()
                baseline.steps.removeAll { $0.actionID == "reading.review" || $0.frequency == .book }
                execution = baseline; legacyExecutionBaseline = baseline
            }
        } else {
            scope = .wholeBook; methodIDs = []; automatic = true; pageStart = store.selectedUnit?.page ?? 1
            chapterStartID = nil; chapterEndID = nil
            pageEnd = min(pageStart + 9, store.book?.units.compactMap(\.page).max() ?? pageStart)
            execution = ReadingExecutionConfiguration(); legacyExecutionBaseline = nil
        }
    }
}
