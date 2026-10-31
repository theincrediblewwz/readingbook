import Foundation

public struct ReadingNoteTopicInput: Codable, Sendable {
    public var id: String
    public var title: String
    public var excerpt: String
    public init(id: String, title: String, excerpt: String) { self.id = id; self.title = title; self.excerpt = excerpt }
}
public struct ReadingNoteTopicGroup: Codable, Hashable, Sendable {
    public var title: String
    public var noteIDs: [String]
    public init(title: String, noteIDs: [String]) { self.title = title; self.noteIDs = noteIDs }
}
public enum ReadingNoteTopicRuntime {
    public static func parse(_ text: String, offeredIDs: Set<String>) throws -> [ReadingNoteTopicGroup] {
        guard text.utf8.count <= 32_768, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["groups"],
              let rows = object["groups"] as? [[String: Any]], (1...20).contains(rows.count),
              rows.allSatisfy({ Set($0.keys) == ["title", "noteIDs"] }) else { throw ReadingError.invalid("笔记分类建议未完整返回。") }
        guard let groups = try? JSONDecoder().decode([ReadingNoteTopicGroup].self, from: JSONSerialization.data(withJSONObject: rows)) else {
            throw ReadingError.invalid("分类建议的名称或笔记清单格式不对，没有改动任何笔记。")
        }
        var seen = Set<String>(), names = Set<String>()
        for group in groups {
            guard !group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, group.title.count <= 40,
                  group.title == group.title.trimmingCharacters(in: .whitespacesAndNewlines),
                  !group.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !group.title.utf8.contains(0), names.insert(group.title).inserted, !group.noteIDs.isEmpty,
                  group.noteIDs.allSatisfy({ offeredIDs.contains($0) && seen.insert($0).inserted }) else {
                throw ReadingError.invalid("分类建议含有未知、重复笔记或无效名称，未改动任何内容。")
            }
        }
        return groups
    }
}
