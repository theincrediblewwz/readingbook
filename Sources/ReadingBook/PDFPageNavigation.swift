import SwiftUI

/// Lives in the window toolbar; the page view has no permanent second toolbar.
struct PDFPageNavigation: View {
    @EnvironmentObject var pdf: PDFReaderController
    @State private var entry = "1"
    @FocusState private var editingPage: Bool
    var body: some View {
        HStack(spacing: 7) {
            Button { pdf.command(.prev) } label: { Image(systemName: "chevron.left") }.help("上一页").disabled(!pdf.isReady || pdf.page <= 1)
            TextField("页码", text: $entry).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .font(.caption.monospacedDigit()).frame(width: 32).focused($editingPage)
                .onSubmit {
                    if let page = Int(entry), (1...max(1, pdf.pageCount)).contains(page) { pdf.command(.jump(page)) }
                    else { entry = String(pdf.page) }
                    editingPage = false
                }.disabled(!pdf.isReady).accessibilityLabel("PDF 页码，回车定位")
            Text("/ \(pdf.pageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { pdf.command(.next) } label: { Image(systemName: "chevron.right") }.help("下一页").disabled(!pdf.isReady || pdf.page >= pdf.pageCount)
        }.fixedSize().onChange(of: pdf.page) { _, page in if !editingPage { entry = String(page) } }
            .onChange(of: pdf.isReady) { _, _ in if !editingPage { entry = String(pdf.page) } }
    }
}
