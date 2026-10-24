import SwiftUI

/// Embedded in the floating reading controls above the original page.
struct PDFPageNavigation: View {
    @EnvironmentObject var pdf: PDFReaderController
    var onEditingChange: (Bool) -> Void = { _ in }
    @State private var entry = "1"
    @FocusState private var editingPage: Bool
    var body: some View {
        HStack(spacing: 4) {
            Button { pdf.command(.prev) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(ReadingToolbarButtonStyle()).help("上一页").disabled(!pdf.isReady || pdf.page <= 1)
            TextField("页码", text: $entry).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .font(.system(size: 14).monospacedDigit()).frame(width: 42, height: ReadingLayout.controlHeight).focused($editingPage)
                .onSubmit {
                    if let page = Int(entry), (1...max(1, pdf.pageCount)).contains(page) { pdf.command(.jump(page)) }
                    else { entry = String(pdf.page) }
                    editingPage = false
                }.onExitCommand { entry = String(pdf.page); editingPage = false }
                .disabled(!pdf.isReady).accessibilityLabel("PDF 页码，回车定位")
            Text("/ \(pdf.pageCount)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Button { pdf.command(.next) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(ReadingToolbarButtonStyle()).help("下一页").disabled(!pdf.isReady || pdf.page >= pdf.pageCount)
        }.fixedSize().onChange(of: pdf.page) { _, page in if !editingPage { entry = String(page) } }
            .onAppear { entry = String(pdf.page) }
            .onDisappear { onEditingChange(false) }
            .onChange(of: pdf.isReady) { _, ready in
                if !ready { editingPage = false }
                if !editingPage { entry = String(pdf.page) }
            }
            .onChange(of: editingPage) { _, value in
                if !value { entry = String(pdf.page) }
                onEditingChange(value)
            }
    }
}
