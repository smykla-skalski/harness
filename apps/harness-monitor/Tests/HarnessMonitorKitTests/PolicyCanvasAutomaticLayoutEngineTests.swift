import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas automatic layout engine")
struct PolicyCanvasAutomaticLayoutEngineTests {
  @Test("layered engine reduces crossings on a two-rank graph")
  func layeredEngineReducesCrossings() {
    let graph = crossingReductionGraph()
    let naiveMetrics = policyCanvasMeasureLayoutMetrics(
      graph: graph,
      nodePositions: [
        "a": CGPoint(x: 72, y: 72),
        "b": CGPoint(x: 72, y: 332),
        "c": CGPoint(x: 532, y: 72),
        "d": CGPoint(x: 532, y: 332),
      ],
      groupRanks: [
        "a": 0,
        "b": 0,
        "c": 1,
        "d": 1,
      ],
      layoutGroupIDByNodeID: [
        "a": "a",
        "b": "b",
        "c": "c",
        "d": "d",
      ]
    )
    let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: graph)

    #expect(naiveMetrics.edgeCrossingCount == 1)
    guard let result else {
      Issue.record("Expected a layout result for the crossing-reduction graph")
      return
    }
    #expect(result.metrics.edgeCrossingCount == 0)
    #expect(result.metrics.flowDirectionViolationCount == 0)
    #expect(result.metrics.readabilityScore > naiveMetrics.readabilityScore)
  }

  @Test("metrics capture backward flow violations")
  func metricsCaptureBackwardFlowViolations() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "left",
          groupID: nil,
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "right",
          groupID: nil,
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "back-edge", sourceNodeID: "left", targetNodeID: "right")
      ],
      groups: []
    )
    let metrics = policyCanvasMeasureLayoutMetrics(
      graph: graph,
      nodePositions: [
        "left": CGPoint(x: 420, y: 72),
        "right": CGPoint(x: 72, y: 72),
      ],
      groupRanks: [
        "left": 0,
        "right": 1,
      ],
      layoutGroupIDByNodeID: [
        "left": "left",
        "right": "right",
      ]
    )

    #expect(metrics.flowDirectionViolationCount == 1)
    #expect(metrics.readabilityScore < 1_000)
  }

  @Test("feedback edges are reversed before layered ranking")
  func feedbackEdgesAreReversedBeforeLayeredRanking() {
    let edges = [
      PolicyCanvasLayoutEdge(id: "a-b", sourceNodeID: "a", targetNodeID: "b"),
      PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      PolicyCanvasLayoutEdge(id: "c-a", sourceNodeID: "c", targetNodeID: "a"),
    ]
    let acyclicEdges = policyCanvasAcyclicEdges(
      ids: ["a", "b", "c"],
      originalOrder: ["a": 0, "b": 1, "c": 2],
      edges: edges
    )

    #expect(
      acyclicEdges.contains { edge in
        edge.id == "c-a" && edge.sourceNodeID == "a" && edge.targetNodeID == "c"
      }
    )

    let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: cycleGraph())
    guard let result else {
      Issue.record("Expected layout result for the cycle graph")
      return
    }
    #expect(Set(result.nodePositions.values.map(\.x)).count >= 2)
  }

  @Test("augmented layered graph inserts dummy nodes for long-span edges")
  func augmentedLayeredGraphInsertsDummyNodesForLongSpanEdges() {
    let orderingGraph = policyCanvasAugmentedLayeredOrderingGraph(
      nodeIDs: ["source", "target"],
      ranks: ["source": 0, "target": 3],
      edges: [
        PolicyCanvasLayoutEdge(id: "source-target", sourceNodeID: "source", targetNodeID: "target")
      ],
      initialOrders: ["source": 0, "target": 0]
    )

    let dummyItems = orderingGraph.itemsByID.values.filter(\.isDummy)
    #expect(dummyItems.count == 2)
    #expect(Set(dummyItems.map(\.rank)) == [1, 2])
    #expect(orderingGraph.outgoing["source"]?.count == 1)
    guard let firstDummy = orderingGraph.outgoing["source"]?.first else {
      Issue.record("Expected the source to connect to the first dummy node")
      return
    }
    #expect(orderingGraph.itemsByID[firstDummy]?.rank == 1)
    #expect(orderingGraph.outgoing[firstDummy]?.count == 1)
  }

  @Test("layered ordering reduces crossings on the augmented layer graph")
  func layeredOrderingReducesCrossingsOnTheAugmentedLayerGraph() {
    let orderingGraph = policyCanvasAugmentedLayeredOrderingGraph(
      nodeIDs: ["a", "b", "c", "d"],
      ranks: ["a": 0, "b": 0, "c": 1, "d": 1],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-d", sourceNodeID: "a", targetNodeID: "d"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      ],
      initialOrders: ["a": 0, "b": 1, "c": 0, "d": 1]
    )
    let reducedLayers = policyCanvasReducedLayerOrders(graph: orderingGraph, maxPasses: 12)

    #expect(bilayerCrossingCount(orderingGraph.layers, graph: orderingGraph) == 1)
    #expect(bilayerCrossingCount(reducedLayers, graph: orderingGraph) == 0)
  }

  @Test("layered engine keeps same-rank nodes on one x column")
  func layeredEngineKeepsSameRankNodesOnOneXColumn() {
    let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: fanoutGraph())
    guard let result else {
      Issue.record("Expected layout result for the fanout graph")
      return
    }

    let sinkX = Set(["sink-a", "sink-b", "sink-c", "sink-d"].compactMap { result.nodePositions[$0]?.x })
    #expect(sinkX.count == 1)
  }

  @Test("layered engine centers a single source against a taller sink layer")
  func layeredEngineCentersSingleSourceAgainstTallerSinkLayer() {
    let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: fanoutGraph())
    guard
      let result,
      let source = result.nodePositions["source"]
    else {
      Issue.record("Expected layout result for centered source graph")
      return
    }

    let sinkY = ["sink-a", "sink-b", "sink-c", "sink-d"].compactMap { result.nodePositions[$0]?.y }
    guard let minSinkY = sinkY.min(), let maxSinkY = sinkY.max() else {
      Issue.record("Expected sink positions for centered source graph")
      return
    }
    #expect(source.y > minSinkY)
    #expect(source.y < maxSinkY)
  }

  @Test("dense layer ordering stays under the interaction budget")
  func denseLayerOrderingPerformance() {
    let graph = denseOrderingGraph(layerCount: 5, layerWidth: 60)
    let start = Date()

    _ = policyCanvasReducedLayerOrders(graph: graph, maxPasses: 12)

    let elapsed = Date().timeIntervalSince(start)
    #expect(
      elapsed < 0.2,
      "Dense layer ordering took \(elapsed * 1000)ms, expected <200ms"
    )
  }

  private func crossingReductionGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "a",
          groupID: "main",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "b",
          groupID: "main",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "c",
          groupID: "main",
          originalIndex: 2,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "d",
          groupID: "main",
          originalIndex: 3,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-d", sourceNodeID: "a", targetNodeID: "d"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "main",
          originalIndex: 0,
          memberNodeIDs: ["a", "b", "c", "d"]
        )
      ]
    )
  }

  private func cycleGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(id: "a", groupID: "cycle", originalIndex: 0, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(id: "b", groupID: "cycle", originalIndex: 1, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(id: "c", groupID: "cycle", originalIndex: 2, currentPosition: .zero, anchor: nil),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-b", sourceNodeID: "a", targetNodeID: "b"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
        PolicyCanvasLayoutEdge(id: "c-a", sourceNodeID: "c", targetNodeID: "a"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(id: "cycle", originalIndex: 0, memberNodeIDs: ["a", "b", "c"])
      ]
    )
  }

  private func fanoutGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(id: "source", groupID: "entry", originalIndex: 0, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(id: "sink-a", groupID: "terminal", originalIndex: 1, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(id: "sink-b", groupID: "terminal", originalIndex: 2, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(id: "sink-c", groupID: "terminal", originalIndex: 3, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(id: "sink-d", groupID: "terminal", originalIndex: 4, currentPosition: .zero, anchor: nil),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "source-a", sourceNodeID: "source", targetNodeID: "sink-a"),
        PolicyCanvasLayoutEdge(id: "source-b", sourceNodeID: "source", targetNodeID: "sink-b"),
        PolicyCanvasLayoutEdge(id: "source-c", sourceNodeID: "source", targetNodeID: "sink-c"),
        PolicyCanvasLayoutEdge(id: "source-d", sourceNodeID: "source", targetNodeID: "sink-d"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(id: "entry", originalIndex: 0, memberNodeIDs: ["source"]),
        PolicyCanvasLayoutGroup(
          id: "terminal",
          originalIndex: 1,
          memberNodeIDs: ["sink-a", "sink-b", "sink-c", "sink-d"]
        ),
      ]
    )
  }

  private func denseOrderingGraph(
    layerCount: Int,
    layerWidth: Int
  ) -> PolicyCanvasLayeredOrderingGraph {
    let layers = (0..<layerCount).map { rank in
      (0..<layerWidth).map { index in
        "layer-\(rank)-item-\(index)"
      }
    }
    let itemsByID = Dictionary(
      uniqueKeysWithValues: layers.enumerated().flatMap { rank, layer in
        layer.map { itemID in
          (
            itemID,
            PolicyCanvasLayeredOrderingItem(
              id: itemID,
              realNodeID: itemID,
              rank: rank
            )
          )
        }
      }
    )
    var incoming: [String: [String]] = [:]
    var outgoing: [String: [String]] = [:]

    for rank in 0..<(layerCount - 1) {
      for sourceID in layers[rank] {
        for targetID in layers[rank + 1] {
          outgoing[sourceID, default: []].append(targetID)
          incoming[targetID, default: []].append(sourceID)
        }
      }
    }

    return PolicyCanvasLayeredOrderingGraph(
      itemsByID: itemsByID,
      layers: layers,
      incoming: incoming,
      outgoing: outgoing
    )
  }

  private func bilayerCrossingCount(
    _ layers: [[String]],
    graph: PolicyCanvasLayeredOrderingGraph
  ) -> Int {
    guard layers.count >= 2 else {
      return 0
    }
    let upperOrder = Dictionary(uniqueKeysWithValues: layers[0].enumerated().map { ($1, $0) })
    let lowerOrder = Dictionary(uniqueKeysWithValues: layers[1].enumerated().map { ($1, $0) })
    let edgePairs = layers[0].flatMap { sourceID -> [(Int, Int)] in
      (graph.outgoing[sourceID] ?? []).compactMap { targetID in
        guard let upperIndex = upperOrder[sourceID], let lowerIndex = lowerOrder[targetID] else {
          return nil
        }
        return (upperIndex, lowerIndex)
      }
    }
    var crossings = 0
    for leftIndex in edgePairs.indices {
      for rightIndex in edgePairs.index(after: leftIndex)..<edgePairs.endIndex {
        let left = edgePairs[leftIndex]
        let right = edgePairs[rightIndex]
        if (left.0 < right.0 && left.1 > right.1) || (left.0 > right.0 && left.1 < right.1) {
          crossings += 1
        }
      }
    }
    return crossings
  }
}
