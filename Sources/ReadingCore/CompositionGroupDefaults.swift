import Foundation

/// Presence matters only while decoding, not in the persisted model.
struct CompositionGroupDeclaration: Decodable {
    var selectionGroup: String?
    var timeGroup: String?
}

extension CompositionDefinition {
    mutating func resolveGroupDefaults(sourceGroups: [CompositionGroupDeclaration], partGroups: [CompositionGroupDeclaration]) {
        // Oversized declarations are rejected by the validator; do not build an
        // unbounded graph before it gets a chance to report them.
        guard sources.count <= 12, parts.count <= 24 else { return }
        let count = sources.count + parts.count
        var neighbors = [[Int]](repeating: [], count: count)
        var sourceIndices = [String: Int]()
        for index in sources.indices where sourceIndices[sources[index].id] == nil { sourceIndices[sources[index].id] = index }
        for index in parts.indices {
            let partIndex = sources.count + index
            var ids = [parts[index].sourceID]
            if parts[index].primitive == .map, let routeID = parts[index].routeSourceID,
               let routeIndex = sourceIndices[routeID], sources[routeIndex].collection == .relations { ids.append(routeID) }
            for id in ids {
                guard let sourceIndex = sourceIndices[id] else { continue }
                neighbors[partIndex].append(sourceIndex); neighbors[sourceIndex].append(partIndex)
            }
        }
        let declarations = sourceGroups + partGroups
        func defaults(_ key: KeyPath<CompositionGroupDeclaration, String?>) -> [Int: String] {
            var visited = Set<Int>(), result = [Int: String]()
            for start in 0..<count where !visited.contains(start) {
                var queue = [start], component = [Int](), names = Set<String>()
                visited.insert(start)
                while let next = queue.popLast() {
                    component.append(next)
                    if let name = declarations[next][keyPath: key] { names.insert(name) }
                    for neighbor in neighbors[next] where visited.insert(neighbor).inserted { queue.append(neighbor) }
                }
                // Conflicting explicit names are left to validation. Completing
                // one uniquely determined value is not a guess about the layout.
                guard names.count == 1, let name = names.first else { continue }
                for index in component where declarations[index][keyPath: key] == nil { result[index] = name }
            }
            return result
        }
        for (index, group) in defaults(\.selectionGroup) {
            if index < sources.count { sources[index].selectionGroup = group }
            else { parts[index - sources.count].selectionGroup = group }
        }
        for (index, group) in defaults(\.timeGroup) {
            if index < sources.count { sources[index].timeGroup = group }
            else { parts[index - sources.count].timeGroup = group }
        }
    }
}
