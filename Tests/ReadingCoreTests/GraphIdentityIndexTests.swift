import XCTest
@testable import ReadingCore

final class GraphIdentityIndexTests: XCTestCase {
    func testPhysicalSelectionDoesNotJumpBetweenNodesSharingADocument() {
        let index = GraphIdentityIndex(nodes: [("node-a", "doc"), ("node-b", "doc"), ("node-c", "other")])
        XCTAssertEqual(index.selectedNode(targetID: "doc", preferredNodeID: "node-b"), "node-b")
        XCTAssertEqual(index.selectedNode(targetID: "doc", preferredNodeID: "node-c"), "node-a")
        XCTAssertNil(index.selectedNode(targetID: nil, preferredNodeID: "node-b"))
        XCTAssertNil(index.selectedNode(targetID: "removed", preferredNodeID: nil))
        XCTAssertEqual(index.ordinalByNodeID["node-b"], 2)
    }
    func testLargeIndexKeepsStableIDsAndDoesNotCrashOnLegacyDuplicate() {
        var nodes = (0..<10_000).map { (nodeID: "n\($0)", targetID: "d\($0 / 2)") }
        nodes.append(("n0", "different"))
        let index = GraphIdentityIndex(nodes: nodes)
        XCTAssertEqual(index.ordinalByNodeID.count, 10_000)
        XCTAssertEqual(index.ordinalByNodeID["n9999"], 10_000)
        XCTAssertEqual(index.selectedNode(targetID: "d4999", preferredNodeID: "n9999"), "n9999")
        XCTAssertEqual(index.targetByNodeID["n0"], "d0")
    }
}
