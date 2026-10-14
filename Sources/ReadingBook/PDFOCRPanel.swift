import SwiftUI
import ReadingCore

struct PDFOCRPanel: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "missing"
    @State private var firstPage = "1"
    @State private var lastPage = "1"
    @State private var showDetails = false
    private var pages: [Int] { Array(Set(store.book?.units.compactMap(\.page) ?? [])).sorted() }
    private var selection: OCRPageSelection {
        OCRPageSelection(project: store.book, mode: mode, first: firstPage, last: lastPage, currentPage: store.selectedUnit?.page)
    }
    private var configuration: ProviderSettings {
        if let id = store.ocrServiceID, id != store.selectedServiceID, let saved = store.savedServices.first(where: { $0.id == id }) { return saved.settings }
        return store.settings
    }

    var body: some View {
        let summary = selection
        let runCount = min(summary.recognizable.count, max(0, configuration.maxRequestsPerRun))
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PDF 页面识别").font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Text("逐页发送原始页图，转录为 Markdown 与 LaTeX").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    rangeFields(summary)
                    serviceFields
                    OCRLaunchError(draft: store.serviceProfileDraft)
                    DisclosureGroup("识别规则与限制", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("每页一个模型请求，完成一页才保存；达到配置的每轮预算后暂停。失败后选择剩余页继续。")
                            Text("已有阅读结论或知识引用的页面会被保护。已识别页仅在尚未产生分析或引用时可以重识别。")
                            Text("原始 PDF 保持不变。看不清的符号、图表和复杂排版保留待核对标记；识别成功不表示理解或提取无遗漏。")
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }.font(.system(size: 12)).padding(.horizontal, 2)
                }.padding(.vertical, 2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("设置服务") { dismiss(); store.showingSettings = true }
                Button("识别 \(runCount) 页") { store.startOCR(pages: summary.recognizable) }
                    .buttonStyle(.borderedProminent).disabled(summary.recognizable.isEmpty || summary.validationError != nil || store.isBusy)
            }
        }.padding(18).controlSize(.small)
            .onAppear { firstPage = String(store.selectedUnit?.page ?? pages.first ?? 1); lastPage = firstPage; store.serviceProfileDraft.ocrError = "" }
    }

    private func rangeFields(_ summary: OCRPageSelection) -> some View {
        CompactSettingsSection("页面与范围") {
            Picker("识别范围", selection: $mode) {
                Text("缺少文本的页").tag("missing")
                Text("当前页").tag("current")
                Text("指定页码").tag("range")
                Text("未 OCR 的可替换页").tag("all")
            }.font(.system(size: 12))
            if mode == "range" {
                HStack(spacing: 8) {
                    Text("原 PDF 页码").font(.system(size: 12))
                    TextField("起始页", text: $firstPage).frame(maxWidth: 90).accessibilityLabel("OCR 起始页")
                    Text("—").foregroundStyle(.secondary)
                    TextField("结束页", text: $lastPage).frame(maxWidth: 90).accessibilityLabel("OCR 结束页")
                    Spacer(minLength: 0)
                }.textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("本轮将识别 \(min(summary.recognizable.count, max(0, configuration.maxRequestsPerRun))) 页 · 跳过 \(summary.skippedCount) 页").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("原书共 \(pages.count) 页").font(.caption).foregroundStyle(.secondary)
            }
            if let error = summary.validationError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            } else {
                if summary.recognizable.isEmpty {
                    Text(summary.requestedCount == 0 ? "此条件没有对应的原 PDF 页面。" : "此范围没有可识别页，请查看以下跳过原因或更换范围。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(summary.skipped) { skipped in
                    DisclosureGroup {
                        Text("原 PDF 第 \(OCRPageSelection.pageRanges(skipped.pages)) 页")
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 4)
                    } label: {
                        Text("\(skipped.pages.count) 页：\(skipped.reason)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if summary.recognizable.count > configuration.maxRequestsPerRun {
                    Text("另有 \(summary.recognizable.count - max(0, configuration.maxRequestsPerRun)) 页可识别；本轮请求预算用完后，可选择剩余页续跑。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var serviceFields: some View {
        CompactSettingsSection("图像服务与预算") {
            Picker("模型配置", selection: Binding(get: { store.ocrServiceID ?? "" }, set: { store.ocrServiceID = $0.isEmpty ? nil : $0; UserDefaults.standard.set(store.ocrServiceID, forKey: "ocr-service") })) {
                Text("当前阅读服务 · \(store.serviceName)").tag("")
                ForEach(store.savedServices) { service in Text("\(service.name) · \(service.settings.model)").tag(service.id) }
            }.font(.system(size: 12))
            Text(configuration.model.isEmpty ? "尚未配置图像模型，请先设置服务。" : configuration.model)
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            Text("每轮上限 \(configuration.maxRequestsPerRun) 次 · 输出上限 \(configuration.maxOutputTokens) token")
                .font(.caption).foregroundStyle(.secondary)
            Text("服务须支持图像输入；识别后请对照原页核对。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct OCRLaunchError: View {
    @ObservedObject var draft: ServiceProfileDraftState
    var body: some View {
        if !draft.ocrError.isEmpty {
            Label(draft.ocrError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Preflight only: no image rendering, Keychain access, or service request.
struct OCRPageSelection {
    struct Skipped: Identifiable {
        var reason: String
        var pages: [Int]
        var id: String { reason }
    }
    var recognizable: [Int] = []
    var skipped: [Skipped] = []
    var requestedCount = 0
    var validationError: String?
    var skippedCount: Int { skipped.reduce(0) { $0 + $1.pages.count } }

    init(project: BookProject?, mode: String, first: String, last: String, currentPage: Int?) {
        guard let project else { validationError = "请先选择一本 PDF。"; return }
        let pages = Array(Set(project.units.compactMap(\.page))).sorted()
        guard let maximum = pages.last else { validationError = "本书没有 PDF 页码，不能按页识别。"; return }
        let requested: [Int]
        if mode == "range" {
            let startText = first.trimmingCharacters(in: .whitespacesAndNewlines)
            let endText = last.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !startText.isEmpty, !endText.isEmpty,
                  startText.utf8.allSatisfy({ (48...57).contains($0) }), endText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let start = Int(startText), let end = Int(endText) else { validationError = "请填写整数页码，例如 1 到 \(maximum)。"; return }
            guard start >= 1, end >= 1, start <= maximum, end <= maximum else { validationError = "页码须在 1 到 \(maximum) 之间。"; return }
            guard start <= end else { validationError = "起始页不能大于结束页。"; return }
            requested = pages.filter { (start...end).contains($0) }
        } else if mode == "current" {
            guard let currentPage, pages.contains(currentPage) else { validationError = "尚未选中原 PDF 页，请先选择页面或指定页码。"; return }
            requested = [currentPage]
        } else { requested = pages }
        requestedCount = requested.count
        let recognized = Set((project.ocrPages ?? []).map(\.page))
        let unitsByPage = Dictionary(grouping: project.units, by: { $0.page ?? -1 })
        var grouped: [String: [Int]] = [:]
        for page in requested {
            let reason: String?
            if let protected = OCRIntegration.unavailableReason(project: project, page: page) { reason = protected }
            else if (mode == "missing" || mode == "all"), recognized.contains(page) { reason = "已有 OCR 转录。指定页码可在未被引用时重新识别。" }
            else if mode == "missing", (unitsByPage[page] ?? []).contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { reason = "已有可用文本。需要重识别时请选择当前页或指定页码。" }
            else { reason = nil }
            if let reason { grouped[reason, default: []].append(page) }
            else { recognizable.append(page) }
        }
        skipped = grouped.map { Skipped(reason: $0.key, pages: $0.value) }.sorted { ($0.pages.first ?? 0) < ($1.pages.first ?? 0) }
    }

    static func pageRanges(_ pages: [Int]) -> String {
        var parts: [String] = []
        var first: Int?, previous: Int?
        for page in pages.sorted() {
            if let end = previous, page == end + 1 { previous = page; continue }
            if let start = first, let end = previous { parts.append(start == end ? String(start) : "\(start)–\(end)") }
            first = page; previous = page
        }
        if let start = first, let end = previous { parts.append(start == end ? String(start) : "\(start)–\(end)") }
        return parts.joined(separator: "、")
    }
}
