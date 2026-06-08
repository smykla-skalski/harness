import Foundation
import SwiftUI

// Unconstrained (no manual anchors) layered placement: layer ordering, group
// member placement, and Brandes-Köpf-aligned vertical positioning.

private struct PolicyCanvasUnconstrainedOrdering {
  let itemCenterY: [String: CGFloat]
  let orderHints: [String: Double]
  let groupOrder: [PolicyCanvasNormalizedLayoutGroup]
}

extension PolicyCanvasLayeredLayoutEngine {
  func normalizedGroups(for graph: PolicyCanvasLayoutGraph)
    -> [PolicyCanvasNormalizedLayoutGroup]
  {
    var groups = graph.groups.enumerated().map { index, group in
      PolicyCanvasNormalizedLayoutGroup(
        layoutID: group.id,
        actualGroupID: group.id,
        originalIndex: index,
        nodeIDs: uniqueNodeIDs(group.memberNodeIDs)
      )
    }
    var groupIndexByID = Dictionary(
      uniqueKeysWithValues: groups.enumerated().map { ($1.layoutID, $0) }
    )

    for node in graph.nodes {
      if let groupID = node.groupID {
        if let index = groupIndexByID[groupID] {
          if !groups[index].nodeIDs.contains(node.id) {
            groups[index].nodeIDs.append(node.id)
          }
          continue
        }
        groupIndexByID[groupID] = groups.count
        groups.append(
          PolicyCanvasNormalizedLayoutGroup(
            layoutID: groupID,
            actualGroupID: nil,
            originalIndex: groups.count,
            nodeIDs: [node.id]
          )
        )
        continue
      }
      groups.append(
        PolicyCanvasNormalizedLayoutGroup(
          layoutID: "__ungrouped__\(node.id)",
          actualGroupID: nil,
          originalIndex: groups.count,
          nodeIDs: [node.id]
        )
      )
    }

    return groups
  }

  func unconstrainedLayeredLayout(
    inputs: PolicyCanvasLayeredLayoutInputs
  ) -> PolicyCanvasLayoutResult {
    let ordering = unconstrainedLayoutOrdering(inputs: inputs)
    var accumulator = PolicyCanvasUnconstrainedPlacement()
    for group in ordering.groupOrder {
      placeUnconstrainedGroup(
        group: group,
        inputs: inputs,
        itemCenterY: ordering.itemCenterY,
        orderHints: ordering.orderHints,
        accumulator: &accumulator
      )
    }
    // Pull parallel-branch groups (two or more at the same macro rank) into one
    // shared rank band, stacked vertically and level with their feeders, before
    // the terminal comb arranges sinks around the resulting spine. A no-op for a
    // one-group-per-rank flow.
    policyCanvasCompactParallelGroupBands(
      input: PolicyCanvasParallelGroupBandCompactionInput(
        groups: ordering.groupOrder,
        edges: inputs.graph.edges,
        groupRanks: inputs.groupRanks,
        layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
        configuration: inputs.configuration
      ),
      accumulator: &accumulator
    )
    var nodePositions = policyCanvasArrangedDecisionTerminals(
      nodePositions: accumulator.nodePositions,
      edges: inputs.graph.edges
    )
    // The comb arranges a group's terminals by topology with no awareness of
    // foreign groups, so a lifted collector or dropped branch terminal can land
    // on top of another group's node or title strip. Clear those cross-group
    // collisions before the frames are rebuilt from the final positions.
    nodePositions = policyCanvasResolveNodeAndForeignTitleOverlaps(
      nodePositions: nodePositions,
      layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
      groupTitleFramesByID: accumulator.groupFramesByLayoutID.mapValues(
        policyCanvasGroupTitleFrame
      )
    )
    var groupFrames = accumulator.groupFrames
    var groupFramesByLayoutID = accumulator.groupFramesByLayoutID

    // The terminal-arrangement pass scatters group members (collector up, branch
    // terminals down), so the column-era frames no longer bound them. Rebuild
    // every group frame from the rearranged positions.
    func rebuiltGroupFrame(layoutID: String, positions: [String: CGPoint]) -> CGRect? {
      let bounds = positions.keys
        .filter { inputs.layoutGroupIDByNodeID[$0] == layoutID }
        .reduce(CGRect.null) { partial, nodeID in
          guard let position = positions[nodeID] else { return partial }
          return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
        }
      return bounds.isNull ? nil : policyCanvasGroupFrame(containing: bounds)
    }

    func rebuildGroupFrames(positions: [String: CGPoint]) {
      for layoutID in Array(groupFramesByLayoutID.keys) {
        if let frame = rebuiltGroupFrame(layoutID: layoutID, positions: positions) {
          groupFramesByLayoutID[layoutID] = frame
        }
      }
      for actualGroupID in Array(groupFrames.keys) {
        if let frame = rebuiltGroupFrame(layoutID: actualGroupID, positions: positions) {
          groupFrames[actualGroupID] = frame
        }
      }
    }
    rebuildGroupFrames(positions: nodePositions)
    for _ in 0..<3 {
      let resolvedPositions = policyCanvasResolveNodeAndForeignTitleOverlaps(
        nodePositions: nodePositions,
        layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
        groupTitleFramesByID: groupFramesByLayoutID.mapValues(policyCanvasGroupTitleFrame)
      )
      guard resolvedPositions != nodePositions else {
        break
      }
      nodePositions = resolvedPositions
      rebuildGroupFrames(positions: nodePositions)
    }

    let overallMinY =
      groupFrames.values.map(\.minY).min()
      ?? nodePositions.values.map(\.y).min()
      ?? 0
    if overallMinY < 0 {
      let yShift = -overallMinY
      nodePositions = nodePositions.mapValues { point in
        CGPoint(x: point.x, y: point.y + yShift)
      }
      groupFrames = groupFrames.mapValues { $0.offsetBy(dx: 0, dy: yShift) }
      groupFramesByLayoutID = groupFramesByLayoutID.mapValues { $0.offsetBy(dx: 0, dy: yShift) }
    }

    let metrics = policyCanvasMeasureLayoutMetrics(
      graph: inputs.graph,
      nodePositions: nodePositions,
      groupRanks: inputs.groupRanks,
      layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID
    )
    let routingHints = policyCanvasLayoutRoutingHints(
      graph: inputs.graph,
      nodePositions: nodePositions,
      layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
      groupFramesByLayoutID: groupFramesByLayoutID
    )
    return PolicyCanvasLayoutResult(
      nodePositions: nodePositions,
      groupFrames: groupFrames,
      autoPlacedNodeIDs: accumulator.autoPlacedNodeIDs,
      metrics: metrics,
      routingHints: routingHints,
      precomputedRoutes: nil
    )
  }

  private func unconstrainedLayoutOrdering(
    inputs: PolicyCanvasLayeredLayoutInputs
  ) -> PolicyCanvasUnconstrainedOrdering {
    let graph = inputs.graph
    let normalizedGroups = inputs.normalizedGroups
    let layoutGroupIDByNodeID = inputs.layoutGroupIDByNodeID
    let groupRanks = inputs.groupRanks
    let internalRanks = inputs.internalRanks
    let acyclicNodeEdges = inputs.acyclicNodeEdges
    let configuration = inputs.configuration
    let maxInternalRankByGroup = normalizedGroups.reduce(into: [:]) { partial, group in
      partial[group.layoutID] = group.nodeIDs.map { internalRanks[$0] ?? 0 }.max() ?? 0
    }
    let macroRanks = Set(groupRanks.values).sorted()
    let compositeBaseRankByMacroRank = compositeBaseRanks(
      macroRanks: macroRanks,
      normalizedGroups: normalizedGroups,
      groupRanks: groupRanks,
      maxInternalRankByGroup: maxInternalRankByGroup
    )
    let nodeRanks: [String: Int] = graph.nodes.reduce(into: [:]) { partial, node in
      guard let groupID = layoutGroupIDByNodeID[node.id] else {
        return
      }
      let macroRank = groupRanks[groupID] ?? 0
      let baseRank = compositeBaseRankByMacroRank[macroRank] ?? 0
      partial[node.id] = baseRank + (internalRanks[node.id] ?? 0)
    }
    let initialOrders = initialOrderHints(
      normalizedGroups: normalizedGroups,
      nodesByID: Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }),
      edges: acyclicNodeEdges
    )
    let orderingGraph = policyCanvasAugmentedLayeredOrderingGraph(
      nodeIDs: graph.nodes.map(\.id),
      ranks: nodeRanks,
      edges: acyclicNodeEdges,
      initialOrders: initialOrders
    )
    let orderedLayers = policyCanvasReducedLayerOrders(
      graph: orderingGraph,
      maxPasses: configuration.sweepPassCount
    )
    let itemCenterY = policyCanvasBrandesKopfYAssignment(
      layers: orderedLayers,
      graph: orderingGraph,
      rowStep: configuration.rowStep
    )
    var orderHints: [String: Double] = [:]
    for layer in orderedLayers {
      let realNodeIDs = layer.compactMap { orderingGraph.itemsByID[$0]?.realNodeID }
      for (index, nodeID) in realNodeIDs.enumerated() {
        orderHints[nodeID] = Double(index)
      }
    }
    let groupCenterYByID = groupBarycenterY(
      normalizedGroups: normalizedGroups,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      edges: acyclicNodeEdges,
      itemCenterY: itemCenterY
    )
    let groupOrder = orderedGroups(
      normalizedGroups: normalizedGroups,
      groupRanks: groupRanks,
      anchoredMinXByGroup: [:],
      groupCenterY: groupCenterYByID
    )
    return PolicyCanvasUnconstrainedOrdering(
      itemCenterY: itemCenterY,
      orderHints: orderHints,
      groupOrder: groupOrder
    )
  }

  func placeUnconstrainedGroup(
    group: PolicyCanvasNormalizedLayoutGroup,
    inputs: PolicyCanvasLayeredLayoutInputs,
    itemCenterY: [String: CGFloat],
    orderHints: [String: Double],
    accumulator: inout PolicyCanvasUnconstrainedPlacement
  ) {
    let memberIDs = group.nodeIDs.filter { inputs.layoutGroupIDByNodeID[$0] == group.layoutID }
    guard !memberIDs.isEmpty else {
      return
    }

    let placedNeighborCenterY = unconstrainedPlacedNeighborCenters(
      memberIDs: memberIDs,
      edges: inputs.graph.edges,
      nodePositions: accumulator.nodePositions
    )
    let orderingTables = PolicyCanvasMemberOrderingTables(
      internalRanks: inputs.internalRanks,
      placedNeighborCenterY: placedNeighborCenterY,
      itemCenterY: itemCenterY,
      orderHints: orderHints
    )
    let orderedMembers = orderedFreeMembers(
      in: group,
      anchoredNodeIDs: [],
      internalRanks: inputs.internalRanks,
      orderHints: orderHints
    ).sorted { leftID, rightID in
      unconstrainedMemberPrecedes(
        leftID: leftID,
        rightID: rightID,
        tables: orderingTables
      )
    }
    let groupOrigin = CGPoint(x: accumulator.nextAutoGroupMinX, y: 0)
    let xPlacement = placeFreeMembers(
      orderedMembers,
      internalRanks: inputs.internalRanks,
      groupOrigin: groupOrigin,
      reservedFrames: [],
      configuration: inputs.configuration,
      verticalHints: Dictionary(
        uniqueKeysWithValues: orderedMembers.map { nodeID in
          (nodeID, placedNeighborCenterY[nodeID] ?? itemCenterY[nodeID] ?? .zero)
        }
      ),
      edges: inputs.graph.edges
    )
    let positions = shiftedUnconstrainedPositions(
      orderedMembers: orderedMembers,
      placedPositions: xPlacement.positions,
      itemCenterY: itemCenterY
    )
    accumulator.nodePositions.merge(positions) { _, new in new }
    accumulator.autoPlacedNodeIDs.formUnion(orderedMembers)

    let memberBounds = memberIDs.reduce(CGRect.null) { partial, nodeID in
      guard let position = accumulator.nodePositions[nodeID] else {
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
      placementFrame.maxX + inputs.configuration.interGroupSpacing
    )
  }

  private func shiftedUnconstrainedPositions(
    orderedMembers: [String],
    placedPositions: [String: CGPoint],
    itemCenterY: [String: CGFloat]
  ) -> [String: CGPoint] {
    let localBounds = orderedMembers.reduce(CGRect.null) { partial, nodeID in
      guard let position = placedPositions[nodeID] else {
        return partial
      }
      return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
    }
    let targetCenters = orderedMembers.compactMap { itemCenterY[$0] }
    let targetCenterY: CGFloat
    if let minTargetCenterY = targetCenters.min(), let maxTargetCenterY = targetCenters.max() {
      targetCenterY = (minTargetCenterY + maxTargetCenterY) / 2
    } else {
      targetCenterY = 0
    }
    let localCenterY = localBounds.isNull ? 0 : localBounds.midY
    let yShift = snappedLayoutDelta(targetCenterY - localCenterY)
    return orderedMembers.reduce(into: [:]) { partial, nodeID in
      guard let position = placedPositions[nodeID] else {
        return
      }
      partial[nodeID] = snappedLayoutPoint(CGPoint(x: position.x, y: position.y + yShift))
    }
  }

  func unconstrainedPlacedNeighborCenters(
    memberIDs: [String],
    edges: [PolicyCanvasLayoutEdge],
    nodePositions: [String: CGPoint]
  ) -> [String: CGFloat] {
    memberIDs.reduce(into: [:]) { partial, nodeID in
      let neighborCenters = edges.compactMap { edge -> CGFloat? in
        if edge.targetNodeID == nodeID, let sourcePosition = nodePositions[edge.sourceNodeID] {
          return sourcePosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
        }
        if edge.sourceNodeID == nodeID, let targetPosition = nodePositions[edge.targetNodeID] {
          return targetPosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
        }
        return nil
      }
      guard !neighborCenters.isEmpty else {
        return
      }
      partial[nodeID] = neighborCenters.reduce(CGFloat.zero, +) / CGFloat(neighborCenters.count)
    }
  }

  func unconstrainedMemberPrecedes(
    leftID: String,
    rightID: String,
    tables: PolicyCanvasMemberOrderingTables
  ) -> Bool {
    let leftRank = tables.internalRanks[leftID] ?? 0
    let rightRank = tables.internalRanks[rightID] ?? 0
    if leftRank != rightRank {
      return leftRank < rightRank
    }
    let leftPlacedCenterY = tables.placedNeighborCenterY[leftID]
    let rightPlacedCenterY = tables.placedNeighborCenterY[rightID]
    if let leftPlacedCenterY, let rightPlacedCenterY,
      abs(leftPlacedCenterY - rightPlacedCenterY) >= (PolicyCanvasLayout.gridSize / 2)
    {
      return leftPlacedCenterY < rightPlacedCenterY
    }
    let leftCenterY = tables.itemCenterY[leftID] ?? 0
    let rightCenterY = tables.itemCenterY[rightID] ?? 0
    if abs(leftCenterY - rightCenterY) >= (PolicyCanvasLayout.gridSize / 2) {
      return leftCenterY < rightCenterY
    }
    return (tables.orderHints[leftID] ?? .zero) < (tables.orderHints[rightID] ?? .zero)
  }

}
