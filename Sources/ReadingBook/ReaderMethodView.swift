import SwiftUI
import ReadingCore

struct ReaderMethodView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var adjusting = false
    @State private var details = false
    @State private var draft = BookProfile()
    @State private var customGenre = ""
    @State private var discardChanges = false
    @State private var profileBookID: String?
    @State private var profileLoaded = false

    private var profile: BookProfile { store.book?.temporalKnowledge?.profile ?? BookProfile() }
    private var activeMethods: [ReadingMethod] {
        guard let book = store.book, let plan = book.plan else { return [] }
        let methods = PluginEngine.activeMethods(in: book)
        return plan.methodIDs.compactMap { id in methods.first { $0.id == id } }
    }
    private var profileDirty: Bool { draft.genres != profile.genres || draft.customGenres != profile.customGenres || draft.avoidsSpoilers != profile.avoidsSpoilers }
    private var canPause: Bool { !store.isSavingDocument && !store.isExportingProject && !store.isImportingBookCommit && !store.isCommittingLocalWrite }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        introduction
                        methodSteps
                        HStack {
                            Button { details = true } label: { Label("处理详情", systemImage: "chevron.down").font(.subheadline) }
                                .buttonStyle(.borderless).help("需要时查看逐段回执、覆盖与调用记录")
                            Spacer()
                            Button { store.openBookScheme() } label: { Label("查看实际方案", systemImage: "slider.horizontal.3").font(.subheadline) }
                                .buttonStyle(.borderless).disabled(store.book == nil)
                        }
                    }.frame(maxWidth: 820).padding(.horizontal, geometry.size.width < 800 ? 28 : 60)
                        .padding(.top, 116).padding(.bottom, 150).frame(maxWidth: .infinity)
                }
                taskState.padding(.horizontal, geometry.size.width < 800 ? 20 : 56).padding(.bottom, 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                ReaderFloatingPanel(title: "调整读法", icon: "slider.horizontal.3", width: 370, height: 520,
                    isPresented: adjustmentBinding, viewport: geometry.size, memoryIDOverride: "methods.adjust", bottomReserve: 140) {
                    adjustmentContent
                }
            }.background(Palette.canvas)
        }
        .onAppear { loadProfile() }
        .onChange(of: store.bookID) { _, _ in adjusting = false; loadProfile() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ReadingBookAdjustReaderMethod"))) { _ in
            if !adjusting { loadProfile() }
            withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { adjustmentBinding.wrappedValue = !adjusting }
        }
        .confirmationDialog("读书偏好尚未保存", isPresented: $discardChanges) {
            Button("保存并收起") { saveProfile(close: true) }.disabled(store.isBusy)
            Button("放弃本次调整", role: .destructive) { loadProfile(); adjusting = false }
            Button("继续调整", role: .cancel) { }
        } message: { Text("实际执行方案不受这次未保存偏好的影响。") }
        .sheet(isPresented: $details) {
            VStack(spacing: 0) {
                HStack { Label("阅读处理详情", systemImage: "checklist").font(.headline); Spacer(); Button { details = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction).help("关闭处理详情") }.padding(14)
                Divider()
                ReadingProcessingDetailsView().environmentObject(store)
            }.frame(minWidth: 660, idealWidth: 920, minHeight: 500, idealHeight: 700)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("怎样读这本书").font(.system(size: 32, weight: .semibold, design: .rounded))
            Text("先看清原文，再把线索连起来，留下自己的理解。")
                .font(.system(size: 16)).foregroundStyle(.secondary)
            if profile.genres.isEmpty && profile.customGenres.isEmpty {
                Button { adjusting = true } label: { Label("选择书型 · 可以多选", systemImage: "plus") }.buttonStyle(ReadingToolbarButtonStyle())
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(profile.genres, id: \.self) { genre in genrePill(genre.readerTitle, icon: genre.readerIcon) }
                    ForEach(profile.customGenres, id: \.self) { value in genrePill(value, icon: "tag") }
                }.frame(maxWidth: 640, alignment: .leading)
            }
            if store.book?.bookSchemes?.pending != nil {
                Button { store.openBookScheme() } label: { Label("预读方案已准备好，查看并确认", systemImage: "checkmark.circle") }
                    .buttonStyle(ReadingToolbarButtonStyle()).readingGlass(radius: 16)
            }
        }
    }
    private var methodSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            if activeMethods.isEmpty {
                direction("先读原文", detail: "逐页展开，按段核对内容；识别不清的地方先留待核对。", icon: "book.pages", number: 1)
                direction("建立联系", detail: "按这本书的内容选择对象、概念、事件和合适的组件。", icon: "point.3.connected.trianglepath.dotted", number: 2)
                direction("留下理解", detail: "回看上下文，把有用的解释和自己的想法写进笔记。", icon: "square.and.pencil", number: 3)
                Text("这是阅读方向。预读后会提出本书的实际执行方法，确认后开始。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            } else {
                ForEach(Array(activeMethods.enumerated()), id: \.element.id) { index, method in
                    VStack(alignment: .leading, spacing: 14) {
                        direction(method.name, detail: method.goal, icon: index == 0 ? "book.pages" : "point.3.connected.trianglepath.dotted", number: index + 1)
                        if !method.steps.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(Array(method.steps.enumerated()), id: \.offset) { _, step in
                                    HStack(alignment: .top, spacing: 10) { Circle().fill(Palette.accent.opacity(0.55)).frame(width: 4, height: 4).padding(.top, 7); Text(step).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                }
                            }.padding(.leading, 66)
                        }
                    }.padding(.bottom, 12)
                }
            }
        }
    }
    private func direction(_ title: String, detail: String, icon: String, number: Int) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon).font(.system(size: 23, weight: .regular)).foregroundStyle(Palette.accent)
                .frame(width: 48, height: 48).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(detail).font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            }.padding(.top, 3)
            Spacer(minLength: 0)
            Text(String(format: "%02d", number)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary).padding(.top, 9)
        }.padding(.vertical, 12)
    }
    private var taskState: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { taskDescription; Spacer(minLength: 12); taskAction }
            VStack(alignment: .leading, spacing: 10) { taskDescription; taskAction }
        }.padding(18).frame(maxWidth: 860).readingGlass(radius: 23)
    }
    private var taskDescription: some View {
        HStack(spacing: 12) {
            if store.isBusy { ProgressView().controlSize(.small) }
            else { Image(systemName: store.book?.isFullyProcessed == true ? "checkmark.circle" : "book.pages").foregroundStyle(Palette.accent) }
            VStack(alignment: .leading, spacing: 5) {
                Text(store.isBusy ? "正在阅读与整理" : store.book?.plan == nil ? "从预读开始" : store.book?.isFullyProcessed == true ? "这一轮阅读已完成" : "准备继续阅读")
                    .font(.subheadline.weight(.semibold))
                Text(store.isBusy ? store.activity : store.book?.plan == nil ? "AI 先看简介和目录，再建议适合这本书的方法。" : "阅读会接着已保存的位置继续；细节可在处理详情查看。")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
    @ViewBuilder private var taskAction: some View {
        if store.isBusy {
            Button { store.pause() } label: { Label("暂停", systemImage: "pause.fill") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(!canPause)
        } else if store.book?.bookSchemes?.pending != nil {
            Button("确认方案") { store.openBookScheme() }.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            Button { store.book?.plan == nil ? store.makePlan() : store.startReading() } label: {
                Label(store.book?.plan == nil ? "预读并建议读法" : "继续精读", systemImage: "sparkles").frame(minHeight: 32)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.book == nil)
        }
    }
    private var adjustmentBinding: Binding<Bool> {
        Binding(get: { adjusting }, set: { value in
            if profileLoaded && !value && adjusting && profileDirty { discardChanges = true }
            else { adjusting = value }
        })
    }
    private var adjustmentContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("这本书可以属于几种类型").font(.subheadline.weight(.medium))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                        ForEach(BookGenre.allCases, id: \.self) { genre in
                            Button {
                                if draft.genres.contains(genre) { draft.genres.removeAll { $0 == genre } }
                                else { draft.genres.append(genre) }
                            } label: { Label(genre.readerTitle, systemImage: draft.genres.contains(genre) ? "checkmark.circle.fill" : genre.readerIcon).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                                .buttonStyle(ReadingToolbarButtonStyle(selected: draft.genres.contains(genre)))
                        }
                    }
                    ForEach(draft.customGenres, id: \.self) { value in
                        HStack { Label(value, systemImage: "tag"); Spacer(); Button { draft.customGenres.removeAll { $0 == value } } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("移除这个自定义书型") }
                    }
                    HStack(spacing: 6) {
                        TextField("自定义书型", text: $customGenre).textFieldStyle(.roundedBorder).onSubmit(addCustomGenre)
                        Button(action: addCustomGenre) { Image(systemName: "plus") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(customGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.customGenres.count >= 16)
                    }
                    Toggle("阅读时尽量不提前揭示后文", isOn: $draft.avoidsSpoilers).font(.subheadline)
                    Divider()
                    Text("书型帮助 AI 选方法。若要改变正在执行的步骤，请调整实际方案并确认。")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                    Button { store.openBookScheme() } label: { Label("调整实际执行方法", systemImage: "slider.horizontal.3") }.buttonStyle(ReadingToolbarButtonStyle())
                    Button { store.requestedWorkspaceRoute = "plugins" } label: { Label("自定义读书方法", systemImage: "puzzlepiece.extension") }.buttonStyle(ReadingToolbarButtonStyle())
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(store.isBusy)
            Divider().opacity(0.4)
            HStack { Text(profileDirty ? "有未保存调整" : "已与本书同步").font(.caption).foregroundStyle(.secondary); Spacer(); Button("保存偏好") { saveProfile(close: false) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!profileDirty || store.isBusy) }.padding(14)
        }
    }
    private func genrePill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .medium)).padding(.horizontal, 13).frame(minHeight: 34)
            .foregroundStyle(Palette.accent).background(Palette.accent.opacity(0.075), in: Capsule())
    }
    private func loadProfile() { profileBookID = store.bookID; draft = profile; customGenre = ""; profileLoaded = true }
    private func addCustomGenre() {
        let value = String(customGenre.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !value.isEmpty, draft.customGenres.count < 16, !draft.customGenres.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        draft.customGenres.append(value); customGenre = ""
    }
    private func saveProfile(close: Bool) {
        guard let bookID = profileBookID else { return }
        let captured = draft
        Task {
            if await store.saveReaderBookProfile(captured, inBook: bookID), store.bookID == bookID {
                loadProfile(); if close { adjusting = false }
            }
        }
    }
}
