import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas initial order edge-aware seed")
struct PolicyCanvasInitialOrderSeedTests {
  @Test("edge-aware seed returns the median Y of successor positions")
  func medianOfSuccessorYs() {
    let nodes = nodesByID([
      ("action", 1000),
      ("term-a", 100),
      ("term-b", 300),
      ("term-c", 500),
    ])
    let edges = [
      PolicyCanvasLayoutEdge(id: "e1", sourceNodeID: "action", targetNodeID: "term-a"),
      PolicyCanvasLayoutEdge(id: "e2", sourceNodeID: "action", targetNodeID: "term-b"),
      PolicyCanvasLayoutEdge(id: "e3", sourceNodeID: "action", targetNodeID: "term-c"),
    ]
    let seed = policyCanvasEdgeAwareSeedY(for: "action", nodesByID: nodes, edges: edges)
    #expect(seed == 300)
  }

  @Test("edge-aware seed averages middle two for an even neighbor count")
  func averageOfTwoMiddleNeighbors() {
    let nodes = nodesByID([
      ("merge", 0),
      ("p1", 100),
      ("p2", 200),
      ("p3", 300),
      ("p4", 400),
    ])
    let edges = [
      PolicyCanvasLayoutEdge(id: "e1", sourceNodeID: "p1", targetNodeID: "merge"),
      PolicyCanvasLayoutEdge(id: "e2", sourceNodeID: "p2", targetNodeID: "merge"),
      PolicyCanvasLayoutEdge(id: "e3", sourceNodeID: "p3", targetNodeID: "merge"),
      PolicyCanvasLayoutEdge(id: "e4", sourceNodeID: "p4", targetNodeID: "merge"),
    ]
    let seed = policyCanvasEdgeAwareSeedY(for: "merge", nodesByID: nodes, edges: edges)
    #expect(seed == 250)
  }

  @Test("edge-aware seed treats predecessors and successors symmetrically")
  func combinesPredecessorsAndSuccessors() {
    let nodes = nodesByID([
      ("middle", 0),
      ("pred", 100),
      ("succ", 500),
    ])
    let edges = [
      PolicyCanvasLayoutEdge(id: "e1", sourceNodeID: "pred", targetNodeID: "middle"),
      PolicyCanvasLayoutEdge(id: "e2", sourceNodeID: "middle", targetNodeID: "succ"),
    ]
    let seed = policyCanvasEdgeAwareSeedY(for: "middle", nodesByID: nodes, edges: edges)
    #expect(seed == 300)
  }

  @Test("edge-aware seed returns nil when a node has no graph neighbors")
  func nilForOrphan() {
    let nodes = nodesByID([("solo", 200)])
    let seed = policyCanvasEdgeAwareSeedY(for: "solo", nodesByID: nodes, edges: [])
    #expect(seed == nil)
  }

  private func nodesByID(_ specs: [(String, CGFloat)]) -> [String: PolicyCanvasLayoutNode] {
    var result: [String: PolicyCanvasLayoutNode] = [:]
    for (index, (id, y)) in specs.enumerated() {
      result[id] = PolicyCanvasLayoutNode(
        id: id,
        groupID: nil,
        originalIndex: index,
        currentPosition: CGPoint(x: 0, y: y),
        anchor: nil
      )
    }
    return result
  }
}
