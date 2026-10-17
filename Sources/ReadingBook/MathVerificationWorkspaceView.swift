import SwiftUI
import ReadingCore

struct MathVerificationWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    var definition: ViewDefinition?
    @State private var mode = MathVerificationMode.solveLinearSystem
    @State private var title = "矩阵与线性方程组"
    @State private var matrix = ""
    @State private var operation = MathRowOperationKind.add
    @State private var targetRow = 2
    @State private var sourceRow = 1
    @State private var factor = "-2"
    @State private var expected = ""
    @State private var steps: [MathRowStep] = []
    @State private var evidence: [Evidence] = []
    @State private var selectedID: String?
    @State private var inputError: String?
    @State private var showInput = true
    @State private var showDeleted = false
    @State private var deleting: String?
    private var records: [MathVerificationRecord] { (store.book?.mathVerifications ?? []).filter { showDeleted ? $0.deletedAt != nil : $0.deletedAt == nil }.reversed() }
    private var selected: MathVerificationRecord? { records.first { $0.id == selectedID } ?? records.first }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                header
                if geometry.size.width >= 1000 {
                    HStack(alignment: .top, spacing: 18) {
                        if showInput { inputPanel.frame(width: min(360, geometry.size.width * 0.35)) }
                        results.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 18) {
                            if showInput { inputFields.padding(20).readingGlass(radius: 22) }
                            results.frame(minHeight: 450)
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 96).padding(.bottom, 22)
        }
        .onAppear { selectReferencedRecord() }
        .onChange(of: store.selectedObjectID) { _, _ in selectReferencedRecord() }
        .onChange(of: store.bookID) { _, _ in clearDraft(); selectedID = nil; showDeleted = false; deleting = nil }
        .confirmationDialog("删除这条核查记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("移到已删除", role: .destructive) { if let deleting { setDeleted(deleting, deleted: true) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("仍可在数学核查的“已删除”中恢复，已保存的 Markdown 不受影响。") }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack { heading; Spacer(); headerActions }
            VStack(alignment: .leading, spacing: 12) { heading; headerActions }
        }
    }
    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: "function").font(.system(size: 26)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("数学核查").font(.system(size: 27, weight: .semibold))
                Text("本地精确分数计算 · 不消耗模型调用").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
    }
    private var headerActions: some View {
        HStack(spacing: 10) {
            Button { withAnimation { showInput.toggle() } } label: { Label(showInput ? "收起输入" : "新建核查", systemImage: showInput ? "sidebar.left" : "plus") }
            Toggle("已删除", isOn: $showDeleted).toggleStyle(.button).onChange(of: showDeleted) { _, _ in selectedID = nil }
        }.controlSize(.large)
    }
    private var inputPanel: some View {
        ScrollView { inputFields.padding(20) }.readingGlass(radius: 22)
    }
    private var inputFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("数字矩阵").font(.headline); Spacer()
                Menu {
                    Button("载入线性方程组示例") {
                        matrix = "1 -1 2 1\n1 -2 -1 2\n3 -1 5 3\n-1 0 2 -2"; mode = .solveLinearSystem; steps = []; evidence = []; inputError = nil
                    }
                    Button("清空输入") { clearDraft() }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 32, height: 32) }.menuStyle(.borderlessButton)
            }
            TextField("核查标题", text: $title).textFieldStyle(.roundedBorder)
            Picker("核查方式", selection: $mode) {
                Text("解线性方程组").tag(MathVerificationMode.solveLinearSystem)
                Text("逐步检查").tag(MathVerificationMode.checkRowSteps)
            }.pickerStyle(.segmented).labelsHidden()
            Text(mode == .solveLinearSystem ? "每行一条方程，末列为常数。数字以空格或逗号分隔。" : "输入变换前的矩阵，再为每一步添加操作与声称的结果。").font(.caption).foregroundStyle(.secondary)
            matrixEditor($matrix, label: "初始矩阵", height: 140)
            Text("支持整数、分数和最多六位小数；最多 8 行、9 列。符号方程和超出精确范围的数字会被拒绝。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if mode == .checkRowSteps { rowStepBuilder }
            Divider()
            if let unit = store.selectedUnit, !unit.text.isEmpty {
                Button {
                    evidence = [Evidence(unitID: unit.id, quote: String(unit.text.prefix(1200)))]
                } label: { Label("附当前原文出处", systemImage: "link") }.buttonStyle(.bordered)
            }
            if !evidence.isEmpty {
                HStack(alignment: .top) {
                    Text("已附出处。仍需自行对照矩阵数值与原文。").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button { evidence = [] } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("移除出处")
                }
            }
            if let inputError { Text(inputError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Button { calculate() } label: {
                Label(store.isBusy ? "正在处理…" : "开始精确核查", systemImage: "checkmark.seal").frame(maxWidth: .infinity, minHeight: 32)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(store.book == nil || store.isBusy || matrix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == .checkRowSteps && steps.isEmpty))
        }.disabled(store.isBusy)
    }
    private var rowStepBuilder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider(); Text("行变换步骤 · \(steps.count)").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack {
                    Text("\(index + 1). \(step.operation.label)").font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button { steps.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("移除此步骤")
                }
            }
            Picker("操作", selection: $operation) {
                Text("两行交换").tag(MathRowOperationKind.swap)
                Text("一行倍乘").tag(MathRowOperationKind.scale)
                Text("两行倍加").tag(MathRowOperationKind.add)
            }
            Stepper("目标行 R\(targetRow)", value: $targetRow, in: 1...8)
            if operation != .scale { Stepper("来源行 R\(sourceRow)", value: $sourceRow, in: 1...8) }
            if operation != .swap { TextField("倍数，例如 -2 或 1/3", text: $factor).textFieldStyle(.roundedBorder) }
            Text(MathRowOperation(kind: operation, targetRow: targetRow, sourceRow: operation == .scale ? nil : sourceRow, factor: operation == .swap ? nil : factor).label)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.accent)
            matrixEditor($expected, label: "这一步声称得到的完整矩阵", height: 110)
            Button("添加这一步") {
                do {
                    guard steps.count < MathVerificationEngine.maximumSteps else { throw ReadingError.invalid("最多 128 步。") }
                    let values = try MathVerificationEngine.parseMatrix(expected)
                    let rowOperation = MathRowOperation(kind: operation, targetRow: targetRow, sourceRow: operation == .scale ? nil : sourceRow, factor: operation == .swap ? nil : factor)
                    steps.append(MathRowStep(operation: rowOperation, expected: values)); expected = ""; inputError = nil
                } catch { inputError = error.localizedDescription }
            }.buttonStyle(.bordered).disabled(expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if records.isEmpty { Text(showDeleted ? "没有已删除记录" : "核查记录").font(.headline) }
                else {
                    Picker("核查记录", selection: Binding(get: { selected?.id ?? "" }, set: { selectedID = $0 })) {
                        ForEach(records) { record in Text(record.title + " · " + record.createdAt.formatted(date: .numeric, time: .shortened)).tag(record.id) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
                if let selected {
                    if showDeleted {
                        Button("恢复") { setDeleted(selected.id, deleted: false) }.buttonStyle(.bordered)
                    } else {
                        Menu {
                            Button("存为 Markdown 草稿") { store.makeNoteFromMathVerification(selected) }
                            Button("载入原输入") { load(selected) }
                            Divider()
                            Button("删除记录…", role: .destructive) { deleting = selected.id }
                        } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }.menuStyle(.borderlessButton)
                    }
                }
            }.disabled(store.isBusy)
            if let selected {
                HStack(spacing: 8) {
                    Image(systemName: selected.status == .verified ? "checkmark.seal.fill" : "xmark.seal.fill")
                    Text(selected.status == .verified ? "数字运算核查通过" : "发现不一致，已停止核查").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(selected.request.origin == .user ? "手动输入" : "AI 转录").font(.caption)
                }.foregroundStyle(selected.status == .verified ? Palette.accent : Color.orange)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        MarkdownText(markdown: selected.markdown)
                        if !selected.request.evidence.isEmpty { EvidenceList(evidence: selected.request.evidence) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
            } else {
                EmptyState(title: showDeleted ? "记录可从这里恢复" : "让计算留下可查的步骤", detail: "输入矩阵或载入示例。结果会保留输入、每次行变换和精确回代；AI 阅读时也可以调用同一个工具。", icon: "function")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func matrixEditor(_ text: Binding<String>, label: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden)
                .frame(height: height).padding(8).background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent.opacity(0.12)))
                .accessibilityLabel(label)
        }
    }
    private func calculate() {
        guard let bookID = store.bookID else { return }
        inputError = nil
        let request = MathVerificationRequest(title: title, input: matrix, mode: mode, steps: mode == .checkRowSteps ? steps : [], evidence: evidence)
        Task {
            if let id = await store.verifyMathematics(request, inBook: bookID), store.bookID == bookID { selectedID = id; showDeleted = false }
        }
    }
    private func setDeleted(_ id: String, deleted: Bool) {
        guard let bookID = store.bookID else { return }
        Task {
            await store.setMathVerificationDeleted(id, deleted: deleted, inBook: bookID)
            guard store.bookID == bookID else { return }
            if !deleted { showDeleted = false; selectedID = id }
        }
    }
    private func load(_ record: MathVerificationRecord) {
        title = record.title; mode = record.request.mode
        matrix = (record.request.matrix ?? record.normalizedMatrix).map { $0.joined(separator: " ") }.joined(separator: "\n")
        steps = record.request.steps; evidence = record.request.evidence; expected = ""; inputError = nil; showInput = true
    }
    private func clearDraft() {
        matrix = ""; expected = ""; steps = []; evidence = []; inputError = nil
        title = "矩阵与线性方程组"; mode = .solveLinearSystem
    }
    private func selectReferencedRecord() {
        guard let record = store.book?.mathVerifications?.first(where: { $0.id == store.selectedObjectID }) else { return }
        selectedID = record.id; showDeleted = record.deletedAt != nil; showInput = false
    }
}
