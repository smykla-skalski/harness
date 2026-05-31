import Foundation
import SwiftUI

// Within-group ordering seeds, barycenter sweeps, free-member placement, and
// the post-placement vertical balancing pass.
extension PolicyCanvasLayeredLayoutEngine {
  func initialOrderHints(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    nodesByID: [String: PolicyCanvasLayoutNode],
    edges: [PolicyCanvasLayoutEdge]
  ) -> [String: Double] {
    normalizedGroups.reduce(into: [:]) { partial, group in
      let orderedMembers = group.nodeIDs.sorted { leftID, rightID in
        guard let left = nodesByID[leftID], let right = nodesByID[rightID] else {
          return leftID < rightID
        }
        let leftSeed = initialOrderSeed(for: left, nodesByID: nodesByID, edges: edges)
        let rightSeed = initialOrderSeed(for: right, nodesByID: nodesByID, edges: edges)
        if leftSeed.priority != rightSeed.priority {
          return leftSeed.priority < rightSeed.priority
        }
        if leftSeed.y != rightSeed.y {
          return leftSeed.y < rightSeed.y
        }
        if leftSeed.x != rightSeed.x {
          return leftSeed.x < rightSeed.x
        }
        return left.originalIndex < right.originalIndex
      }
      for (index, nodeID) in orderedMembers.enumerated() {
        partial[nodeID] = Double(index)
      }
    }
  }

  func initialOrderSeed(
    for node: PolicyCanvasLayoutNode,
    nodesByID: [String: PolicyCanvasLayoutNode],
    edges: [PolicyCanvasLayoutEdge]
  ) -> PolicyCanvasOrderSeed {
    if let anchor = node.anchor {
      return PolicyCanvasOrderSeed(priority: 0, y: anchor.position.y, x: anchor.position.x)
    }
    switch mode.orderSeedStrategy {
    case .neighborBarycenter:
      let seedY =
        policyCanvasEdgeAwareSeedY(
          for: node.id,
          nodesByID: nodesByID,
          edges: edges
        ) ?? node.currentPosition.y
      return PolicyCanvasOrderSeed(
        priority: 1,
        y: seedY,
        x: node.currentPosition.x
      )
    case .currentPosition:
      // Keep the node where the user already sees it. `originalIndex` remains
      // the final comparator tiebreak for nodes that share a row exactly.
      return PolicyCanvasOrderSeed(
        priority: 1,
        y: node.currentPosition.y,
        x: node.currentPosition.x
      )
    }
  }

  func sweepOrderHints<G: Collection>(
    groups: G,
    context: PolicyCanvasBarycenterContext,
    internalRanks: [String: Int],
    orderHints: inout [String: Double]
  ) where G.Element == PolicyCanvasNormalizedLayoutGroup {
    for group in groups {
      let orderedNodeIDs = group.nodeIDs.sorted { leftID, rightID in
        let leftRank = internalRanks[leftID] ?? 0
        let rightRank = internalRanks[rightID] ?? 0
        if leftRank != rightRank {
          return leftRank < rightRank
        }
        let leftScore = barycenter(
          nodeID: leftID,
          groupID: group.layoutID,
          context: context,
          orderHints: orderHints
        )
        let rightScore = barycenter(
          nodeID: rightID,
          groupID: group.layoutID,
          context: context,
          orderHints: orderHints
        )
        if leftScore != rightScore {
          return leftScore < rightScore
        }
        return (orderHints[leftID] ?? .zero) < (orderHints[rightID] ?? .zero)
      }
      for (index, nodeID) in orderedNodeIDs.enumerated() {
        orderHints[nodeID] = Double(index)
      }
    }
  }

  func barycenter(
    nodeID: String,
    groupID: String,
    context: PolicyCanvasBarycenterContext,
    orderHints: [String: Double]
  ) -> Double {
    let preferIncomingNeighbors = context.preferIncomingNeighbors
    let layoutGroupIDByNodeID = context.layoutGroupIDByNodeID
    let externalPreferredNeighbors = context.graph.edges.compactMap { edge -> Double? in
      if preferIncomingNeighbors,
        edge.targetNodeID == nodeID,
        layoutGroupIDByNodeID[edge.sourceNodeID] != groupID
      {
        return orderHints[edge.sourceNodeID]
      }
      if !preferIncomingNeighbors,
        edge.sourceNodeID == nodeID,
        layoutGroupIDByNodeID[edge.targetNodeID] != groupID
      {
        return orderHints[edge.targetNodeID]
      }
      return nil
    }
    let internalPreferredNeighbors = context.graph.edges.compactMap { edge -> Double? in
      if preferIncomingNeighbors,
        edge.targetNodeID == nodeID,
        layoutGroupIDByNodeID[edge.sourceNodeID] == groupID
      {
        return orderHints[edge.sourceNodeID]
      }
      if !preferIncomingNeighbors,
        edge.sourceNodeID == nodeID,
        layoutGroupIDByNodeID[edge.targetNodeID] == groupID
      {
        return orderHints[edge.targetNodeID]
      }
      return nil
    }
    let preferredNeighbors = externalPreferredNeighbors + internalPreferredNeighbors
    if !preferredNeighbors.isEmpty {
      return preferredNeighbors.reduce(0, +) / Double(preferredNeighbors.count)
    }
    return orderHints[nodeID] ?? .zero
  }

  func orderedFreeMembers(
    in group: PolicyCanvasNormalizedLayoutGroup,
    anchoredNodeIDs: Set<String>,
    internalRanks: [String: Int],
    orderHints: [String: Double]
  ) -> [String] {
    group.nodeIDs
      .filter { !anchoredNodeIDs.contains($0) }
      .sorted { leftID, rightID in
        let leftRank = internalRanks[leftID] ?? 0
        let rightRank = internalRanks[rightID] ?? 0
        if leftRank != rightRank {
          return leftRank < rightRank
        }
        return (orderHints[leftID] ?? .zero) < (orderHints[rightID] ?? .zero)
      }
  }

  func placeFreeMembers(
    _ nodeIDs: [String],
    internalRanks: [String: Int],
    groupOrigin: CGPoint,
    reservedFrames: [CGRect],
    configuration: PolicyCanvasLayoutConfiguration,
    verticalHints: [String: CGFloat] = [:],
    edges: [PolicyCanvasLayoutEdge] = []
  ) -> (positions: [String: CGPoint], frames: [CGRect]) {
    guard !nodeIDs.isEmpty else {
      return ([:], reservedFrames)
    }
    var positions: [String: CGPoint] = [:]
    var occupiedFrames = reservedFrames
    let ranks = Set(nodeIDs.map { internalRanks[$0] ?? 0 }).sorted()
    let memberSet = Set(nodeIDs)
    let labelMetrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)

    // Horizontal gap from one rank to the next: the widest label crossing that
    // boundary plus one port turn-lead on each side, so the edge can leave its
    // source port, carry the label in the clear, and enter the target port
    // without folding into a jog. A short label ("green") gets a tight gap, a
    // long one ("changes requested") keeps its room, and the label is never
    // squeezed onto a lead. A bare turn-lead pair is the unlabeled minimum. With
    // no edges supplied (the anchored path) it falls back to the configured
    // column spacing unchanged.
    func interRankGap(after rank: Int, before nextRank: Int) -> CGFloat {
      guard !edges.isEmpty else {
        return configuration.columnSpacing
      }
      let leadPair = 2 * PolicyCanvasLayout.edgePortTurnMinimumLead
      let widths = edges.compactMap { edge -> CGFloat? in
        guard
          memberSet.contains(edge.sourceNodeID), memberSet.contains(edge.targetNodeID),
          (internalRanks[edge.sourceNodeID] ?? 0) == rank,
          (internalRanks[edge.targetNodeID] ?? 0) == nextRank,
          !edge.label.isEmpty
        else {
          return nil
        }
        return labelMetrics.size(for: edge.label).width + leadPair
      }
      return max(leadPair, widths.max() ?? leadPair)
    }

    var cursorX = groupOrigin.x + PolicyCanvasLayout.groupHorizontalPadding
    for (rankIndex, rank) in ranks.enumerated() {
      let bucket = nodeIDs.filter { (internalRanks[$0] ?? 0) == rank }
      guard !bucket.isEmpty else {
        continue
      }
      let baseColumnCount = preferredColumnCount(
        memberCount: bucket.count,
        configuration: configuration
      )
      let hintValues = bucket.compactMap { verticalHints[$0] }
      let verticalHintSpread = (hintValues.max() ?? .zero) - (hintValues.min() ?? .zero)
      let columnCount =
        verticalHintSpread >= (configuration.rowStep * 3)
        ? max(1, baseColumnCount - 1)
        : baseColumnCount
      for (index, nodeID) in bucket.enumerated() {
        let subcolumn = index % columnCount
        var row = index / columnCount
        while true {
          let position = snappedLayoutPoint(
            CGPoint(
              x: cursorX + (CGFloat(subcolumn) * configuration.columnStep),
              y: groupOrigin.y + PolicyCanvasLayout.groupVerticalPadding
                + (CGFloat(row) * configuration.rowStep)
            )
          )
          let frame = CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
          if occupiedFrames.allSatisfy({ !$0.intersects(frame) }) {
            positions[nodeID] = position
            occupiedFrames.append(frame)
            break
          }
          row += 1
        }
      }
      let rankSpan =
        (CGFloat(max(0, columnCount - 1)) * configuration.columnStep)
        + PolicyCanvasLayout.nodeSize.width
      if rankIndex < ranks.count - 1 {
        cursorX += rankSpan + interRankGap(after: rank, before: ranks[rankIndex + 1])
      }
    }

    return (positions, occupiedFrames)
  }

  func preferredColumnCount(
    memberCount: Int,
    configuration: PolicyCanvasLayoutConfiguration
  ) -> Int {
    guard memberCount > 2 else {
      return 1
    }

    let aspectScale =
      (configuration.targetGroupAspectRatio * configuration.rowStep)
      / max(configuration.columnStep, 1)
    let rawColumns = sqrt(CGFloat(memberCount) * max(aspectScale, 0.5))
    return min(max(Int(rawColumns.rounded(.down)), 1), memberCount)
  }

  func balanceGroupVerticalPositions(
    groups: [PolicyCanvasNormalizedLayoutGroup],
    context: PolicyCanvasVerticalBalanceContext,
    accumulator: inout PolicyCanvasAnchoredPlacement
  ) {
    guard groups.count > 1 else {
      return
    }
    let maximumBalancedGroupHeight =
      PolicyCanvasLayout.minimumGroupSize.height + context.configuration.rowStep
    for _ in 0..<3 {
      var movedAny = false
      for group in groups {
        let didMove = balanceSingleGroupVertically(
          group: group,
          context: context,
          maximumBalancedGroupHeight: maximumBalancedGroupHeight,
          accumulator: &accumulator
        )
        movedAny = movedAny || didMove
      }
      if !movedAny {
        break
      }
    }
  }

  func balanceSingleGroupVertically(
    group: PolicyCanvasNormalizedLayoutGroup,
    context: PolicyCanvasVerticalBalanceContext,
    maximumBalancedGroupHeight: CGFloat,
    accumulator: inout PolicyCanvasAnchoredPlacement
  ) -> Bool {
    guard
      !context.anchoredGroupIDs.contains(group.layoutID),
      let groupFrame = accumulator.groupFramesByLayoutID[group.layoutID],
      groupFrame.height <= maximumBalancedGroupHeight,
      intraGroupEdgeCount(
        for: group.layoutID,
        graph: context.graph,
        layoutGroupIDByNodeID: context.layoutGroupIDByNodeID
      ) == 0
    else {
      return false
    }
    let endpointDeltas = balanceEndpointDeltas(
      group: group,
      context: context,
      nodePositions: accumulator.nodePositions
    )
    guard !endpointDeltas.isEmpty else {
      return false
    }
    let averageDelta = endpointDeltas.reduce(0, +) / CGFloat(endpointDeltas.count)
    let maxShiftPerPass = context.configuration.rowStep * 1.5
    var shiftY = snappedLayoutDelta(averageDelta * 0.5)
    shiftY = max(-maxShiftPerPass, min(maxShiftPerPass, shiftY))
    if groupFrame.minY + shiftY < 0 {
      shiftY = snappedLayoutDelta(-groupFrame.minY)
    }
    guard abs(shiftY) >= (PolicyCanvasLayout.gridSize / 2) else {
      return false
    }
    for nodeID in group.nodeIDs {
      guard var position = accumulator.nodePositions[nodeID] else {
        continue
      }
      position.y += shiftY
      accumulator.nodePositions[nodeID] = position
    }
    let nextFrame = groupFrame.offsetBy(dx: 0, dy: shiftY)
    accumulator.groupFramesByLayoutID[group.layoutID] = nextFrame
    if let actualGroupID = group.actualGroupID {
      accumulator.groupFrames[actualGroupID] = nextFrame
    }
    return true
  }

  func balanceEndpointDeltas(
    group: PolicyCanvasNormalizedLayoutGroup,
    context: PolicyCanvasVerticalBalanceContext,
    nodePositions: [String: CGPoint]
  ) -> [CGFloat] {
    context.graph.edges.compactMap { edge -> CGFloat? in
      guard
        let sourceGroupID = context.layoutGroupIDByNodeID[edge.sourceNodeID],
        let targetGroupID = context.layoutGroupIDByNodeID[edge.targetNodeID],
        sourceGroupID != targetGroupID,
        let sourcePosition = nodePositions[edge.sourceNodeID],
        let targetPosition = nodePositions[edge.targetNodeID]
      else {
        return nil
      }
      let sourceCenterY = sourcePosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
      let targetCenterY = targetPosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
      if sourceGroupID == group.layoutID {
        return targetCenterY - sourceCenterY
      }
      if targetGroupID == group.layoutID {
        return sourceCenterY - targetCenterY
      }
      return nil
    }
  }

  func crossGroupOrderViolations(
    graph: PolicyCanvasLayoutGraph,
    groupRanks: [String: Int],
    layoutGroupIDByNodeID: [String: String]
  ) -> Int {
    graph.edges.reduce(into: 0) { partial, edge in
      guard
        let sourceGroupID = layoutGroupIDByNodeID[edge.sourceNodeID],
        let targetGroupID = layoutGroupIDByNodeID[edge.targetNodeID],
        sourceGroupID != targetGroupID,
        let sourceRank = groupRanks[sourceGroupID],
        let targetRank = groupRanks[targetGroupID],
        sourceRank > targetRank
      else {
        return
      }
      partial += 1
    }
  }

  func intraGroupEdgeCount(
    for groupID: String,
    graph: PolicyCanvasLayoutGraph,
    layoutGroupIDByNodeID: [String: String]
  ) -> Int {
    graph.edges.reduce(into: 0) { count, edge in
      guard
        layoutGroupIDByNodeID[edge.sourceNodeID] == groupID,
        layoutGroupIDByNodeID[edge.targetNodeID] == groupID
      else {
        return
      }
      count += 1
    }
  }
}
