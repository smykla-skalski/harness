import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas crossing reduction monotonic improvement")
struct PolicyCanvasCrossingMonotonicTests {
  @Test("reducedLayerOrders never returns a worse layout than its input")
  func reducedLayerOrdersNeverWorsens() {
    let graph = policyCanvasAugmentedLayeredOrderingGraph(
      nodeIDs: ["a", "b", "c", "d"],
      ranks: ["a": 0, "b": 0, "c": 1, "d": 1],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-d", sourceNodeID: "a", targetNodeID: "d"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      ],
      initialOrders: ["a": 0, "b": 1, "c": 0, "d": 1]
    )
    let initialCrossings = policyCanvasLayeredOrderingCrossingCount(
      graph: graph,
      layers: graph.layers
    )
    let result = policyCanvasReducedLayerOrders(graph: graph, maxPasses: 12)
    let finalCrossings = policyCanvasLayeredOrderingCrossingCount(
      graph: graph,
      layers: result
    )
    #expect(finalCrossings <= initialCrossings)
  }

  @Test("reducedLayerOrders eliminates a resolvable single crossing")
  func reducedLayerOrdersResolvesSingleCrossing() {
    let graph = policyCanvasAugmentedLayeredOrderingGraph(
      nodeIDs: ["a", "b", "c", "d"],
      ranks: ["a": 0, "b": 0, "c": 1, "d": 1],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-d", sourceNodeID: "a", targetNodeID: "d"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      ],
      initialOrders: ["a": 0, "b": 1, "c": 0, "d": 1]
    )
    let result = policyCanvasReducedLayerOrders(graph: graph, maxPasses: 12)
    let finalCrossings = policyCanvasLayeredOrderingCrossingCount(
      graph: graph,
      layers: result
    )
    #expect(finalCrossings == 0)
  }

  @Test("crossingCount sees an unresolvable layout's crossings")
  func crossingCountObservesCrossings() {
    let graph = policyCanvasAugmentedLayeredOrderingGraph(
      nodeIDs: ["a", "b", "c", "d"],
      ranks: ["a": 0, "b": 0, "c": 1, "d": 1],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-d", sourceNodeID: "a", targetNodeID: "d"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      ],
      initialOrders: ["a": 0, "b": 1, "c": 0, "d": 1]
    )
    let crossings = policyCanvasLayeredOrderingCrossingCount(
      graph: graph,
      layers: [["a", "b"], ["c", "d"]]
    )
    #expect(crossings == 1)
  }
}
