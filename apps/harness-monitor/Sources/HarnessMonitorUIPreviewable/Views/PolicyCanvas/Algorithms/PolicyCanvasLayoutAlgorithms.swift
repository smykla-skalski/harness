import CoreGraphics
import Foundation

struct PolicyCanvasCycleBreakingInput: Sendable {
  let nodeIDs: [String]
  let originalOrder: [String: Int]
  let edges: [PolicyCanvasLayoutEdge]
}

struct PolicyCanvasRankAssignmentInput: Sendable {
  let graph: PolicyCanvasLayoutGraph
  let nodeIDs: [String]
  let originalOrder: [String: Int]
  let edges: [PolicyCanvasLayoutEdge]
  let mode: PolicyCanvasAutomaticLayoutMode
}

struct PolicyCanvasRankAssignmentOutput: Sendable {
  let nodeRanks: [String: Int]
  let scopeRanks: [String: Int]
  let layoutGroupIDByNodeID: [String: String]
  let normalizedGroups: [PolicyCanvasNormalizedLayoutGroup]
  let internalRanks: [String: Int]
  let initialOrders: [String: Double]
  let acyclicEdges: [PolicyCanvasLayoutEdge]
}

struct PolicyCanvasLongEdgeNormalizationInput: Sendable {
  let nodeIDs: [String]
  let ranks: [String: Int]
  let edges: [PolicyCanvasLayoutEdge]
  let initialOrders: [String: Double]
}

struct PolicyCanvasLayerOrderingInput: Sendable {
  let graph: PolicyCanvasLayeredOrderingGraph
  let maxPasses: Int
}

struct PolicyCanvasCoordinateAssignmentInput: Sendable {
  let layers: [[String]]
  let graph: PolicyCanvasLayeredOrderingGraph
  let configuration: PolicyCanvasLayoutConfiguration
}

struct PolicyCanvasCoordinateAssignmentOutput: Sendable {
  let itemCenterY: [String: CGFloat]
}

struct PolicyCanvasGroupPlacementInput: Sendable {
  let graph: PolicyCanvasLayoutGraph
  let mode: PolicyCanvasAutomaticLayoutMode
  let rankAssignment: PolicyCanvasRankAssignmentOutput
  let itemCenterY: [String: CGFloat]
  let orderHints: [String: Double]
  let fallbackNodePositions: [String: CGPoint]
  let configuration: PolicyCanvasLayoutConfiguration
}

struct PolicyCanvasGroupPlacementOutput: Sendable {
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let groupFramesByLayoutID: [String: CGRect]
  let autoPlacedNodeIDs: Set<String>
}

struct PolicyCanvasLayoutPostProcessingInput: Sendable {
  let graph: PolicyCanvasLayoutGraph
  let rankAssignment: PolicyCanvasRankAssignmentOutput
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let groupFramesByLayoutID: [String: CGRect]
}

struct PolicyCanvasLayoutPostProcessingOutput: Sendable {
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let groupFramesByLayoutID: [String: CGRect]
}

struct PolicyCanvasMetricsInput: Sendable {
  let graph: PolicyCanvasLayoutGraph
  let nodePositions: [String: CGPoint]
  let ranks: [String: Int]
  let layoutGroupIDByNodeID: [String: String]
}

protocol PolicyCanvasCycleBreakingAlgorithm: Sendable {
  func breakCycles(input: PolicyCanvasCycleBreakingInput) -> [PolicyCanvasLayoutEdge]
}

protocol PolicyCanvasRankAssignmentAlgorithm: Sendable {
  func assignRanks(input: PolicyCanvasRankAssignmentInput) -> PolicyCanvasRankAssignmentOutput
}

protocol PolicyCanvasLongEdgeNormalizationAlgorithm: Sendable {
  func normalize(input: PolicyCanvasLongEdgeNormalizationInput) -> PolicyCanvasLayeredOrderingGraph
}

protocol PolicyCanvasLayerOrderingAlgorithm: Sendable {
  func orderLayers(input: PolicyCanvasLayerOrderingInput) -> [[String]]
}

protocol PolicyCanvasCoordinateAssignmentAlgorithm: Sendable {
  func assignCoordinates(
    input: PolicyCanvasCoordinateAssignmentInput
  ) -> PolicyCanvasCoordinateAssignmentOutput
}

protocol PolicyCanvasGroupPlacementAlgorithm: Sendable {
  func placeGroups(input: PolicyCanvasGroupPlacementInput) -> PolicyCanvasGroupPlacementOutput
}

protocol PolicyCanvasLayoutPostProcessingAlgorithm: Sendable {
  func processLayout(
    input: PolicyCanvasLayoutPostProcessingInput
  ) -> PolicyCanvasLayoutPostProcessingOutput
}

protocol PolicyCanvasMetricsAlgorithm: Sendable {
  func measure(input: PolicyCanvasMetricsInput) -> PolicyCanvasLayoutMetrics
}

struct PolicyCanvasDepthFirstBackEdgeReversal: PolicyCanvasCycleBreakingAlgorithm {
  func breakCycles(input: PolicyCanvasCycleBreakingInput) -> [PolicyCanvasLayoutEdge] {
    policyCanvasAcyclicEdges(
      ids: input.nodeIDs,
      originalOrder: input.originalOrder,
      edges: input.edges
    )
  }
}

struct PolicyCanvasGreedyFeedbackArcReversal: PolicyCanvasCycleBreakingAlgorithm {
  func breakCycles(input: PolicyCanvasCycleBreakingInput) -> [PolicyCanvasLayoutEdge] {
    var forward: [PolicyCanvasLayoutEdge] = []
    forward.reserveCapacity(input.edges.count)
    for edge in input.edges {
      let sourceOrder = input.originalOrder[edge.sourceNodeID] ?? .max
      let targetOrder = input.originalOrder[edge.targetNodeID] ?? .max
      if sourceOrder <= targetOrder {
        forward.append(edge)
      } else {
        forward.append(
          PolicyCanvasLayoutEdge(
            id: edge.id,
            sourceNodeID: edge.targetNodeID,
            targetNodeID: edge.sourceNodeID,
            label: edge.label
          )
        )
      }
    }
    return policyCanvasAcyclicEdges(
      ids: input.nodeIDs,
      originalOrder: input.originalOrder,
      edges: forward
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
    let maxInternalRankByGroup: [String: Int] = normalizedGroups.reduce(into: [:]) {
      partial, group in
      partial[group.layoutID] = group.nodeIDs.map { internalRanks[$0] ?? 0 }.max() ?? 0
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

struct PolicyCanvasSeededBarycenterTransposeCrossingReduction:
  PolicyCanvasLayerOrderingAlgorithm
{
  func orderLayers(input: PolicyCanvasLayerOrderingInput) -> [[String]] {
    policyCanvasReducedLayerOrders(graph: input.graph, maxPasses: input.maxPasses)
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

struct PolicyCanvasBrandesKopfCoordinateAssignmentAlgorithm:
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
      anchoredMinXByGroup: [:]
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

struct PolicyCanvasTerminalCombAndSingleFedAlignment:
  PolicyCanvasLayoutPostProcessingAlgorithm
{
  func processLayout(
    input: PolicyCanvasLayoutPostProcessingInput
  ) -> PolicyCanvasLayoutPostProcessingOutput {
    var nodePositions = policyCanvasArrangedDecisionTerminals(
      nodePositions: input.nodePositions,
      edges: input.graph.edges
    )
    var groupFrames = input.groupFrames
    var groupFramesByLayoutID = policyCanvasRebuiltGroupFramesByLayoutID(
      normalizedGroups: input.rankAssignment.normalizedGroups,
      layoutGroupIDByNodeID: input.rankAssignment.layoutGroupIDByNodeID,
      nodePositions: nodePositions
    )
    for group in input.rankAssignment.normalizedGroups {
      guard let actualGroupID = group.actualGroupID,
        let frame = groupFramesByLayoutID[group.layoutID]
      else {
        continue
      }
      groupFrames[actualGroupID] = frame
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

func policyCanvasLayerOrderHints(
  layers: [[String]],
  graph: PolicyCanvasLayeredOrderingGraph
) -> [String: Double] {
  var orderHints: [String: Double] = [:]
  for layer in layers {
    let realNodeIDs = layer.compactMap { graph.itemsByID[$0]?.realNodeID }
    for (index, nodeID) in realNodeIDs.enumerated() {
      orderHints[nodeID] = Double(index)
    }
  }
  return orderHints
}

func policyCanvasLayoutGroupIDsByNodeID(
  graph: PolicyCanvasLayoutGraph,
  normalizedGroups: [PolicyCanvasNormalizedLayoutGroup]
) -> [String: String] {
  var result: [String: String] = [:]
  for group in normalizedGroups {
    for nodeID in uniqueNodeIDs(group.nodeIDs) {
      result[nodeID] = group.layoutID
    }
  }
  for node in graph.nodes {
    if let groupID = node.groupID {
      result[node.id] = groupID
    }
    if result[node.id] == nil {
      result[node.id] = "__ungrouped__\(node.id)"
    }
  }
  return result
}

func policyCanvasScopeRanks(
  nodeRanks: [String: Int],
  layoutGroupIDByNodeID: [String: String]
) -> [String: Int] {
  layoutGroupIDByNodeID.reduce(into: [:]) { partial, entry in
    let rank = nodeRanks[entry.key] ?? 0
    partial[entry.value] = min(partial[entry.value] ?? rank, rank)
  }
}

func policyCanvasAutoPlacedNodeIDs(
  graph: PolicyCanvasLayoutGraph,
  mode: PolicyCanvasAutomaticLayoutMode
) -> Set<String> {
  Set(
    graph.nodes.compactMap { node in
      if mode.preservesManualAnchors, node.anchor != nil {
        return nil
      }
      return node.id
    }
  )
}

private func policyCanvasPureUnitLayeredOrderingGraph(
  nodeIDs: [String],
  ranks: [String: Int],
  edges: [PolicyCanvasLayoutEdge],
  initialOrders: [String: Double]
) -> PolicyCanvasLayeredOrderingGraph {
  var itemsByID = Dictionary(
    uniqueKeysWithValues: nodeIDs.map { nodeID in
      (
        nodeID,
        PolicyCanvasLayeredOrderingItem(
          id: nodeID,
          realNodeID: nodeID,
          rank: ranks[nodeID] ?? 0
        )
      )
    })
  var outgoing: [String: [String]] = [:]
  var incoming: [String: [String]] = [:]
  var orderByItemID = initialOrders
  let maxRank = max(0, itemsByID.values.map(\.rank).max() ?? 0)

  func connect(_ sourceID: String, _ targetID: String) {
    outgoing[sourceID, default: []].append(targetID)
    incoming[targetID, default: []].append(sourceID)
  }

  for (edgeIndex, edge) in edges.enumerated() {
    let sourceRank = ranks[edge.sourceNodeID] ?? 0
    let targetRank = ranks[edge.targetNodeID] ?? 0
    guard targetRank > sourceRank else {
      continue
    }
    if targetRank == sourceRank + 1 {
      connect(edge.sourceNodeID, edge.targetNodeID)
      continue
    }
    var previousID = edge.sourceNodeID
    let sourceOrder = initialOrders[edge.sourceNodeID] ?? 0
    for intermediateRank in (sourceRank + 1)..<targetRank {
      let dummyID = "__dummy__\(edge.id)#\(intermediateRank)"
      assert(
        itemsByID[dummyID] == nil,
        "PolicyCanvas dummy ID collides with an existing item: \(dummyID)"
      )
      itemsByID[dummyID] = PolicyCanvasLayeredOrderingItem(
        id: dummyID,
        realNodeID: nil,
        rank: intermediateRank
      )
      orderByItemID[dummyID] = sourceOrder + (Double(edgeIndex) / 10_000)
      connect(previousID, dummyID)
      previousID = dummyID
    }
    connect(previousID, edge.targetNodeID)
  }

  var layers = Array(repeating: [String](), count: maxRank + 1)
  for item in itemsByID.values {
    layers[item.rank].append(item.id)
  }
  for rank in layers.indices {
    layers[rank].sort { leftID, rightID in
      let leftOrder = orderByItemID[leftID] ?? 0
      let rightOrder = orderByItemID[rightID] ?? 0
      if leftOrder != rightOrder {
        return leftOrder < rightOrder
      }
      let leftItem = itemsByID[leftID]
      let rightItem = itemsByID[rightID]
      if leftItem?.isDummy != rightItem?.isDummy {
        return rightItem?.isDummy ?? false
      }
      return leftID < rightID
    }
  }

  return PolicyCanvasLayeredOrderingGraph(
    itemsByID: itemsByID,
    layers: layers,
    incoming: incoming.mapValues { $0.sorted() },
    outgoing: outgoing.mapValues { $0.sorted() }
  )
}

private func policyCanvasPureBarycenterLayerOrders(
  graph: PolicyCanvasLayeredOrderingGraph,
  maxPasses: Int
) -> [[String]] {
  var layers = graph.layers
  let passLimit = max(1, maxPasses)
  for _ in 0..<passLimit {
    var changed = false
    changed =
      policyCanvasPureBarycenterSweep(
        layers: &layers,
        graph: graph,
        forward: true
      )
      || changed
    changed =
      policyCanvasPureBarycenterSweep(
        layers: &layers,
        graph: graph,
        forward: false
      )
      || changed
    if !changed {
      break
    }
  }
  return layers
}

private func policyCanvasPureBarycenterSweep(
  layers: inout [[String]],
  graph: PolicyCanvasLayeredOrderingGraph,
  forward: Bool
) -> Bool {
  guard layers.count > 1 else {
    return false
  }
  let layerIndexes =
    forward
    ? Array(1..<layers.count)
    : Array(stride(from: layers.count - 2, through: 0, by: -1))
  var changed = false

  for movingRank in layerIndexes {
    let fixedRank = forward ? movingRank - 1 : movingRank + 1
    let currentOrder = Dictionary(
      uniqueKeysWithValues: layers[movingRank].enumerated().map { ($1, $0) }
    )
    let fixedOrder = Dictionary(
      uniqueKeysWithValues: layers[fixedRank].enumerated().map { ($1, $0) }
    )
    let reordered = layers[movingRank].sorted { leftID, rightID in
      let leftScore = policyCanvasPureBarycenterScore(
        itemID: leftID,
        graph: graph,
        fixedOrder: fixedOrder,
        forward: forward,
        fallbackOrder: currentOrder[leftID] ?? 0
      )
      let rightScore = policyCanvasPureBarycenterScore(
        itemID: rightID,
        graph: graph,
        fixedOrder: fixedOrder,
        forward: forward,
        fallbackOrder: currentOrder[rightID] ?? 0
      )
      if leftScore != rightScore {
        return leftScore < rightScore
      }
      return (currentOrder[leftID] ?? 0) < (currentOrder[rightID] ?? 0)
    }
    if reordered != layers[movingRank] {
      changed = true
      layers[movingRank] = reordered
    }
  }

  return changed
}

private func policyCanvasPureBarycenterScore(
  itemID: String,
  graph: PolicyCanvasLayeredOrderingGraph,
  fixedOrder: [String: Int],
  forward: Bool,
  fallbackOrder: Int
) -> Double {
  let neighbors = forward ? (graph.incoming[itemID] ?? []) : (graph.outgoing[itemID] ?? [])
  let neighborOrders = neighbors.compactMap { neighborID in
    fixedOrder[neighborID].map(Double.init)
  }
  guard !neighborOrders.isEmpty else {
    return Double(fallbackOrder)
  }
  return neighborOrders.reduce(0, +) / Double(neighborOrders.count)
}

private func policyCanvasRebuiltGroupFramesByLayoutID(
  normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
  layoutGroupIDByNodeID: [String: String],
  nodePositions: [String: CGPoint]
) -> [String: CGRect] {
  var frames: [String: CGRect] = [:]
  for group in normalizedGroups {
    let bounds = group.nodeIDs
      .filter { layoutGroupIDByNodeID[$0] == group.layoutID }
      .reduce(CGRect.null) { partial, nodeID in
        guard let position = nodePositions[nodeID] else {
          return partial
        }
        return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
      }
    guard !bounds.isNull else {
      continue
    }
    if group.actualGroupID == nil {
      frames[group.layoutID] = bounds.integral
    } else {
      frames[group.layoutID] = policyCanvasGroupFrame(containing: bounds)
    }
  }
  return frames
}
