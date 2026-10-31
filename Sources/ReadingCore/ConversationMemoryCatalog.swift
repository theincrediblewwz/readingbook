import Foundation

/// Browsing is independent of automatic-context admission. In particular an
/// unrelated book must not consume this book's catalog limit.
public enum ConversationMemoryCatalog {
    public static func read(bookID: String, messages: [ChatMessage], root: URL) -> [ConversationMemory] {
        let directory = root.appendingPathComponent("ConversationMemory", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        let known = Dictionary(messages.map { ($0.id, $0.role) }, uniquingKeysWith: { first, _ in first })
        var result: [ConversationMemory] = [], seen = Set<String>()
        for url in urls where url.pathExtension == "json" {
            if Task.isCancelled { return [] }
            guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 1_048_576,
                  let data = try? Data(contentsOf: url), let memory = try? JSONDecoder().decode(ConversationMemory.self, from: data),
                  memory.version == 1, memory.bookID == bookID, memory.id == bookID + ":" + memory.scopeFingerprint,
                  memory.scopeFingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  memory.updatedAt.timeIntervalSince1970.isFinite, (memory.scopeTitle?.count ?? 0) <= 200 else { continue }
            let groups = [memory.requirements, memory.conclusions, memory.unresolved]
            guard groups.contains(where: { !$0.isEmpty }), groups.allSatisfy({ $0.count <= 12 }),
                  groups.flatMap({ $0 }).allSatisfy({ item in
                      !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.text.count <= 800 &&
                      (1...8).contains(item.sources.count) && Set(item.sources).count == item.sources.count && item.sources.allSatisfy { known[$0] != nil }
                  }), seen.insert(memory.id).inserted else { continue }
            result.append(memory)
        }
        return result.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
}
