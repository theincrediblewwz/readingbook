import Foundation

/// A transaction-local collision check, not a second knowledge store. Equivalent
/// spellings require the caller to reuse or disambiguate an ID; they never merge
/// facts automatically. Keep accents, punctuation and complete names intact.
struct KnowledgeIdentityIndex {
    private struct Key: Hashable { let typeID: String; let name: String }
    private var names: [Key: Set<String>] = [:]
    private var canonicalizer = LibrarySearchCanonicalizer()

    init(_ entities: [KnowledgeEntity]) throws {
        for entity in entities { try insert(entity) }
    }
    mutating func insert(_ entity: KnowledgeEntity) throws {
        for name in [entity.name] + entity.aliases {
            let value = try canonicalizer.fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !value.isEmpty else { continue }
            names[Key(typeID: entity.typeID, name: value), default: []].insert(entity.id)
        }
    }
    mutating func conflictingID(for entity: KnowledgeEntity) throws -> String? {
        var collisions = Set<String>()
        for name in [entity.name] + entity.aliases {
            let value = try canonicalizer.fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
            if let ids = names[Key(typeID: entity.typeID, name: value)] { collisions.formUnion(ids) }
        }
        collisions.remove(entity.id)
        return collisions.min()
    }
    static func conflict(in entities: [KnowledgeEntity], checking newIDs: Set<String>) throws -> String? {
        guard !newIDs.isEmpty else { return nil }
        var index = try Self(entities)
        for entity in entities where newIDs.contains(entity.id) {
            if let id = try index.conflictingID(for: entity) { return id }
        }
        return nil
    }
    static func conflictMessage(_ id: String) -> String {
        "同类型中已有名称或别名写法相同的对象（ID：\(id)，含繁简与全半角写法）。请核对并复用该稳定 ID；同名的不同对象请先用可区分的名称和别名消歧，已有资料保留。"
    }
}
