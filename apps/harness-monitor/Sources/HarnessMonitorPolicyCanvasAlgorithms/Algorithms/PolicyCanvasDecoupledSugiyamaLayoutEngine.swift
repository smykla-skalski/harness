import CoreGraphics
import Foundation

struct PolicyCanvasDecoupledSugiyamaLayoutEngine: PolicyCanvasLayoutEngine {
  let mode: PolicyCanvasAutomaticLayoutMode
  let selection: PolicyCanvasAlgorithmSelection

  init(
    mode: PolicyCanvasAutomaticLayoutMode = .initialLoad,
    selection: PolicyCanvasAlgorithmSelection
  ) {
    self.mode = mode
    self.selection = selection
  }

  func layout(
    graph: PolicyCanvasLayoutGraph,
    configuration: PolicyCanvasLayoutConfiguration = .layeredDefault
  ) -> PolicyCanvasLayoutResult? {
    guard !graph.nodes.isEmpty else {
      return nil
    }
    let algorithms = PolicyCanvasLayoutAlgorithmRegistry.layoutAlgorithms(for: selection)
    let nodeIDs = graph.nodes.map(\.id)
    let originalOrder = originalOrder(for: graph)
    let acyclicEdges = algorithms.cycleBreaking.breakCycles(
      input: PolicyCanvasCycleBreakingInput(
        nodeIDs: nodeIDs,
        originalOrder: originalOrder,
        edges: graph.edges
      )
    )
    let rankAssignment = algorithms.rankAssignment.assignRanks(
      input: PolicyCanvasRankAssignmentInput(
        graph: graph,
        nodeIDs: nodeIDs,
        originalOrder: originalOrder,
        edges: acyclicEdges,
        mode: mode
      )
    )
    let resolvedConfiguration = configuration.pressureAdjusted(
      graph: graph,
      rankAssignment: rankAssignment
    )
    let orderingGraph = algorithms.longEdgeNormalization.normalize(
      input: PolicyCanvasLongEdgeNormalizationInput(
        nodeIDs: nodeIDs,
        ranks: rankAssignment.nodeRanks,
        edges: acyclicEdges,
        initialOrders: rankAssignment.initialOrders
      )
    )
    let orderedLayers = algorithms.layerOrdering.orderLayers(
      input: PolicyCanvasLayerOrderingInput(
        graph: orderingGraph,
        maxPasses: resolvedConfiguration.sweepPassCount
      )
    )
    let coordinates = algorithms.coordinateAssignment.assignCoordinates(
      input: PolicyCanvasCoordinateAssignmentInput(
        layers: orderedLayers,
        graph: orderingGraph,
        configuration: resolvedConfiguration
      )
    )
    let fallbackNodePositions = positionedNodes(
      graph: graph,
      ranks: rankAssignment.nodeRanks,
      itemCenterY: coordinates.itemCenterY,
      configuration: resolvedConfiguration
    )
    let orderHints = policyCanvasLayerOrderHints(layers: orderedLayers, graph: orderingGraph)
    let groupOutput = algorithms.groupPlacement.placeGroups(
      input: PolicyCanvasGroupPlacementInput(
        graph: graph,
        mode: mode,
        rankAssignment: rankAssignment,
        itemCenterY: coordinates.itemCenterY,
        orderHints: orderHints,
        fallbackNodePositions: fallbackNodePositions,
        configuration: resolvedConfiguration
      )
    )
    let processedLayout = processedLayout(
      graph: graph,
      rankAssignment: rankAssignment,
      groupOutput: groupOutput,
      algorithm: algorithms.layoutPostProcessing
    )
    let metrics = algorithms.metrics.measure(
      input: PolicyCanvasMetricsInput(
        graph: graph,
        nodePositions: processedLayout.nodePositions,
        ranks: rankAssignment.scopeRanks,
        layoutGroupIDByNodeID: rankAssignment.layoutGroupIDByNodeID
      )
    )
    let routingHints = policyCanvasLayoutRoutingHints(
      graph: graph,
      nodePositions: processedLayout.nodePositions,
      layoutGroupIDByNodeID: rankAssignment.layoutGroupIDByNodeID,
      groupFramesByLayoutID: processedLayout.groupFramesByLayoutID
    )
    return PolicyCanvasLayoutResult(
      nodePositions: processedLayout.nodePositions,
      groupFrames: processedLayout.groupFrames,
      autoPlacedNodeIDs: groupOutput.autoPlacedNodeIDs,
      metrics: metrics,
      routingHints: routingHints,
      precomputedRoutes: nil
    )
  }

  private func positionedNodes(
    graph: PolicyCanvasLayoutGraph,
    ranks: [String: Int],
    itemCenterY: [String: CGFloat],
    configuration: PolicyCanvasLayoutConfiguration
  ) -> [String: CGPoint] {
    var positions: [String: CGPoint] = graph.nodes.reduce(into: [:]) { partial, node in
      if mode.preservesManualAnchors, let anchor = node.anchor {
        partial[node.id] = anchor.position
        return
      }
      let rank = ranks[node.id] ?? 0
      let centerY = itemCenterY[node.id] ?? 0
      partial[node.id] = snappedLayoutPoint(
        CGPoint(
          x: PolicyCanvasLayout.initialContentOrigin.x + CGFloat(rank) * configuration.columnStep,
          y: PolicyCanvasLayout.initialContentOrigin.y + centerY
            - (PolicyCanvasLayout.nodeSize.height / 2)
        )
      )
    }
    let minY = positions.values.map(\.y).min() ?? PolicyCanvasLayout.initialContentOrigin.y
    if minY < PolicyCanvasLayout.initialContentOrigin.y {
      let shift = PolicyCanvasLayout.initialContentOrigin.y - minY
      positions = positions.mapValues { point in
        snappedLayoutPoint(CGPoint(x: point.x, y: point.y + shift))
      }
    }
    return positions
  }

  private func originalOrder(for graph: PolicyCanvasLayoutGraph) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.originalIndex) })
  }

  private func processedLayout(
    graph: PolicyCanvasLayoutGraph,
    rankAssignment: PolicyCanvasRankAssignmentOutput,
    groupOutput: PolicyCanvasGroupPlacementOutput,
    algorithm: any PolicyCanvasLayoutPostProcessingAlgorithm
  ) -> PolicyCanvasLayoutPostProcessingOutput {
    algorithm.processLayout(
      input: PolicyCanvasLayoutPostProcessingInput(
        graph: graph,
        rankAssignment: rankAssignment,
        nodePositions: groupOutput.nodePositions,
        groupFrames: groupOutput.groupFrames,
        groupFramesByLayoutID: groupOutput.groupFramesByLayoutID
      )
    )
  }

}
