import SwiftUI
import ReadingCore

/// Capture the owner and the reader's scope before presenting a confirmation.
/// Changing book/library/page while the sheet is open cannot authorize a
/// request for that new context.
struct CompanionGenerationIntent: Identifiable {
    let id = UUID()
    let bookID: String
    let rootPath: String
    let sourceHash: String
    let contextKey: String
    let scope: ReadingQueryScope
    let title: String
    let review: ReadingCompanionGenerationReview

    @MainActor init?(store: AppStore, contextKey: String, scope: ReadingQueryScope,
                     title: String, review: ReadingCompanionGenerationReview) {
        guard let book = store.book else { return nil }
        bookID = book.id; rootPath = store.libraryRootURL.path; sourceHash = book.sourceHash
        self.contextKey = contextKey; self.scope = scope; self.title = title; self.review = review
    }

    @MainActor func stillMatches(_ store: AppStore, contextKey: String) -> Bool {
        store.bookID == bookID && store.libraryRootURL.path == rootPath && store.book?.sourceHash == sourceHash
            && self.contextKey == contextKey
    }
}

private struct CompanionGenerationConfirmation: ViewModifier {
    @Binding var intent: CompanionGenerationIntent?
    var generate: (CompanionGenerationIntent) -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog("这部分已有保存的分析，继续生成？", isPresented: Binding(
            get: { intent != nil }, set: { if !$0 { intent = nil } }), presenting: intent) { request in
                Button("继续补充") { generate(request) }
                Button("保留现有内容", role: .cancel) { }
            } message: { request in
                Text("\(request.title)\n继续会再次请求模型补充，对象资料可能更新。已有解释、译文、原书和笔记保留；相同条目会复用，新增内容会单独保存。")
            }
    }
}

extension View {
    func companionGenerationConfirmation(_ intent: Binding<CompanionGenerationIntent?>,
                                         generate: @escaping (CompanionGenerationIntent) -> Void) -> some View {
        modifier(CompanionGenerationConfirmation(intent: intent, generate: generate))
    }
}
