import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas Brandes-Köpf assignment")
struct PolicyCanvasBrandesKopfAssignmentTests {
  @Test("buildPositions records layer index and within-layer index for every node")
  func buildPositionsRecordsCoordinates() {
    let layers: [[String]] = [["a", "b"], ["c"], ["d", "e", "f"]]
    let positions = policyCanvasBKBuildPositions(layers: layers)
    #expect(positions["a"] == PolicyCanvasBKPosition(layer: 0, index: 0))
    #expect(positions["b"] == PolicyCanvasBKPosition(layer: 0, index: 1))
    #expect(positions["c"] == PolicyCanvasBKPosition(layer: 1, index: 0))
    #expect(positions["d"] == PolicyCanvasBKPosition(layer: 2, index: 0))
    #expect(positions["e"] == PolicyCanvasBKPosition(layer: 2, index: 1))
    #expect(positions["f"] == PolicyCanvasBKPosition(layer: 2, index: 2))
  }

  @Test("type-1 conflicts flag non-inner edges that cross an inner segment")
  func type1ConflictsFlagInnerCrossings() {
    // Layer 0: [real, d0]   (real index 0, dummy at index 1)
    // Layer 1: [d1, target] (dummy at index 0, target at index 1)
    // Inner segment d0 -> d1 goes from index 1 down to index 0.
    // Non-inner real -> target goes from index 0 down to index 1.
    // The two segments cross because their indices invert across layers.
    let layers: [[String]] = [["real", "d0"], ["d1", "target"]]
    let items: [String: PolicyCanvasLayeredOrderingItem] = [
      "real": PolicyCanvasLayeredOrderingItem(id: "real", realNodeID: "real", rank: 0),
      "d0": PolicyCanvasLayeredOrderingItem(id: "d0", realNodeID: nil, rank: 0),
      "d1": PolicyCanvasLayeredOrderingItem(id: "d1", realNodeID: nil, rank: 1),
      "target": PolicyCanvasLayeredOrderingItem(id: "target", realNodeID: "target", rank: 1),
    ]
    let graph = PolicyCanvasLayeredOrderingGraph(
      itemsByID: items,
      layers: layers,
      incoming: ["d1": ["d0"], "target": ["real"]],
      outgoing: ["d0": ["d1"], "real": ["target"]]
    )
    let positions = policyCanvasBKBuildPositions(layers: layers)
    let conflicts = policyCanvasBKMarkType1Conflicts(
      layers: layers,
      graph: graph,
      positions: positions
    )
    #expect(conflicts.contains(PolicyCanvasBKEdgeKey(source: "real", target: "target")))
  }

  @Test("type-1 conflicts ignore parallel edges that do not cross an inner segment")
  func type1ConflictsIgnoreParallelEdges() {
    // Two parallel non-inner edges with no inner segment present.
    let layers: [[String]] = [["a", "b"], ["c", "d"]]
    let items: [String: PolicyCanvasLayeredOrderingItem] = [
      "a": PolicyCanvasLayeredOrderingItem(id: "a", realNodeID: "a", rank: 0),
      "b": PolicyCanvasLayeredOrderingItem(id: "b", realNodeID: "b", rank: 0),
      "c": PolicyCanvasLayeredOrderingItem(id: "c", realNodeID: "c", rank: 1),
      "d": PolicyCanvasLayeredOrderingItem(id: "d", realNodeID: "d", rank: 1),
    ]
    let graph = PolicyCanvasLayeredOrderingGraph(
      itemsByID: items,
      layers: layers,
      incoming: ["c": ["a"], "d": ["b"]],
      outgoing: ["a": ["c"], "b": ["d"]]
    )
    let positions = policyCanvasBKBuildPositions(layers: layers)
    let conflicts = policyCanvasBKMarkType1Conflicts(
      layers: layers,
      graph: graph,
      positions: positions
    )
    #expect(conflicts.isEmpty)
  }

  @Test("type-1 conflicts never flag an inner segment between two dummies")
  func type1ConflictsSkipBothDummyInnerSegments() {
    // Two long edges a->b and c->d, each spanning three ranks, whose dummy
    // chains cross at the inner (dummy-dummy) segment level: rank 1 is
    // [a1, c1] and rank 2 is [c2, a2], so a1->a2 and c1->c2 invert. Inner
    // segments are the protected segments, never type-1 conflicts, so the
    // dummy-to-dummy edge a1->a2 must not be flagged.
    let layers: [[String]] = [["a", "c"], ["a1", "c1"], ["c2", "a2"], ["b", "d"]]
    let items: [String: PolicyCanvasLayeredOrderingItem] = [
      "a": PolicyCanvasLayeredOrderingItem(id: "a", realNodeID: "a", rank: 0),
      "c": PolicyCanvasLayeredOrderingItem(id: "c", realNodeID: "c", rank: 0),
      "a1": PolicyCanvasLayeredOrderingItem(id: "a1", realNodeID: nil, rank: 1),
      "c1": PolicyCanvasLayeredOrderingItem(id: "c1", realNodeID: nil, rank: 1),
      "c2": PolicyCanvasLayeredOrderingItem(id: "c2", realNodeID: nil, rank: 2),
      "a2": PolicyCanvasLayeredOrderingItem(id: "a2", realNodeID: nil, rank: 2),
      "b": PolicyCanvasLayeredOrderingItem(id: "b", realNodeID: "b", rank: 3),
      "d": PolicyCanvasLayeredOrderingItem(id: "d", realNodeID: "d", rank: 3),
    ]
    let graph = PolicyCanvasLayeredOrderingGraph(
      itemsByID: items,
      layers: layers,
      incoming: [
        "a1": ["a"], "a2": ["a1"], "b": ["a2"],
        "c1": ["c"], "c2": ["c1"], "d": ["c2"],
      ],
      outgoing: [
        "a": ["a1"], "a1": ["a2"], "a2": ["b"],
        "c": ["c1"], "c1": ["c2"], "c2": ["d"],
      ]
    )
    let positions = policyCanvasBKBuildPositions(layers: layers)
    let conflicts = policyCanvasBKMarkType1Conflicts(
      layers: layers,
      graph: graph,
      positions: positions
    )
    #expect(!conflicts.contains(PolicyCanvasBKEdgeKey(source: "a1", target: "a2")))
  }

  @Test("vertical alignment links nodes along a non-conflicting chain")
  func verticalAlignmentLinksAChain() {
    // Two layers, each with two nodes, connected straight: a-c, b-d.
    let layers: [[String]] = [["a", "b"], ["c", "d"]]
    let items: [String: PolicyCanvasLayeredOrderingItem] = [
      "a": PolicyCanvasLayeredOrderingItem(id: "a", realNodeID: "a", rank: 0),
      "b": PolicyCanvasLayeredOrderingItem(id: "b", realNodeID: "b", rank: 0),
      "c": PolicyCanvasLayeredOrderingItem(id: "c", realNodeID: "c", rank: 1),
      "d": PolicyCanvasLayeredOrderingItem(id: "d", realNodeID: "d", rank: 1),
    ]
    let graph = PolicyCanvasLayeredOrderingGraph(
      itemsByID: items,
      layers: layers,
      incoming: ["c": ["a"], "d": ["b"]],
      outgoing: ["a": ["c"], "b": ["d"]]
    )
    let positions = policyCanvasBKBuildPositions(layers: layers)
    let result = policyCanvasBKVerticalAlignment(
      layers: layers,
      graph: graph,
      conflicts: [],
      positions: positions,
      direction: .upLeft
    )
    #expect(result.root["c"] == "a")
    #expect(result.root["d"] == "b")
    #expect(result.align["a"] == "c")
    #expect(result.align["b"] == "d")
  }

  @Test("horizontal compaction maintains rowStep between independent blocks")
  func horizontalCompactionMaintainsRowStep() {
    let layers: [[String]] = [["x", "y"]]
    let items: [String: PolicyCanvasLayeredOrderingItem] = [
      "x": PolicyCanvasLayeredOrderingItem(id: "x", realNodeID: "x", rank: 0),
      "y": PolicyCanvasLayeredOrderingItem(id: "y", realNodeID: "y", rank: 0),
    ]
    let graph = PolicyCanvasLayeredOrderingGraph(
      itemsByID: items,
      layers: layers,
      incoming: [:],
      outgoing: [:]
    )
    let positions = policyCanvasBKBuildPositions(layers: layers)
    let alignment = policyCanvasBKVerticalAlignment(
      layers: layers,
      graph: graph,
      conflicts: [],
      positions: positions,
      direction: .upLeft
    )
    let coords = policyCanvasBKHorizontalCompaction(
      layers: layers,
      positions: positions,
      alignment: alignment,
      direction: .upLeft,
      rowStep: 100
    )
    let dx = (coords["y"] ?? 0) - (coords["x"] ?? 0)
    #expect(dx == 100)
  }

  @Test("align coordinates shifts every layout onto the narrowest layout's frame")
  func alignCoordinatesUsesNarrowestLayoutAsReference() {
    // Brandes & Köpf computes each of the four candidate layouts in its own
    // frame, so they must be width-aligned before balancing. A is the narrowest
    // (span 90) and anchors the frame: left-biased layouts (upLeft/downLeft)
    // line up by their minimum, right-biased layouts (upRight/downRight) by
    // their maximum.
    let assignments: [[String: CGFloat]] = [
      ["x": 0, "y": 90],  // upLeft - reference, span 90
      ["x": 0, "y": 100],  // downLeft - span 100
      ["x": -100, "y": 0],  // upRight - span 100
      ["x": -110, "y": 0],  // downRight - span 110
    ]
    let directions: [PolicyCanvasBKDirection] = [.upLeft, .downLeft, .upRight, .downRight]
    let aligned = policyCanvasBKAlignCoordinates(
      assignments: assignments,
      directions: directions
    )
    #expect(aligned[0] == ["x": 0, "y": 90])
    #expect(aligned[1] == ["x": 0, "y": 100])
    #expect(aligned[2] == ["x": -10, "y": 90])
    #expect(aligned[3] == ["x": -20, "y": 90])
  }

  @Test("balance reports median of four direction assignments per node")
  func balanceTakesMedianOfFourDirections() {
    let assignments: [[String: CGFloat]] = [
      ["v": 100],
      ["v": 200],
      ["v": 300],
      ["v": 400],
    ]
    let result = policyCanvasBKBalance(assignments: assignments, allNodeIDs: ["v"])
    #expect(result["v"] == 250)
  }

  @Test("end-to-end aligns a straight chain through dummy nodes")
  func endToEndAlignsStraightChain() {
    let layers: [[String]] = [["a"], ["d"], ["b"]]
    let items: [String: PolicyCanvasLayeredOrderingItem] = [
      "a": PolicyCanvasLayeredOrderingItem(id: "a", realNodeID: "a", rank: 0),
      "d": PolicyCanvasLayeredOrderingItem(id: "d", realNodeID: nil, rank: 1),
      "b": PolicyCanvasLayeredOrderingItem(id: "b", realNodeID: "b", rank: 2),
    ]
    let graph = PolicyCanvasLayeredOrderingGraph(
      itemsByID: items,
      layers: layers,
      incoming: ["d": ["a"], "b": ["d"]],
      outgoing: ["a": ["d"], "d": ["b"]]
    )
    let coords = policyCanvasBrandesKopfYAssignment(
      layers: layers,
      graph: graph,
      rowStep: 100
    )
    #expect(coords["a"] == coords["d"])
    #expect(coords["d"] == coords["b"])
  }
}
