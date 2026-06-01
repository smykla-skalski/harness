import Foundation
import SwiftUI

// Routing-hint synthesis: per-edge corridor lane assignment (horizontal and
// vertical), preferred target bands, and the layout-graph adapter that maps
// canvas nodes/groups/edges into the layered layout input shape.
func policyCanvasLayoutRoutingHints(
  graph: PolicyCanvasLayoutGraph,
  nodePositions: [String: CGPoint],
  layoutGroupIDByNodeID: [String: String],
  groupFramesByLayoutID: [String: CGRect]
) -> PolicyCanvasLayoutRoutingHints? {
  let horizontalLaneCandidates = policyCanvasHorizontalCorridorLaneCandidates(
    nodePositions: nodePositions
  )
  guard !horizontalLaneCandidates.isEmpty else {
    return nil
  }

  var bundleEntries: [PolicyCanvasCorridorBundleEntry] = []
  bundleEntries.reserveCapacity(graph.edges.count)
  for edge in graph.edges {
    guard
      let sourcePosition = nodePositions[edge.sourceNodeID],
      let targetPosition = nodePositions[edge.targetNodeID]
    else {
      continue
    }
    let sourceScopeID = layoutGroupIDByNodeID[edge.sourceNodeID] ?? edge.sourceNodeID
    let targetScopeID = layoutGroupIDByNodeID[edge.targetNodeID] ?? edge.targetNodeID
    let sourceAnchor = CGPoint(
      x: sourcePosition.x + (PolicyCanvasLayout.nodeSize.width / 2),
      y: sourcePosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
    )
    let targetAnchor = CGPoint(
      x: targetPosition.x + (PolicyCanvasLayout.nodeSize.width / 2),
      y: targetPosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
    )
    let desiredLaneY = snappedLayoutDelta((sourceAnchor.y + targetAnchor.y) / 2)
    let preferredBand = policyCanvasPreferredTargetCorridorBand(
      sourceScopeID: sourceScopeID,
      targetScopeID: targetScopeID,
      targetNodeID: edge.targetNodeID,
      nodePositions: nodePositions,
      groupFramesByLayoutID: groupFramesByLayoutID
    )
    let resolvedLane: (index: Int, y: CGFloat)
    if abs(sourceAnchor.y - targetAnchor.y) < 1 {
      // A flat edge - source and target on the same row - runs straight along
      // that row through the inter-node gap. The horizontal corridor candidates
      // are mid-gaps BETWEEN rows, so snapping a flat edge to the nearest one
      // dives the wire down into the gap and back up for no reason. Keep it on
      // its own row; the visibility router still detours if a node actually
      // blocks the span. The laneIndex is the row y (matching the band-fallback
      // scheme) so it never collides with the 0-based mid-gap indices.
      resolvedLane = (index: Int(desiredLaneY.rounded()), y: desiredLaneY)
    } else {
      resolvedLane = policyCanvasNearestHorizontalCorridorLane(
        desiredY: desiredLaneY,
        candidates: horizontalLaneCandidates,
        preferredBand: preferredBand
      )
    }
    bundleEntries.append(
      PolicyCanvasCorridorBundleEntry(
        edgeID: edge.id,
        key: PolicyCanvasRouteCorridorKey(
          sourceScopeID: sourceScopeID,
          targetScopeID: targetScopeID,
          targetNodeID: edge.targetNodeID,
          label: edge.label,
          laneIndex: resolvedLane.index
        ),
        baseHorizontalLaneY: resolvedLane.y,
        verticalLaneX: policyCanvasPreferredVerticalCorridorLane(
          endpoints: PolicyCanvasCorridorEdgeEndpoints(
            sourceScopeID: sourceScopeID,
            targetScopeID: targetScopeID,
            sourceNodeID: edge.sourceNodeID,
            targetNodeID: edge.targetNodeID
          ),
          nodePositions: nodePositions,
          groupFramesByLayoutID: groupFramesByLayoutID
        ),
        targetNodeID: edge.targetNodeID,
        targetBand: preferredBand,
        stableTiebreak: policyCanvasCorridorBundleTiebreak(
          sourceAnchor: sourceAnchor,
          targetAnchor: targetAnchor,
          sourceNodeID: edge.sourceNodeID,
          targetNodeID: edge.targetNodeID,
          edgeID: edge.id
        )
      )
    )
  }
  let edgeHints = policyCanvasAssignCorridorBundleHints(entries: bundleEntries)
  guard !edgeHints.isEmpty else {
    return nil
  }
  return PolicyCanvasLayoutRoutingHints(edgeHints: edgeHints)
}

func policyCanvasHorizontalCorridorLaneCandidates(
  nodePositions: [String: CGPoint]
) -> [(index: Int, y: CGFloat)] {
  let nodeCenterYs = Set(
    nodePositions.values.map { position in
      snappedLayoutDelta(position.y + (PolicyCanvasLayout.nodeSize.height / 2))
    }
  ).sorted()
  guard !nodeCenterYs.isEmpty else {
    return []
  }
  // Clearance pad so lanes don't run through node bodies. Half the node
  // height plus one grid step lands the lane safely outside the node's
  // vertical extent.
  let clearance = (PolicyCanvasLayout.nodeSize.height / 2) + PolicyCanvasLayout.gridSize

  var lanes: [CGFloat] = []
  if nodeCenterYs.count == 1, let only = nodeCenterYs.first {
    // Single node: route above or below it, never through it.
    lanes = [
      snappedLayoutDelta(only - clearance),
      snappedLayoutDelta(only + clearance),
    ]
  } else {
    for (upper, lower) in zip(nodeCenterYs, nodeCenterYs.dropFirst()) {
      guard lower - upper > PolicyCanvasLayout.nodeSize.height / 2 else {
        continue
      }
      lanes.append(snappedLayoutDelta((upper + lower) / 2))
    }
    if lanes.isEmpty, let top = nodeCenterYs.first, let bottom = nodeCenterYs.last {
      // Cluster too tight for any mid-gap lane. Earlier code fell back to
      // the node centers themselves, which routed edges through node
      // bodies. Offer outside-the-cluster lanes instead so routes go
      // around the cluster rather than through it.
      lanes = [
        snappedLayoutDelta(top - clearance),
        snappedLayoutDelta(bottom + clearance),
      ]
    }
  }
  return Array(lanes.enumerated()).map { (index: $0.offset, y: $0.element) }
}

private func policyCanvasPreferredTargetCorridorBand(
  sourceScopeID: String,
  targetScopeID: String,
  targetNodeID: String,
  nodePositions: [String: CGPoint],
  groupFramesByLayoutID: [String: CGRect]
) -> ClosedRange<CGFloat>? {
  guard sourceScopeID != targetScopeID else {
    return nil
  }
  if let targetPosition = nodePositions[targetNodeID] {
    let targetFrame = CGRect(origin: targetPosition, size: PolicyCanvasLayout.nodeSize)
    return (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY
  }
  guard let targetFrame = groupFramesByLayoutID[targetScopeID] else {
    return nil
  }
  return targetFrame.minY...targetFrame.maxY
}

func policyCanvasNearestHorizontalCorridorLane(
  desiredY: CGFloat,
  candidates: [(index: Int, y: CGFloat)],
  preferredBand: ClosedRange<CGFloat>?
) -> (index: Int, y: CGFloat) {
  let preferredCandidates: [(index: Int, y: CGFloat)]
  if let preferredBand {
    let inBand = candidates.filter { preferredBand.contains($0.y) }
    if inBand.isEmpty {
      // No real candidate sits inside the target band. Snap the band centre
      // onto the layout grid, clamp it back inside the band, and derive the
      // laneIndex from that clamped y. The y/index pair is then tied to the
      // band, so two different targets get distinct laneIndex values (the
      // PolicyCanvasRouteCorridorKey identity stays per-target) while the
      // hint y always falls inside the target's band.
      let bandCenter = (preferredBand.lowerBound + preferredBand.upperBound) / 2
      let snappedCenter = snappedLayoutDelta(bandCenter)
      let clampedY = min(max(snappedCenter, preferredBand.lowerBound), preferredBand.upperBound)
      return (index: Int(clampedY.rounded()), y: clampedY)
    }
    preferredCandidates = inBand
  } else {
    preferredCandidates = candidates
  }
  return preferredCandidates.min { left, right in
    let leftDistance = abs(left.y - desiredY)
    let rightDistance = abs(right.y - desiredY)
    if abs(leftDistance - rightDistance) > 0.001 {
      return leftDistance < rightDistance
    }
    return left.index < right.index
  } ?? candidates[0]
}

struct PolicyCanvasCorridorEdgeEndpoints {
  let sourceScopeID: String
  let targetScopeID: String
  let sourceNodeID: String
  let targetNodeID: String
}

private func policyCanvasPreferredVerticalCorridorLane(
  endpoints: PolicyCanvasCorridorEdgeEndpoints,
  nodePositions: [String: CGPoint],
  groupFramesByLayoutID: [String: CGRect]
) -> CGFloat? {
  guard
    let sourceFrame = groupFramesByLayoutID[endpoints.sourceScopeID],
    let targetFrame = groupFramesByLayoutID[endpoints.targetScopeID]
  else {
    return nil
  }
  if sourceFrame.maxX <= targetFrame.minX {
    if let localizedLane = policyCanvasLocalizedVerticalCorridorLane(
      sourceNodeID: endpoints.sourceNodeID,
      targetNodeID: endpoints.targetNodeID,
      sourceScopeFrame: sourceFrame,
      targetScopeFrame: targetFrame,
      nodePositions: nodePositions
    ) {
      return localizedLane
    }
    return snappedLayoutDelta((sourceFrame.maxX + targetFrame.minX) / 2)
  }
  if targetFrame.maxX <= sourceFrame.minX {
    if let localizedLane = policyCanvasLocalizedVerticalCorridorLane(
      sourceNodeID: endpoints.sourceNodeID,
      targetNodeID: endpoints.targetNodeID,
      sourceScopeFrame: sourceFrame,
      targetScopeFrame: targetFrame,
      nodePositions: nodePositions
    ) {
      return localizedLane
    }
    return snappedLayoutDelta((targetFrame.maxX + sourceFrame.minX) / 2)
  }
  return nil
}

private func policyCanvasLocalizedVerticalCorridorLane(
  sourceNodeID: String,
  targetNodeID: String,
  sourceScopeFrame: CGRect,
  targetScopeFrame: CGRect,
  nodePositions: [String: CGPoint]
) -> CGFloat? {
  guard
    let sourcePosition = nodePositions[sourceNodeID],
    let targetPosition = nodePositions[targetNodeID]
  else {
    return nil
  }
  let sourceNodeFrame = CGRect(origin: sourcePosition, size: PolicyCanvasLayout.nodeSize)
  let targetNodeFrame = CGRect(origin: targetPosition, size: PolicyCanvasLayout.nodeSize)
  let verticalDelta = abs(targetNodeFrame.midY - sourceNodeFrame.midY)
  guard verticalDelta >= PolicyCanvasLayout.nodeSize.height else {
    return nil
  }

  if sourceScopeFrame.maxX <= targetScopeFrame.minX {
    let horizontalGap = max(0, targetNodeFrame.minX - sourceNodeFrame.maxX)
    guard horizontalGap > 0, verticalDelta >= horizontalGap * 2 else {
      return nil
    }
    let targetLocalX = max(
      sourceScopeFrame.maxX,
      targetNodeFrame.minX - (PolicyCanvasLayout.gridSize * 2)
    )
    return snappedLayoutDelta(min(targetLocalX, targetNodeFrame.minX))
  }

  if targetScopeFrame.maxX <= sourceScopeFrame.minX {
    let horizontalGap = max(0, sourceNodeFrame.minX - targetNodeFrame.maxX)
    guard horizontalGap > 0, verticalDelta >= horizontalGap * 2 else {
      return nil
    }
    let targetLocalX = min(
      sourceScopeFrame.minX,
      targetNodeFrame.maxX + (PolicyCanvasLayout.gridSize * 2)
    )
    return snappedLayoutDelta(max(targetLocalX, targetNodeFrame.maxX))
  }

  return nil
}

func policyCanvasLayoutGraph(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  mode: PolicyCanvasAutomaticLayoutMode
) -> PolicyCanvasLayoutGraph {
  let layoutNodes = nodes.enumerated().map { index, node in
    let anchor: PolicyCanvasLayoutAnchor?
    if mode.preservesManualAnchors, node.layoutSource == .manual {
      anchor = PolicyCanvasLayoutAnchor(position: node.position)
    } else {
      anchor = nil
    }
    return PolicyCanvasLayoutNode(
      id: node.id,
      groupID: node.groupID,
      originalIndex: index,
      currentPosition: node.position,
      anchor: anchor
    )
  }
  let groupMembership = Dictionary(
    uniqueKeysWithValues: groups.map { group in
      (group.id, nodes.filter { $0.groupID == group.id }.map(\.id))
    }
  )
  let layoutGroups = groups.enumerated().map { index, group in
    PolicyCanvasLayoutGroup(
      id: group.id,
      originalIndex: index,
      memberNodeIDs: groupMembership[group.id] ?? []
    )
  }
  let layoutEdges = edges.map { edge in
    PolicyCanvasLayoutEdge(
      id: edge.id,
      sourceNodeID: edge.source.nodeID,
      targetNodeID: edge.target.nodeID,
      label: edge.label
    )
  }
  return PolicyCanvasLayoutGraph(
    nodes: layoutNodes,
    edges: layoutEdges,
    groups: layoutGroups
  )
}
