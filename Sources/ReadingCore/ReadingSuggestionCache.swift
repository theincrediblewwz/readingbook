import Foundation

public struct ReadingSuggestionCycle: Codable, Sendable {
    public var questions: [String]
    public var occupied: Bool
    public init(questions: [String] = [], occupied: Bool = false) { self.questions = questions; self.occupied = occupied }
}

/// Derived suggestion cycles, separated from books and original answers.
/// No API keys are stored; identity includes the book/source/scope/model.
public actor ReadingSuggestionCache {
    public static let shared = ReadingSuggestionCache()
    public init() { }
    private func url(root: URL, identity: String) throws -> URL {
        root.appendingPathComponent("ReadingSuggestions", isDirectory: true)
            .appendingPathComponent(try BookImporter.sha256(Data(identity.utf8)) + ".json")
    }
    public func read(root: URL, identity: String) -> ReadingSuggestionCycle? {
        guard let path = try? url(root: root, identity: identity),
              let attributes = try? path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) < 16_384,
              let data = try? Data(contentsOf: path), let cycle = try? JSONDecoder().decode(ReadingSuggestionCycle.self, from: data) else { return nil }
        if cycle.questions.isEmpty { return cycle }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["questions": cycle.questions]),
              (try? ReadingQuestionSuggestions.parse(String(decoding: payload, as: UTF8.self))) != nil else { return nil }
        return cycle
    }
    public func write(_ cycle: ReadingSuggestionCycle, root: URL, identity: String) throws {
        let path = try url(root: root, identity: identity), directory = path.deletingLastPathComponent()
        let data = try JSONEncoder().encode(cycle)
        guard data.count < 16_384 else { throw ReadingError.invalid("推荐问题缓存过大。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
        // A live batch is user-visible state: evicting it would secretly spend
        // another model request on return. Only occupied/empty cycles can retire.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && $0 != path }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
        for old in files.dropFirst(255) {
            guard let size = try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_384,
                  let data = try? Data(contentsOf: old), let value = try? JSONDecoder().decode(ReadingSuggestionCycle.self, from: data),
                  value.occupied || value.questions.isEmpty else { continue }
            try? FileManager.default.removeItem(at: old)
        }
    }
}
