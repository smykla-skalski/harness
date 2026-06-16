import CoreGraphics
import Foundation

struct PolicyCanvasDepthFirstBackEdgeReversal: PolicyCanvasCycleBreakingAlgorithm {
  func breakCycles(input: PolicyCanvasCycleBreakingInput) -> [PolicyCanvasLayoutEdge] {
    policyCanvasAcyclicEdges(
      ids: input.nodeIDs,
      originalOrder: input.originalOrder,
      edges: input.edges
    )
  }
}

struct PolicyCanvasHarnessGroupAwareLongestPathLayering: PolicyCanvasRankAssignmentAlgorithm {
  func assignRanks(input: PolicyCanvasRankAssignmentInput) -> PolicyCanvasRankAssignmentOutput {
    let engine = PolicyCanvasLayeredLayoutEngine(mode: input.mode)
    let normalizedGroups = engine.normalizedGroups(for: input.graph)
    let layoutGroupIDByNodeID = policyCanvasLayoutGroupIDsByNodeID(
      graph: input.graph,
      normalizedGroups: normalizedGroups
    )
    let groupRanks = engine.groupRanks(
      for: normalizedGroups,
      edges: input.edges,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    let internalRanks = engine.internalRanks(
      for: normalizedGroups,
      edges: input.edges,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    var maxInternalRankByGroup: [String: Int] = [:]
    for group in normalizedGroups {
      maxInternalRankByGroup[group.layoutID] =
        group.nodeIDs.map { internalRanks[$0] ?? 0 }.max() ?? 0
    }
    let compositeBaseRankByMacroRank = engine.compositeBaseRanks(
      macroRanks: Set(groupRanks.values).sorted(),
      normalizedGroups: normalizedGroups,
      groupRanks: groupRanks,
      maxInternalRankByGroup: maxInternalRankByGroup
    )
    let nodeRanks: [String: Int] = input.graph.nodes.reduce(into: [:]) { partial, node in
      guard let groupID = layoutGroupIDByNodeID[node.id] else {
        return
      }
      let macroRank = groupRanks[groupID] ?? 0
      let baseRank = compositeBaseRankByMacroRank[macroRank] ?? 0
      partial[node.id] = baseRank + (internalRanks[node.id] ?? 0)
    }
    let nodesByID = Dictionary(uniqueKeysWithValues: input.graph.nodes.map { ($0.id, $0) })
    let initialOrders = engine.initialOrderHints(
      normalizedGroups: normalizedGroups,
      nodesByID: nodesByID,
      edges: input.edges
    )
    return PolicyCanvasRankAssignmentOutput(
      nodeRanks: nodeRanks,
      scopeRanks: groupRanks,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      normalizedGroups: normalizedGroups,
      internalRanks: internalRanks,
      initialOrders: initialOrders,
      acyclicEdges: input.edges
    )
  }
}

struct PolicyCanvasInterpolatedDummyChainNormalization:
  PolicyCanvasLongEdgeNormalizationAlgorithm
{
  func normalize(input: PolicyCanvasLongEdgeNormalizationInput)
    -> PolicyCanvasLayeredOrderingGraph
  {
    policyCanvasAugmentedLayeredOrderingGraph(
      nodeIDs: input.nodeIDs,
      ranks: input.ranks,
      edges: input.edges,
      initialOrders: input.initialOrders
    )
  }
}

struct PolicyCanvasSeededBarycenterTransposeReduction:
  PolicyCanvasLayerOrderingAlgorithm
{
  func orderLayers(input: PolicyCanvasLayerOrderingInput) -> [[String]] {
    policyCanvasReducedLayerOrders(graph: input.graph, maxPasses: input.maxPasses)
  }
}

struct PolicyCanvasBrandesKopfCoordinateAssignment:
  PolicyCanvasCoordinateAssignmentAlgorithm
{
  func assignCoordinates(
    input: PolicyCanvasCoordinateAssignmentInput
  ) -> PolicyCanvasCoordinateAssignmentOutput {
    PolicyCanvasCoordinateAssignmentOutput(
      itemCenterY: policyCanvasBrandesKopfYAssignment(
        layers: input.layers,
        graph: input.graph,
        rowStep: input.configuration.rowStep
      )
    )
  }
}

struct PolicyCanvasHarnessGroupFramePacking: PolicyCanvasGroupPlacementAlgorithm {
  func placeGroups(input: PolicyCanvasGroupPlacementInput) -> PolicyCanvasGroupPlacementOutput {
    let engine = PolicyCanvasLayeredLayoutEngine(mode: input.mode)
    let layoutInputs = PolicyCanvasLayeredLayoutInputs(
      graph: input.graph,
      normalizedGroups: input.rankAssignment.normalizedGroups,
      layoutGroupIDByNodeID: input.rankAssignment.layoutGroupIDByNodeID,
      groupRanks: input.rankAssignment.scopeRanks,
      internalRanks: input.rankAssignment.internalRanks,
      acyclicNodeEdges: input.rankAssignment.acyclicEdges,
      configuration: input.configuration
    )
    let anchoredNodeIDs = Set(
      input.graph.nodes.compactMap { node in
        node.anchor == nil ? nil : node.id
      })
    guard !anchoredNodeIDs.isEmpty else {
      return unconstrainedPlacement(
        engine: engine,
        inputs: layoutInputs,
        itemCenterY: input.itemCenterY,
        orderHints: input.orderHints
      )
    }
    return anchoredPlacement(
      engine: engine,
      inputs: layoutInputs,
      anchoredNodeIDs: anchoredNodeIDs
    )
  }

  private func unconstrainedPlacement(
    engine: PolicyCanvasLayeredLayoutEngine,
    inputs: PolicyCanvasLayeredLayoutInputs,
    itemCenterY: [String: CGFloat],
    orderHints: [String: Double]
  ) -> PolicyCanvasGroupPlacementOutput {
    var accumulator = PolicyCanvasUnconstrainedPlacement()
    let groupOrder = engine.orderedGroups(
      normalizedGroups: inputs.normalizedGroups,
      groupRanks: inputs.groupRanks,
      anchoredMinXByGroup: [:],
      groupCenterY: engine.groupBarycenterY(
        normalizedGroups: inputs.normalizedGroups,
        layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
        edges: inputs.acyclicNodeEdges,
        itemCenterY: itemCenterY
      )
    )
    for group in groupOrder {
      engine.placeUnconstrainedGroup(
        group: group,
        inputs: inputs,
        itemCenterY: itemCenterY,
        orderHints: orderHints,
        accumulator: &accumulator
      )
    }
    policyCanvasCompactParallelGroupBands(
      input: PolicyCanvasParallelGroupBandCompactionInput(
        groups: groupOrder,
        edges: inputs.graph.edges,
        groupRanks: inputs.groupRanks,
        layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
        configuration: inputs.configuration
      ),
      accumulator: &accumulator
    )
    return PolicyCanvasGroupPlacementOutput(
      nodePositions: accumulator.nodePositions,
      groupFrames: accumulator.groupFrames,
      groupFramesByLayoutID: accumulator.groupFramesByLayoutID,
      autoPlacedNodeIDs: accumulator.autoPlacedNodeIDs
    )
  }

  private func anchoredPlacement(
    engine: PolicyCanvasLayeredLayoutEngine,
    inputs: PolicyCanvasLayeredLayoutInputs,
    anchoredNodeIDs: Set<String>
  ) -> PolicyCanvasGroupPlacementOutput {
    let nodesByID = Dictionary(uniqueKeysWithValues: inputs.graph.nodes.map { ($0.id, $0) })
    let anchoredMinXByGroup = engine.anchoredMinXByGroup(
      nodesByID: nodesByID,
      normalizedGroups: inputs.normalizedGroups
    )
    let groupOrder = engine.orderedGroups(
      normalizedGroups: inputs.normalizedGroups,
      groupRanks: inputs.groupRanks,
      anchoredMinXByGroup: anchoredMinXByGroup
    )
    var accumulator = PolicyCanvasAnchoredPlacement()
    let context = PolicyCanvasAnchoredGroupContext(
      nodesByID: nodesByID,
      anchoredNodeIDs: anchoredNodeIDs,
      internalRanks: inputs.internalRanks,
      orderHints: engine.anchoredOrderHints(
        inputs: inputs,
        groupOrder: groupOrder,
        nodesByID: nodesByID
      ),
      configuration: inputs.configuration
    )
    for group in groupOrder {
      engine.placeAnchoredGroup(group: group, context: context, accumulator: &accumulator)
    }
    engine.balanceGroupVerticalPositions(
      groups: groupOrder,
      context: PolicyCanvasVerticalBalanceContext(
        graph: inputs.graph,
        layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
        anchoredGroupIDs: accumulator.anchoredGroupIDs,
        configuration: inputs.configuration
      ),
      accumulator: &accumulator
    )
    return PolicyCanvasGroupPlacementOutput(
      nodePositions: accumulator.nodePositions,
      groupFrames: accumulator.groupFrames,
      groupFramesByLayoutID: accumulator.groupFramesByLayoutID,
      autoPlacedNodeIDs: accumulator.autoPlacedNodeIDs
    )
  }
}

struct PolicyCanvasTerminalCombAndSingleFedAlignment:
  PolicyCanvasLayoutPostProcessingAlgorithm
{
  func processLayout(
    input: PolicyCanvasLayoutPostProcessingInput
  ) -> PolicyCanvasLayoutPostProcessingOutput {
    let nodeSizes = policyCanvasLayoutNodeSizes(nodes: input.graph.nodes, edges: input.graph.edges)
    var nodePositions = policyCanvasArrangedDecisionTerminals(
      nodePositions: input.nodePositions,
      edges: input.graph.edges
    )
    nodePositions = policyCanvasResolveNodeAndForeignTitleOverlaps(
      nodePositions: nodePositions,
      layoutGroupIDByNodeID: input.rankAssignment.layoutGroupIDByNodeID,
      groupTitleFramesByID: input.groupFramesByLayoutID.mapValues(policyCanvasGroupTitleFrame),
      nodeSizes: nodeSizes
    )
    var groupFrames = input.groupFrames
    var groupFramesByLayoutID = policyCanvasRebuiltGroupFramesByLayoutID(
      normalizedGroups: input.rankAssignment.normalizedGroups,
      layoutGroupIDByNodeID: input.rankAssignment.layoutGroupIDByNodeID,
      nodePositions: nodePositions,
      nodeSizes: nodeSizes
    )
    func applyActualGroupFrames() {
      for group in input.rankAssignment.normalizedGroups {
        guard let actualGroupID = group.actualGroupID,
          let frame = groupFramesByLayoutID[group.layoutID]
        else {
          continue
        }
        groupFrames[actualGroupID] = frame
      }
    }
    applyActualGroupFrames()
    for _ in 0..<3 {
      let resolvedPositions = policyCanvasResolveNodeAndForeignTitleOverlaps(
        nodePositions: nodePositions,
        layoutGroupIDByNodeID: input.rankAssignment.layoutGroupIDByNodeID,
        groupTitleFramesByID: groupFramesByLayoutID.mapValues(policyCanvasGroupTitleFrame),
        nodeSizes: nodeSizes
      )
      guard resolvedPositions != nodePositions else {
        break
      }
      nodePositions = resolvedPositions
      groupFramesByLayoutID = policyCanvasRebuiltGroupFramesByLayoutID(
        normalizedGroups: input.rankAssignment.normalizedGroups,
        layoutGroupIDByNodeID: input.rankAssignment.layoutGroupIDByNodeID,
        nodePositions: nodePositions,
        nodeSizes: nodeSizes
      )
      applyActualGroupFrames()
    }
    let overallMinY =
      groupFrames.values.map(\.minY).min()
      ?? nodePositions.values.map(\.y).min()
      ?? 0
    if overallMinY < 0 {
      let yShift = -overallMinY
      nodePositions = nodePositions.mapValues { CGPoint(x: $0.x, y: $0.y + yShift) }
      groupFrames = groupFrames.mapValues { $0.offsetBy(dx: 0, dy: yShift) }
      groupFramesByLayoutID = groupFramesByLayoutID.mapValues { $0.offsetBy(dx: 0, dy: yShift) }
    }
    return PolicyCanvasLayoutPostProcessingOutput(
      nodePositions: nodePositions,
      groupFrames: groupFrames,
      groupFramesByLayoutID: groupFramesByLayoutID
    )
  }
}

struct PolicyCanvasHarnessReadabilityMetricsAlgorithm: PolicyCanvasMetricsAlgorithm {
  func measure(input: PolicyCanvasMetricsInput) -> PolicyCanvasLayoutMetrics {
    policyCanvasMeasureLayoutMetrics(
      graph: input.graph,
      nodePositions: input.nodePositions,
      groupRanks: input.ranks,
      layoutGroupIDByNodeID: input.layoutGroupIDByNodeID
    )
  }
}
