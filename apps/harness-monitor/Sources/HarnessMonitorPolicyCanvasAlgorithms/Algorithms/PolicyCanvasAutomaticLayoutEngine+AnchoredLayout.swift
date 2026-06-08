import Foundation
import SwiftUI

// Anchor-constrained layered placement plus the macro-rank, internal-rank, and
// group-ordering helpers shared by both layout paths.
extension PolicyCanvasLayeredLayoutEngine {
  func anchoredLayeredLayout(
    inputs: PolicyCanvasLayeredLayoutInputs,
    anchoredNodeIDs: Set<String>,
    nodesByID: [String: PolicyCanvasLayoutNode]
  ) -> PolicyCanvasLayoutResult {
    let anchoredMinXByGroup = anchoredMinXByGroup(
      nodesByID: nodesByID,
      normalizedGroups: inputs.normalizedGroups
    )
    let groupOrder = orderedGroups(
      normalizedGroups: inputs.normalizedGroups,
      groupRanks: inputs.groupRanks,
      anchoredMinXByGroup: anchoredMinXByGroup
    )
    let orderHints = anchoredOrderHints(
      inputs: inputs,
      groupOrder: groupOrder,
      nodesByID: nodesByID
    )
    let context = PolicyCanvasAnchoredGroupContext(
      nodesByID: nodesByID,
      anchoredNodeIDs: anchoredNodeIDs,
      internalRanks: inputs.internalRanks,
      orderHints: orderHints,
      configuration: inputs.configuration
    )
    var accumulator = PolicyCanvasAnchoredPlacement()
    for group in groupOrder {
      placeAnchoredGroup(group: group, context: context, accumulator: &accumulator)
    }

    balanceGroupVerticalPositions(
      groups: groupOrder,
      context: PolicyCanvasVerticalBalanceContext(
        graph: inputs.graph,
        layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
        anchoredGroupIDs: accumulator.anchoredGroupIDs,
        configuration: inputs.configuration
      ),
      accumulator: &accumulator
    )

    let metrics = policyCanvasMeasureLayoutMetrics(
      graph: inputs.graph,
      nodePositions: accumulator.nodePositions,
      groupRanks: inputs.groupRanks,
      layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID
    )
    let routingHints = policyCanvasLayoutRoutingHints(
      graph: inputs.graph,
      nodePositions: accumulator.nodePositions,
      layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
      groupFramesByLayoutID: accumulator.groupFramesByLayoutID
    )
    return PolicyCanvasLayoutResult(
      nodePositions: accumulator.nodePositions,
      groupFrames: accumulator.groupFrames,
      autoPlacedNodeIDs: accumulator.autoPlacedNodeIDs,
      metrics: metrics,
      routingHints: routingHints
    )
  }

  func anchoredOrderHints(
    inputs: PolicyCanvasLayeredLayoutInputs,
    groupOrder: [PolicyCanvasNormalizedLayoutGroup],
    nodesByID: [String: PolicyCanvasLayoutNode]
  ) -> [String: Double] {
    var orderHints = initialOrderHints(
      normalizedGroups: inputs.normalizedGroups,
      nodesByID: nodesByID,
      edges: inputs.acyclicNodeEdges
    )
    let acyclicGraph = PolicyCanvasLayoutGraph(
      nodes: inputs.graph.nodes,
      edges: inputs.acyclicNodeEdges,
      groups: inputs.graph.groups
    )
    let incomingContext = PolicyCanvasBarycenterContext(
      graph: acyclicGraph,
      layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
      preferIncomingNeighbors: true
    )
    let outgoingContext = PolicyCanvasBarycenterContext(
      graph: acyclicGraph,
      layoutGroupIDByNodeID: inputs.layoutGroupIDByNodeID,
      preferIncomingNeighbors: false
    )
    for _ in 0..<inputs.configuration.sweepPassCount {
      sweepOrderHints(
        groups: groupOrder,
        context: incomingContext,
        internalRanks: inputs.internalRanks,
        orderHints: &orderHints
      )
      sweepOrderHints(
        groups: groupOrder.reversed(),
        context: outgoingContext,
        internalRanks: inputs.internalRanks,
        orderHints: &orderHints
      )
    }
    return orderHints
  }

  func placeAnchoredGroup(
    group: PolicyCanvasNormalizedLayoutGroup,
    context: PolicyCanvasAnchoredGroupContext,
    accumulator: inout PolicyCanvasAnchoredPlacement
  ) {
    let memberIDs = group.nodeIDs.filter { context.nodesByID[$0] != nil }
    guard !memberIDs.isEmpty else {
      return
    }

    let anchoredMembers = memberIDs.filter { context.anchoredNodeIDs.contains($0) }
    if !anchoredMembers.isEmpty {
      accumulator.anchoredGroupIDs.insert(group.layoutID)
    }
    let anchoredFrames = anchoredMembers.compactMap { nodeID -> CGRect? in
      guard let anchor = context.nodesByID[nodeID]?.anchor else {
        return nil
      }
      let position = snappedLayoutPoint(anchor.position)
      accumulator.nodePositions[nodeID] = position
      return CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
    }

    let groupOrigin = CGPoint(
      x: anchoredMembers.compactMap { context.nodesByID[$0]?.anchor?.position.x }.min()
        .map { $0 - PolicyCanvasLayout.groupHorizontalPadding } ?? accumulator.nextAutoGroupMinX,
      y: anchoredMembers.compactMap { context.nodesByID[$0]?.anchor?.position.y }.min()
        .map { $0 - PolicyCanvasLayout.groupVerticalPadding } ?? 0
    )
    let freeMembers = orderedFreeMembers(
      in: group,
      anchoredNodeIDs: context.anchoredNodeIDs,
      internalRanks: context.internalRanks,
      orderHints: context.orderHints
    )
    let placement = placeFreeMembers(
      freeMembers,
      internalRanks: context.internalRanks,
      groupOrigin: groupOrigin,
      reservedFrames: anchoredFrames,
      configuration: context.configuration
    )
    accumulator.nodePositions.merge(placement.positions) { _, new in new }
    accumulator.autoPlacedNodeIDs.formUnion(freeMembers)

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
      placementFrame.maxX + context.configuration.interGroupSpacing
    )
  }

  func compositeBaseRanks(
    macroRanks: [Int],
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    groupRanks: [String: Int],
    maxInternalRankByGroup: [String: Int]
  ) -> [Int: Int] {
    var baseRanks: [Int: Int] = [:]
    var nextBaseRank = 0
    for macroRank in macroRanks {
      baseRanks[macroRank] = nextBaseRank
      let layerColumnCount = normalizedGroups.reduce(into: 1) { partial, group in
        guard groupRanks[group.layoutID] == macroRank else {
          return
        }
        partial = max(partial, (maxInternalRankByGroup[group.layoutID] ?? 0) + 1)
      }
      nextBaseRank += layerColumnCount
    }
    return baseRanks
  }

  func layerBaseXByMacroRank(
    macroRanks: [Int],
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    groupRanks: [String: Int],
    maxInternalRankByGroup: [String: Int],
    configuration: PolicyCanvasLayoutConfiguration
  ) -> [Int: CGFloat] {
    var baseXByMacroRank: [Int: CGFloat] = [:]
    var nextBaseX: CGFloat = 0
    for macroRank in macroRanks {
      baseXByMacroRank[macroRank] = nextBaseX
      let initialLayerWidth = CGFloat(PolicyCanvasLayout.nodeSize.width)
      let layerWidth = normalizedGroups.reduce(into: initialLayerWidth) { partial, group in
        guard groupRanks[group.layoutID] == macroRank else {
          return
        }
        let contentWidth =
          CGFloat(maxInternalRankByGroup[group.layoutID] ?? 0) * configuration.columnStep
          + PolicyCanvasLayout.nodeSize.width
        let width: CGFloat
        if group.actualGroupID == nil {
          width = contentWidth
        } else {
          width = max(
            contentWidth + (PolicyCanvasLayout.groupHorizontalPadding * 2),
            PolicyCanvasLayout.minimumGroupSize.width
          )
        }
        partial = max(partial, width)
      }
      nextBaseX += layerWidth + configuration.interGroupSpacing
    }
    return baseXByMacroRank
  }

  func anchoredMinXByGroup(
    nodesByID: [String: PolicyCanvasLayoutNode],
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup]
  ) -> [String: CGFloat] {
    Dictionary(
      uniqueKeysWithValues: normalizedGroups.compactMap { group in
        let anchoredMinX = group.nodeIDs.compactMap { nodeID in
          nodesByID[nodeID]?.anchor?.position.x
        }.min()
        guard let anchoredMinX else {
          return nil
        }
        return (group.layoutID, anchoredMinX)
      })
  }

  func orderedGroups(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    groupRanks: [String: Int],
    anchoredMinXByGroup: [String: CGFloat],
    groupCenterY: [String: CGFloat] = [:]
  ) -> [PolicyCanvasNormalizedLayoutGroup] {
    normalizedGroups.sorted { left, right in
      let leftRank = groupRanks[left.layoutID] ?? 0
      let rightRank = groupRanks[right.layoutID] ?? 0
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      if mode.preservesManualAnchors,
        let leftAnchor = anchoredMinXByGroup[left.layoutID],
        let rightAnchor = anchoredMinXByGroup[right.layoutID],
        leftAnchor != rightAnchor
      {
        return leftAnchor < rightAnchor
      }
      if let leftCenterY = groupCenterY[left.layoutID],
        let rightCenterY = groupCenterY[right.layoutID],
        abs(leftCenterY - rightCenterY) >= (PolicyCanvasLayout.gridSize / 2)
      {
        return leftCenterY < rightCenterY
      }
      return left.originalIndex < right.originalIndex
    }
  }

  func groupCenterY(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    itemCenterY: [String: CGFloat]
  ) -> [String: CGFloat] {
    normalizedGroups.reduce(into: [:]) { partial, group in
      let centers = group.nodeIDs.compactMap { itemCenterY[$0] }.sorted()
      guard !centers.isEmpty else {
        return
      }
      partial[group.layoutID] = centers[centers.count / 2]
    }
  }

  func groupBarycenterY(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    layoutGroupIDByNodeID: [String: String],
    edges: [PolicyCanvasLayoutEdge],
    itemCenterY: [String: CGFloat]
  ) -> [String: CGFloat] {
    let fallbackCenterY = groupCenterY(
      normalizedGroups: normalizedGroups,
      itemCenterY: itemCenterY
    )
    return normalizedGroups.reduce(into: [:]) { partial, group in
      let neighborCenters = edges.compactMap { edge -> CGFloat? in
        let sourceGroupID = layoutGroupIDByNodeID[edge.sourceNodeID]
        let targetGroupID = layoutGroupIDByNodeID[edge.targetNodeID]
        guard sourceGroupID != targetGroupID else {
          return nil
        }
        if targetGroupID == group.layoutID, let sourceGroupID {
          return itemCenterY[edge.sourceNodeID] ?? fallbackCenterY[sourceGroupID]
        }
        if sourceGroupID == group.layoutID, let targetGroupID {
          return itemCenterY[edge.targetNodeID] ?? fallbackCenterY[targetGroupID]
        }
        return nil
      }
      guard !neighborCenters.isEmpty else {
        partial[group.layoutID] = fallbackCenterY[group.layoutID]
        return
      }
      partial[group.layoutID] =
        neighborCenters.reduce(CGFloat.zero, +) / CGFloat(neighborCenters.count)
    }
  }

  func groupRanks(
    for groups: [PolicyCanvasNormalizedLayoutGroup],
    edges: [PolicyCanvasLayoutEdge],
    layoutGroupIDByNodeID: [String: String]
  ) -> [String: Int] {
    longestPathRanks(
      ids: groups.map(\.layoutID),
      originalOrder: Dictionary(
        uniqueKeysWithValues: groups.map { ($0.layoutID, $0.originalIndex) }),
      successors: interGroupSuccessors(
        edges: edges,
        layoutGroupIDByNodeID: layoutGroupIDByNodeID
      )
    )
  }

  func internalRanks(
    for groups: [PolicyCanvasNormalizedLayoutGroup],
    edges: [PolicyCanvasLayoutEdge],
    layoutGroupIDByNodeID: [String: String]
  ) -> [String: Int] {
    groups.reduce(into: [:]) { partial, group in
      let intraGroupEdges = edges.compactMap { edge -> (String, String)? in
        guard
          layoutGroupIDByNodeID[edge.sourceNodeID] == group.layoutID,
          layoutGroupIDByNodeID[edge.targetNodeID] == group.layoutID
        else {
          return nil
        }
        return (edge.sourceNodeID, edge.targetNodeID)
      }
      let ranks = longestPathRanks(
        ids: group.nodeIDs,
        originalOrder: Dictionary(
          uniqueKeysWithValues: group.nodeIDs.enumerated().map { ($1, $0) }),
        successors: intraGroupEdges.reduce(into: [:]) { successors, edge in
          successors[edge.0, default: []].insert(edge.1)
        }
      )
      partial.merge(ranks) { _, new in new }
    }
  }

  func interGroupSuccessors(
    edges: [PolicyCanvasLayoutEdge],
    layoutGroupIDByNodeID: [String: String]
  ) -> [String: Set<String>] {
    edges.reduce(into: [:]) { partial, edge in
      guard
        let sourceGroupID = layoutGroupIDByNodeID[edge.sourceNodeID],
        let targetGroupID = layoutGroupIDByNodeID[edge.targetNodeID],
        sourceGroupID != targetGroupID
      else {
        return
      }
      partial[sourceGroupID, default: []].insert(targetGroupID)
    }
  }

}
