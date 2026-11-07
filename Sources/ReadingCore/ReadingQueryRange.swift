import Foundation

/// An explicit reader choice, frozen before any request or write grant. This
/// uses the same canonical chapter ranges as continued reading, not another
/// component's copy of the text or an interpretation of the user's question.
public struct ReadingQueryRange: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case pages, chapters }
    public var kind: Kind
    public var pageStart: Int?
    public var pageEnd: Int?
    public var chapterStartID: String?
    public var chapterEndID: String?
    public init(pageStart: Int, pageEnd: Int) {
        kind = .pages; self.pageStart = pageStart; self.pageEnd = pageEnd
    }
    public init(chapterStartID: String, chapterEndID: String) {
        kind = .chapters; self.chapterStartID = chapterStartID; self.chapterEndID = chapterEndID
    }
    func resolve(in project: BookProject) throws -> (title: String, ranges: [ReadingSourceRange]) {
        let ordered = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        switch kind {
        case .pages:
            guard chapterStartID == nil, chapterEndID == nil, let first = pageStart, let last = pageEnd,
                  first > 0, last >= first, ordered.contains(where: { $0.page == first }),
                  ordered.contains(where: { $0.page == last }) else { throw ReadingError.invalid("请选择书中已有的起止页码。") }
            let ranges = ordered.filter { $0.page.map { (first...last).contains($0) } ?? false }.filter { !$0.text.isEmpty }
                .map { ReadingSourceRange(unitID: $0.id, startUTF16: 0, endUTF16: $0.text.utf16.count) }
            guard !ranges.isEmpty else { throw ReadingError.invalid("所选页码没有可读取的原文。") }
            return (first == last ? "第 \(first) 页" : "第 \(first)–\(last) 页", ranges)
        case .chapters:
            guard pageStart == nil, pageEnd == nil, let first = chapterStartID, let last = chapterEndID,
                  let index = try BookChapterRuntime.index(in: project) else { throw ReadingError.invalid("请选择可信目录中的起止章节，或改用页码范围。") }
            var selection = SmartReadingSelection(scope: .chapterRange)
            selection.chapterStartID = first; selection.chapterEndID = last
            let ranges = try SmartReadingRuntime.selectedChapterRanges(selection, index: index, in: project)
            let start = index.chapters.first { $0.id == first }!, end = index.chapters.first { $0.id == last }!
            return (first == last ? start.title : start.title + "—" + end.title, ranges)
        }
    }
}
