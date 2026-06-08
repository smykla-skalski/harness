import CoreGraphics
import Foundation

struct PolicyCanvasGreedyFeedbackArcReversal: PolicyCanvasCycleBreakingAlgorithm {
  func breakCycles(input: PolicyCanvasCycleBreakingInput) -> [PolicyCanvasLayoutEdge] {
    let order = policyCanvasGreedyFeedbackArcOrder(
      nodeIDs: input.nodeIDs,
      originalOrder: input.originalOrder,
      edges: input.edges
    )
    return policyCanvasEdgesOrientedByOrder(input.edges, order: order)
  }
}

struct PolicyCanvasLongestPathLayering: PolicyCanvasRankAssignmentAlgorithm {
  func assignRanks(input: PolicyCanvasRankAssignmentInput) -> PolicyCanvasRankAssignmentOutput {
    let nodeRanks = longestPathRanks(
      ids: input.nodeIDs,
      originalOrder: input.originalOrder,
      successors: input.edges.reduce(into: [:]) { successors, edge in
        successors[edge.sourceNodeID, default: []].insert(edge.targetNodeID)
      }
    )
    let normalizedGroups = PolicyCanvasLayeredLayoutEngine(mode: input.mode)
      .normalizedGroups(for: input.graph)
    let layoutGroupIDByNodeID = policyCanvasLayoutGroupIDsByNodeID(
      graph: input.graph,
      normalizedGroups: normalizedGroups
    )
    let scopeRanks = policyCanvasScopeRanks(
      nodeRanks: nodeRanks,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    return PolicyCanvasRankAssignmentOutput(
      nodeRanks: nodeRanks,
      scopeRanks: scopeRanks,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      normalizedGroups: normalizedGroups,
      internalRanks: nodeRanks,
      initialOrders: Dictionary(
        uniqueKeysWithValues: input.graph.nodes.map { node in
          (node.id, Double(node.originalIndex))
        }
      ),
      acyclicEdges: input.edges
    )
  }
}

struct PolicyCanvasUnitDummyChainNormalization: PolicyCanvasLongEdgeNormalizationAlgorithm {
  func normalize(input: PolicyCanvasLongEdgeNormalizationInput)
    -> PolicyCanvasLayeredOrderingGraph
  {
    policyCanvasPureUnitLayeredOrderingGraph(
      nodeIDs: input.nodeIDs,
      ranks: input.ranks,
      edges: input.edges,
      initialOrders: input.initialOrders
    )
  }
}

struct PolicyCanvasBarycenterCrossingReduction: PolicyCanvasLayerOrderingAlgorithm {
  func orderLayers(input: PolicyCanvasLayerOrderingInput) -> [[String]] {
    policyCanvasPureBarycenterLayerOrders(
      graph: input.graph,
      maxPasses: input.maxPasses
    )
  }
}

struct PolicyCanvasBarycenterTransposeCrossingReduction:
  PolicyCanvasLayerOrderingAlgorithm
{
  func orderLayers(input: PolicyCanvasLayerOrderingInput) -> [[String]] {
    policyCanvasReducedLayerOrders(graph: input.graph, maxPasses: input.maxPasses)
  }
}

struct PolicyCanvasLayeredGridCoordinateAssignment: PolicyCanvasCoordinateAssignmentAlgorithm {
  func assignCoordinates(
    input: PolicyCanvasCoordinateAssignmentInput
  ) -> PolicyCanvasCoordinateAssignmentOutput {
    var centers: [String: CGFloat] = [:]
    for layer in input.layers {
      let initialCenters = centeredLayerCenters(
        count: layer.count,
        rowStep: input.configuration.rowStep
      )
      for (itemID, centerY) in zip(layer, initialCenters) {
        centers[itemID] = centerY
      }
    }
    return PolicyCanvasCoordinateAssignmentOutput(itemCenterY: centers)
  }

  private func centeredLayerCenters(count: Int, rowStep: CGFloat) -> [CGFloat] {
    guard count > 0 else {
      return []
    }
    let totalHeight = CGFloat(max(0, count - 1)) * rowStep
    return (0..<count).map { index in
      (CGFloat(index) * rowStep) - (totalHeight / 2)
    }
  }
}

struct PolicyCanvasLayeredClusterFramePacking: PolicyCanvasGroupPlacementAlgorithm {
  func placeGroups(input: PolicyCanvasGroupPlacementInput) -> PolicyCanvasGroupPlacementOutput {
    let engine = PolicyCanvasLayeredLayoutEngine(mode: input.mode)
    let groupOrder = engine.orderedGroups(
      normalizedGroups: input.rankAssignment.normalizedGroups,
      groupRanks: input.rankAssignment.scopeRanks,
      anchoredMinXByGroup: [:],
      groupCenterY: engine.groupBarycenterY(
        normalizedGroups: input.rankAssignment.normalizedGroups,
        layoutGroupIDByNodeID: input.rankAssignment.layoutGroupIDByNodeID,
        edges: input.rankAssignment.acyclicEdges,
        itemCenterY: input.itemCenterY
      )
    )
    var accumulator = PolicyCanvasUnconstrainedPlacement()
    for group in groupOrder {
      placeCluster(
        group: group,
        input: input,
        accumulator: &accumulator
      )
    }
    return PolicyCanvasGroupPlacementOutput(
      nodePositions: accumulator.nodePositions,
      groupFrames: accumulator.groupFrames,
      groupFramesByLayoutID: accumulator.groupFramesByLayoutID,
      autoPlacedNodeIDs: accumulator.autoPlacedNodeIDs
    )
  }

  private func placeCluster(
    group: PolicyCanvasNormalizedLayoutGroup,
    input: PolicyCanvasGroupPlacementInput,
    accumulator: inout PolicyCanvasUnconstrainedPlacement
  ) {
    let memberIDs = group.nodeIDs.filter {
      input.rankAssignment.layoutGroupIDByNodeID[$0] == group.layoutID
    }
    guard !memberIDs.isEmpty else {
      return
    }

    let groupRankOffset =
      memberIDs
      .compactMap { input.rankAssignment.internalRanks[$0] }
      .min() ?? 0
    let minimumCenterY =
      memberIDs
      .compactMap { input.itemCenterY[$0] }
      .min() ?? 0
    let groupOrigin = CGPoint(x: accumulator.nextAutoGroupMinX, y: 0)
    let positions = memberIDs.reduce(into: [String: CGPoint]()) { partial, nodeID in
      let rank = input.rankAssignment.internalRanks[nodeID] ?? groupRankOffset
      let localRank = max(0, rank - groupRankOffset)
      let centerY = input.itemCenterY[nodeID] ?? minimumCenterY
      partial[nodeID] = snappedLayoutPoint(
        CGPoint(
          x: groupOrigin.x + PolicyCanvasLayout.groupHorizontalPadding
            + (CGFloat(localRank) * input.configuration.columnStep),
          y: groupOrigin.y + PolicyCanvasLayout.groupVerticalPadding
            + (centerY - minimumCenterY)
        )
      )
    }
    accumulator.nodePositions.merge(positions) { _, new in new }
    accumulator.autoPlacedNodeIDs.formUnion(memberIDs)
    updateGroupFrames(
      group: group,
      memberIDs: memberIDs,
      positions: positions,
      configuration: input.configuration,
      accumulator: &accumulator
    )
  }

  private func updateGroupFrames(
    group: PolicyCanvasNormalizedLayoutGroup,
    memberIDs: [String],
    positions: [String: CGPoint],
    configuration: PolicyCanvasLayoutConfiguration,
    accumulator: inout PolicyCanvasUnconstrainedPlacement
  ) {
    let memberBounds = memberIDs.reduce(CGRect.null) { partial, nodeID in
      guard let position = positions[nodeID] else {
        return partial
      }
      return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
    }
    guard !memberBounds.isNull else {
      return
    }
    let placementFrame: CGRect
    if let actualGroupID = group.actualGroupID {
      let frame = policyCanvasGroupFrame(containing: memberBounds)
      accumulator.groupFrames[actualGroupID] = frame
      placementFrame = frame
    } else {
      placementFrame = memberBounds.integral
    }
    accumulator.groupFramesByLayoutID[group.layoutID] = placementFrame
    accumulator.nextAutoGroupMinX = max(
      accumulator.nextAutoGroupMinX,
      placementFrame.maxX + configuration.interGroupSpacing
    )
  }
}

struct PolicyCanvasTightBoundingBoxGroupFrames: PolicyCanvasGroupPlacementAlgorithm {
  func placeGroups(input: PolicyCanvasGroupPlacementInput) -> PolicyCanvasGroupPlacementOutput {
    let nodePositions = input.fallbackNodePositions
    var groupFrames: [String: CGRect] = [:]
    var framesByLayoutID: [String: CGRect] = [:]
    for group in input.graph.groups {
      let memberBounds = group.memberNodeIDs.reduce(CGRect.null) { partial, nodeID in
        guard let position = nodePositions[nodeID] else {
          return partial
        }
        return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
      }
      guard !memberBounds.isNull else {
        continue
      }
      let frame = policyCanvasGroupFrame(containing: memberBounds)
      groupFrames[group.id] = frame
      framesByLayoutID[group.id] = frame
    }
    for node in input.graph.nodes where node.groupID == nil {
      guard let position = nodePositions[node.id] else {
        continue
      }
      framesByLayoutID["__ungrouped__\(node.id)"] =
        CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
    }
    return PolicyCanvasGroupPlacementOutput(
      nodePositions: nodePositions,
      groupFrames: groupFrames,
      groupFramesByLayoutID: framesByLayoutID,
      autoPlacedNodeIDs: policyCanvasAutoPlacedNodeIDs(graph: input.graph, mode: input.mode)
    )
  }
}

struct PolicyCanvasNoOpLayoutPostProcessing: PolicyCanvasLayoutPostProcessingAlgorithm {
  func processLayout(
    input: PolicyCanvasLayoutPostProcessingInput
  ) -> PolicyCanvasLayoutPostProcessingOutput {
    PolicyCanvasLayoutPostProcessingOutput(
      nodePositions: input.nodePositions,
      groupFrames: input.groupFrames,
      groupFramesByLayoutID: input.groupFramesByLayoutID
    )
  }
}

struct PolicyCanvasSugiyamaCrossingMetrics: PolicyCanvasMetricsAlgorithm {
  func measure(input: PolicyCanvasMetricsInput) -> PolicyCanvasLayoutMetrics {
    let base = policyCanvasMeasureLayoutMetrics(
      graph: input.graph,
      nodePositions: input.nodePositions,
      groupRanks: input.ranks,
      layoutGroupIDByNodeID: input.layoutGroupIDByNodeID
    )
    return PolicyCanvasLayoutMetrics(
      macroLayerCount: base.macroLayerCount,
      crossGroupOrderViolations: 0,
      anchoredNodeCount: base.anchoredNodeCount,
      edgeCrossingCount: base.edgeCrossingCount,
      flowDirectionViolationCount: base.flowDirectionViolationCount,
      averageEdgeLength: base.averageEdgeLength,
      edgeLengthVariance: base.edgeLengthVariance,
      readabilityScore: max(0, 1_000 - Double(base.edgeCrossingCount * 220))
    )
  }
}
