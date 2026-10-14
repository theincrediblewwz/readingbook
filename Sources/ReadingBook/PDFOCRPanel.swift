import SwiftUI
import ReadingCore

struct PDFOCRPanel: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "missing"
    @State private var firstPage = 1
    @State private var lastPage = 1
    @State private var showDetails = false
    private var pages: [Int] { Array(Set(store.book?.units.compactMap(\.page) ?? [])).sorted() }
    private var selectedPages: [Int] {
        guard let book = store.book else { return [] }
        return pages.filter { page in
            guard OCRIntegration.unavailableReason(project: book, page: page) == nil else { return false }
            if mode == "range" { return page >= firstPage && page <= lastPage }
            if mode == "current" { return page == store.selectedUnit?.page }
            if mode == "missing" { return book.ocrPages?.contains(where: { $0.page == page }) != true && book.units.filter { $0.page == page }.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
            return book.ocrPages?.contains(where: { $0.page == page }) != true
        }
    }
    private var configuration: ProviderSettings {
        if let id = store.ocrServiceID, id != store.selectedServiceID, let saved = store.savedServices.first(where: { $0.id == id }) { return saved.settings }
        return store.settings
    }

    var body: some View {
        let selection = selectedPages
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PDF 页面识别").font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Text("逐页发送原始页图，转录为 Markdown 与 LaTeX").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    rangeFields(selectionCount: selection.count)
                    serviceFields
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
                Button("识别 \(selection.count) 页") { store.startOCR(pages: selection) }
                    .buttonStyle(.borderedProminent).disabled(selection.isEmpty || store.isBusy)
            }
        }.padding(18).controlSize(.small)
            .onAppear { firstPage = store.selectedUnit?.page ?? 1; lastPage = firstPage }
    }

    private func rangeFields(selectionCount: Int) -> some View {
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
                    TextField("起始页", value: $firstPage, format: .number).frame(maxWidth: 90)
                    Text("—").foregroundStyle(.secondary)
                    TextField("结束页", value: $lastPage, format: .number).frame(maxWidth: 90)
                    Spacer(minLength: 0)
                }.textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("可识别 \(selectionCount) 页").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("原书共 \(pages.count) 页").font(.caption).foregroundStyle(.secondary)
            }
            if selectionCount == 0 {
                Text("当前条件下没有可替换页；已有分析或引用的页会被保护。").font(.caption).foregroundStyle(.secondary)
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
