import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas two-sided layer transpose")
struct PolicyCanvasLayerTransposeTests {
  // Build a graph whose middle layer ordering trades off the upper and lower
  // neighbour layers against each other. The shared helper lets each test pin
  // exactly how many crossings each candidate order produces on each side.
  private func transposeGraph(
    upper: [String],
    middle: [String],
    lower: [String],
    edges: [(String, String)]
  ) -> PolicyCanvasLayeredOrderingGraph {
    var itemsByID: [String: PolicyCanvasLayeredOrderingItem] = [:]
    for id in upper {
      itemsByID[id] = PolicyCanvasLayeredOrderingItem(id: id, realNodeID: id, rank: 0)
    }
    for id in middle {
      itemsByID[id] = PolicyCanvasLayeredOrderingItem(id: id, realNodeID: id, rank: 1)
    }
    for id in lower {
      itemsByID[id] = PolicyCanvasLayeredOrderingItem(id: id, realNodeID: id, rank: 2)
    }
    var incoming: [String: [String]] = [:]
    var outgoing: [String: [String]] = [:]
    for (source, target) in edges {
      outgoing[source, default: []].append(target)
      incoming[target, default: []].append(source)
    }
    return PolicyCanvasLayeredOrderingGraph(
      itemsByID: itemsByID,
      layers: [upper, middle, lower],
      incoming: incoming,
      outgoing: outgoing
    )
  }

  @Test("rejects an upper-only improvement that worsens the joint crossing total")
  func rejectsUpperOnlyImprovementThatWorsensTotal() {
    // Upper edges (u0->m1, u1->m0) make [m0,m1] cross once on top, so a swap to
    // [m1,m0] removes one upper crossing. Lower edges hang m1 over l1/l2/l3 and
    // m0 over l0, so the same swap drags m0->l0 across all three m1 segments:
    // +3 lower crossings. Net of the swap is +2. A one-sided (upper) transpose
    // takes the swap and lands on the globally worse order; the two-sided
    // transpose must keep [m0,m1].
    let graph = transposeGraph(
      upper: ["u0", "u1"],
      middle: ["m0", "m1"],
      lower: ["l0", "l1", "l2", "l3"],
      edges: [
        ("u0", "m1"), ("u1", "m0"),
        ("m0", "l0"), ("m1", "l1"), ("m1", "l2"), ("m1", "l3"),
      ]
    )
    var middle = ["m0", "m1"]
    policyCanvasTransposeLayer(
      movingLayer: &middle,
      upperLayer: ["u0", "u1"],
      lowerLayer: ["l0", "l1", "l2", "l3"],
      graph: graph
    )
    #expect(middle == ["m0", "m1"])
  }

  @Test("still swaps when both neighbour layers favour the swap")
  func acceptsJointImprovement() {
    // Both sides cross in [m0,m1]: u0->m1/u1->m0 on top, m0->l1/m1->l0 on the
    // bottom. The swap removes a crossing on each side, so two-sided transpose
    // must reorder to [m1,m0].
    let graph = transposeGraph(
      upper: ["u0", "u1"],
      middle: ["m0", "m1"],
      lower: ["l0", "l1"],
      edges: [
        ("u0", "m1"), ("u1", "m0"),
        ("m0", "l1"), ("m1", "l0"),
      ]
    )
    var middle = ["m0", "m1"]
    policyCanvasTransposeLayer(
      movingLayer: &middle,
      upperLayer: ["u0", "u1"],
      lowerLayer: ["l0", "l1"],
      graph: graph
    )
    #expect(middle == ["m1", "m0"])
  }
}
