import SwiftUI
import ReadingCore

/// Editing this form changes no permission until the reader presses Apply.
struct QuerySourceRangePicker: View {
    @EnvironmentObject private var store: AppStore
    var apply: (ReadingQueryRange) -> Void
    var cancel: () -> Void
    @State private var byChapter = false
    @State private var firstPage = ""
    @State private var lastPage = ""
    @State private var chapters: [BookChapterRange] = []
    @State private var firstChapter = ""
    @State private var lastChapter = ""
    @State private var loading = false
    @State private var error: String?
    private var ends: [BookChapterRange] {
        guard let start = chapters.firstIndex(where: { $0.id == firstChapter }) else { return [] }
        return Array(chapters[start...]).filter { $0.level == chapters[start].level && $0.isComplete }
    }
    private var choice: ReadingQueryRange? {
        if byChapter {
            guard !firstChapter.isEmpty, ends.contains(where: { $0.id == lastChapter }) else { return nil }
            return .init(chapterStartID: firstChapter, chapterEndID: lastChapter)
        }
        guard let first = Int(firstPage), let last = Int(lastPage), first > 0, last >= first,
              store.book?.units.contains(where: { $0.page == first }) == true,
              store.book?.units.contains(where: { $0.page == last }) == true else { return nil }
        return .init(pageStart: first, pageEnd: last)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                mode("页码", selected: !byChapter) { byChapter = false }
                mode("章节", selected: byChapter) { byChapter = true }
            }
            if byChapter {
                if loading { ProgressView("读取目录…").frame(minHeight: 80) }
                else if chapters.isEmpty { Text(error ?? "还没有可信的章节目录，可以先按页码选择。").foregroundStyle(.secondary).padding(.vertical, 16) }
                else {
                    chapterMenu("从", selection: $firstChapter, values: chapters.filter(\.isComplete))
                    chapterMenu("到", selection: $lastChapter, values: ends)
                }
            } else {
                HStack(spacing: 12) {
                    Text("从"); TextField("起始页", text: $firstPage).textFieldStyle(.roundedBorder).accessibilityIdentifier("query-range-first-page")
                    Text("到"); TextField("结束页", text: $lastPage).textFieldStyle(.roundedBorder).accessibilityIdentifier("query-range-last-page")
                }.font(.system(size: 15)).padding(.vertical, 12)
            }
            HStack {
                Button("返回") { cancel() }.buttonStyle(ReadingQuietButtonStyle())
                Spacer()
                Button("使用这个范围") { if let choice { apply(choice) } }
                    .buttonStyle(ReadingActionButtonStyle()).disabled(choice == nil || loading)
                    .accessibilityIdentifier("query-range-apply").help("只允许这次提问读取所选范围；不会自动开始生成")
            }
        }.padding(12)
            .onAppear {
                let saved = store.querySourceRange
                byChapter = saved?.kind == .chapters
                firstPage = String(saved?.pageStart ?? store.selectedUnit?.page ?? 1)
                lastPage = String(saved?.pageEnd ?? store.selectedUnit?.page ?? 1)
                firstChapter = saved?.chapterStartID ?? ""; lastChapter = saved?.chapterEndID ?? ""
            }
            .task(id: byChapter) {
                guard byChapter, chapters.isEmpty else { return }
                loading = true; error = nil
                defer { loading = false }
                do {
                    let result = try await store.readingContinuationChapters()
                    guard !Task.isCancelled else { return }
                    chapters = result
                    if !result.contains(where: { $0.id == firstChapter && $0.isComplete }) { firstChapter = result.first(where: \.isComplete)?.id ?? "" }
                    if !ends.contains(where: { $0.id == lastChapter }) { lastChapter = firstChapter }
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: firstChapter) { _, _ in if !ends.contains(where: { $0.id == lastChapter }) { lastChapter = firstChapter } }
    }
    private func mode(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 38) }
            .buttonStyle(ReadingQuietButtonStyle()).background(selected ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .help("按\(title)选择范围")
    }
    private func chapterMenu(_ title: String, selection: Binding<String>, values: [BookChapterRange]) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Menu {
                ForEach(values) { chapter in Button(chapter.title) { selection.wrappedValue = chapter.id } }
            } label: {
                HStack { Text(values.first(where: { $0.id == selection.wrappedValue })?.title ?? "选择章节").lineLimit(2); Spacer(); Image(systemName: "chevron.down") }
                    .padding(10).frame(maxWidth: .infinity, minHeight: 44)
            }.menuStyle(.borderlessButton).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .help("选择\(title == "从" ? "起始" : "结束")章节")
        }
    }
}
