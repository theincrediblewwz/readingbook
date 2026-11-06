import Foundation

/// A small host-built composition for a common reading task. It stores only
/// query/layout declarations and stable IDs, never copies of facts or notes.
public enum ReadingWorkbench {
    public static let templateID = "reading-workbench"
    public static let title = "人物、事件与笔记"
    public static func definition() -> CompositionDefinition { template }
    private static let template: CompositionDefinition = {
        let sources: [CompositionDataSource] = [
            .init(id: "objects", collection: .objects, scope: .book, limit: 200),
            .init(id: "relations", collection: .relations, scope: .book, limit: 200),
            .init(id: "details", collection: .objects, scope: .book, relation: .selected),
            .init(id: "events", collection: .events, scope: .book, relation: .events, limit: 200),
            .init(id: "notes", collection: .documents, scope: .book, relation: .documents, limit: 200)
        ]
        let parts: [CompositionPart] = [
            .init(id: "people", primitive: .objectList, sourceID: "objects", title: "书中要素"),
            .init(id: "graph", primitive: .relations, sourceID: "relations", title: "人物与事件关系"),
            .init(id: "detail", primitive: .objectDetail, sourceID: "details", title: "介绍与原文依据"),
            .init(id: "event-list", primitive: .objectList, sourceID: "events", title: "相关事件"),
            .init(id: "note-list", primitive: .markdown, sourceID: "notes", title: "相关笔记")
        ]
        let layout: [CompositionLayoutNode] = [
            .init(id: "root", kind: .row, children: ["people-frame", "main"]),
            .init(id: "people-frame", kind: .part, partID: "people", fraction: 0.28),
            .init(id: "main", kind: .column, children: ["graph-frame", "details-tabs"], fraction: 0.72),
            .init(id: "graph-frame", kind: .part, partID: "graph"),
            .init(id: "details-tabs", kind: .tabs, children: ["detail-frame", "events-frame", "notes-frame"]),
            .init(id: "detail-frame", kind: .part, partID: "detail"),
            .init(id: "events-frame", kind: .part, partID: "event-list"),
            .init(id: "notes-frame", kind: .part, partID: "note-list")
        ]
        return .init(sources: sources, parts: parts, layout: layout, rootID: "root")
    }()
    public static func isWorkbench(_ view: ViewDefinition?) -> Bool {
        view?.rendererID == "reading.composition" && view?.composition == definition()
    }
    public static func continuationQuestion(view: ViewDefinition) -> String {
        "继续整理“\(view.title)”（已有视图ID：\(view.id)）。先查看已保存的资料与本次范围内的处理缺口，只补充缺少的人物关系和事件；复用已有对象ID及这个工作台，保留我的修正与笔记，不重复生成已有介绍。每条新增结论带原文出处，推断要说清楚。"
    }
}
