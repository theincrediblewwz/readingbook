import Foundation

public enum ReadingRecordGrouping: String, Codable, CaseIterable, Sendable {
    case date, chapter, none
    public var title: String { switch self { case .date: return "日期"; case .chapter: return "章节"; case .none: return "不分组" } }
}
public struct ReadingRecordDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let date: Date?
    public let chapterKey: String
    public let chapterTitle: String
    public let chapterOrder: Int
    public var preview: String = ""
}
public struct ReadingRecordGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let records: [ReadingRecordDescriptor]
}
public struct ReadingRecordCatalog: Sendable {
    public let records: [String: ReadingRecordDescriptor]
    public static func prepare(in project: BookProject) throws -> Self {
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chapterByUnit: [String: (key: String, title: String, order: Int)] = [:]
        if let index = try? BookChapterRuntime.index(in: project) {
            for (order, chapter) in index.segments.enumerated() {
                for range in chapter.ranges {
                    if let old = chapterByUnit[range.unitID], old.key != chapter.id {
                        chapterByUnit[range.unitID] = ("@multiple", "跨章节", Int.max - 1)
                    } else { chapterByUnit[range.unitID] = (chapter.id, chapter.title, order) }
                }
            }
        }
        let pdf = project.originalName.lowercased().hasSuffix(".pdf")
        func chapter(_ ids: [String]) -> (String, String, Int) {
            let values = Set(ids).compactMap { id -> (String, String, Int)? in
                guard let unit = units[id] else { return nil }
                if let value = chapterByUnit[id] { return (value.key, value.title, value.order) }
                if pdf, let page = unit.page { return ("@page:\(page)", "第 \(page) 页", unit.order) }
                let title = unit.chapter.trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : ("@chapter:" + title, title, unit.order)
            }
            guard let first = values.min(by: { $0.2 < $1.2 }) else { return ("@unbound", "未关联章节", Int.max) }
            guard Set(values.map { $0.0 }).count == 1 else { return ("@multiple", "跨章节或页面", Int.max - 1) }
            return first
        }
        var result: [String: ReadingRecordDescriptor] = [:]
        func add(_ id: String, _ title: String, _ date: Date?, _ sourceIDs: [String], body: String = "") throws {
            guard result[id] == nil else { throw ReadingError.invalid("记录身份重复，未合并或丢弃原内容。") }
            let scope = chapter(sourceIDs)
            result[id] = .init(id: id, title: title.isEmpty ? "未命名记录" : title, date: date,
                               chapterKey: scope.0, chapterTitle: scope.1, chapterOrder: scope.2, preview: FoldedReadingPreview.make(body, title: title))
        }
        for document in project.activeDocuments {
            try Task.checkCancellation()
            let placement = project.readerCollections?.notePlacements?[document.id]
            let ids = (placement?.matches(project) == true ? [placement!.unitID] : []) + document.evidence.map(\.unitID)
            try add("note:" + document.id, document.title, document.updatedAt, ids)
        }
        var question = ""
        for message in project.chats {
            try Task.checkCancellation()
            if message.role == "user" { question = String(message.content.prefix(120)) }
            let title = message.role == "assistant" ? (question.isEmpty ? String(message.content.prefix(120)) : question) : String(message.content.prefix(120))
            let contextual = message.readingContext?.sourceHash == project.sourceHash ? message.readingContext?.unitIDs ?? [] : []
            try add("chat:" + message.id, (message.role == "assistant" ? "回答：" : "提问：") + title, message.createdAt, contextual + message.evidence.map(\.unitID), body: message.content)
        }
        let anchors = Dictionary((project.readingExperience?.anchors ?? []).map { ($0.id, $0.unitID) }, uniquingKeysWith: { first, _ in first })
        for layer in project.readingExperience?.layers ?? [] { try add("layer:" + layer.id, layer.title, nil, layer.sourceAnchorIDs.compactMap { anchors[$0] }, body: layer.markdown) }
        for alignment in project.readingExperience?.alignments ?? [] { try add("alignment:" + alignment.id, alignment.title, nil, alignment.sourceAnchorIDs.compactMap { anchors[$0] }, body: alignment.markdown) }
        return .init(records: result)
    }
    public func groups(ids: [String], by mode: ReadingRecordGrouping, calendar: Calendar = .current) -> [ReadingRecordGroup] {
        let rows = ids.compactMap { records[$0] }
        if mode == .none { return rows.isEmpty ? [] : [.init(id: "@all", title: "全部记录", records: rows)] }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        let key = DateFormatter(); key.calendar = calendar; key.timeZone = calendar.timeZone; key.locale = Locale(identifier: "en_US_POSIX"); key.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: rows) { row in mode == .chapter ? row.chapterKey : row.date.map { key.string(from: $0) } ?? "@undated" }
        return grouped.map { id, records in
            ReadingRecordGroup(id: id, title: mode == .chapter ? records[0].chapterTitle : records[0].date.map { formatter.string(from: $0) } ?? "未标注日期", records: records)
        }.sorted {
            if mode == .date { if $0.id == "@undated" { return false }; if $1.id == "@undated" { return true }; return $0.id > $1.id }
            let lhs = $0.records.map(\.chapterOrder).min() ?? Int.max, rhs = $1.records.map(\.chapterOrder).min() ?? Int.max
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }
}
