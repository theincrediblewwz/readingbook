import SwiftUI
import ReadingCore

struct PDFOCRPanel: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "missing"
    @State private var firstPage = 1
    @State private var lastPage = 1
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("把扫描页变成可读的文字", systemImage: "viewfinder").font(.system(size: 23, design: .serif))
            Text("将 PDF 的原页图发送给你选择的视觉模型，逐页转录为 Markdown 与 LaTeX。原书保持原样，每页保存完成后才继续下一页。").font(.subheadline).foregroundStyle(.secondary)
            Form {
                Picker("识别范围", selection: $mode) {
                    Text("缺少文本的页").tag("missing"); Text("当前页").tag("current"); Text("指定页码").tag("range"); Text("所有尚未 OCR 的可替换页").tag("all")
                }
                if mode == "range" {
                    HStack { TextField("起始页", value: $firstPage, format: .number); Text("—"); TextField("结束页", value: $lastPage, format: .number) }
                }
                Picker("图像模型配置", selection: Binding(get: { store.ocrServiceID ?? "" }, set: { store.ocrServiceID = $0.isEmpty ? nil : $0; UserDefaults.standard.set(store.ocrServiceID, forKey: "ocr-service") })) {
                    Text("当前阅读配置 · \(store.settings.model)").tag("")
                    ForEach(store.savedServices) { service in Text("\(service.name) · \(service.settings.model)").tag(service.id) }
                }
                Text("本次 \(selectedPages.count) 页，每页一个模型请求；达到配置的每轮请求预算会暂停。已识别页可在尚未产生分析/引用时重识别，失败后选择剩余页继续。").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            Text("有阅读结论或引用的页面会被保护，不覆盖旧依据。看不清的符号、图表和复杂排版会保留待核对标记，识别成功不表示理解或提取无遗漏。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("设置服务") { dismiss(); store.showingSettings = true }; Button("识别 \(selectedPages.count) 页") { store.startOCR(pages: selectedPages) }.buttonStyle(.borderedProminent).disabled(selectedPages.isEmpty || store.isBusy) }
        }.padding(28).onAppear { firstPage = store.selectedUnit?.page ?? 1; lastPage = firstPage }
    }
}
