import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

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

  @Test("layered engine packs dense same-rank sinks across multiple x columns")
  func layeredEnginePacksDenseSameRankSinksAcrossMultipleColumns() {
    let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: fanoutGraph())
    guard let result else {
      Issue.record("Expected layout result for the fanout graph")
      return
    }

    let sinkX = Set(
      ["sink-a", "sink-b", "sink-c", "sink-d"].compactMap { result.nodePositions[$0]?.x })
    #expect(sinkX.count >= 2)
  }

  @Test("layered engine emits corridor hints for inter-group routes")
  func layeredEngineEmitsCorridorHintsForInterGroupRoutes() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "source",
          groupID: "left",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "target",
          groupID: "right",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "source-target", sourceNodeID: "source", targetNodeID: "target")
      ],
      groups: [
        PolicyCanvasLayoutGroup(id: "left", originalIndex: 0, memberNodeIDs: ["source"]),
        PolicyCanvasLayoutGroup(id: "right", originalIndex: 1, memberNodeIDs: ["target"]),
      ]
    )

    guard let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: graph)
    else {
      Issue.record("Expected layout result for corridor hint graph")
      return
    }
    guard
      let routingHints = result.routingHints,
      let hint = routingHints.edgeHint(for: "source-target"),
      let leftFrame = result.groupFrames["left"],
      let rightFrame = result.groupFrames["right"],
      let verticalLaneX = hint.verticalLaneX
    else {
      Issue.record("Expected inter-group corridor hint for source-target")
      return
    }

    #expect(hint.key.sourceScopeID == "left")
    #expect(hint.key.targetScopeID == "right")
    #expect(verticalLaneX > leftFrame.maxX)
    #expect(verticalLaneX < rightFrame.minX)
    #expect(hint.horizontalLaneY >= rightFrame.minY)
    #expect(hint.horizontalLaneY <= rightFrame.maxY)
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

  @Test("layered engine keeps multi-group outcome collectors stable across repeated runs")
  func layeredEngineKeepsMultiGroupOutcomeCollectorsStableAcrossRepeatedRuns() {
    let graph = multiGroupCollectorGraph()
    let engine = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad)
    let collectorPairs = (0..<12).compactMap { _ -> String? in
      guard
        let result = engine.layout(graph: graph),
        let human = result.nodePositions["out-human"],
        let deny = result.nodePositions["out-deny"]
      else {
        return nil
      }
      return "human=\(human) deny=\(deny)"
    }

    #expect(collectorPairs.count == 12)
    #expect(
      Set(collectorPairs).count == 1,
      "collector placement changed across repeated identical layout runs: \(Set(collectorPairs))"
    )
  }

}
