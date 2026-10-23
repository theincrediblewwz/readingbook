import Foundation

/// A presentation index, preserving physical node identity when two cards point
/// at the same document. Build once for changed data, never once for each node.
public struct GraphIdentityIndex: Sendable {
    public let ordinalByNodeID: [String: Int]
    public let targetByNodeID: [String: String]
    public let firstNodeByTargetID: [String: String]
    public init(nodes: [(nodeID: String, targetID: String)]) {
        var ordinals: [String: Int] = [:], targets: [String: String] = [:], first: [String: String] = [:]
        for (index, node) in nodes.enumerated() where ordinals[node.nodeID] == nil {
            ordinals[node.nodeID] = index + 1; targets[node.nodeID] = node.targetID
            if first[node.targetID] == nil { first[node.targetID] = node.nodeID }
        }
        ordinalByNodeID = ordinals; targetByNodeID = targets; firstNodeByTargetID = first
    }
    public func selectedNode(targetID: String?, preferredNodeID: String?) -> String? {
        guard let targetID else { return nil }
        if let preferredNodeID, targetByNodeID[preferredNodeID] == targetID { return preferredNodeID }
        return firstNodeByTargetID[targetID]
    }
}
