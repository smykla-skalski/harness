import CoreGraphics

/// Group title bands paired with their group id, in group order (the title-frame
/// helper is a straight map so the pairing is stable).
func policyCanvasGroupTitleFramesByID(
  _ groups: [PolicyCanvasGroup]
) -> [(id: String, frame: CGRect)] {
  zip(groups, policyCanvasGroupTitleFrames(groups)).map { group, frame in
    (id: group.id, frame: frame)
  }
}

/// Measure routes that run through a node body or a group-title band that is not
/// one of their own endpoints. Reuses the router's own obstacle-intersection
/// test so the metric agrees with what the router was asked to avoid.
func policyCanvasMeasureBodyHits(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect],
  groupTitleFrames: [(id: String, frame: CGRect)]
) -> [PolicyCanvasBodyHitViolation] {
  var violations: [PolicyCanvasBodyHitViolation] = []
  let sortedNodes = nodeFramesByID.sorted { $0.key < $1.key }
  for routed in routedEdges {
    let endpoints: Set<String> = [routed.edge.source.nodeID, routed.edge.target.nodeID]
    for (nodeID, frame) in sortedNodes where !endpoints.contains(nodeID) {
      if policyCanvasRouteIntersectsObstacles(routed.route, obstacles: [frame]) {
        violations.append(
          PolicyCanvasBodyHitViolation(
            edgeID: routed.edge.id,
            obstacle: .node,
            obstacleID: nodeID,
            frame: frame
          )
        )
      }
    }
    for title in groupTitleFrames
    where policyCanvasRouteIntersectsObstacles(routed.route, obstacles: [title.frame]) {
      violations.append(
        PolicyCanvasBodyHitViolation(
          edgeID: routed.edge.id,
          obstacle: .groupTitle,
          obstacleID: title.id,
          frame: title.frame
        )
      )
    }
  }
  return violations.sorted(by: policyCanvasBodyHitViolationOrder)
}

private func policyCanvasBodyHitViolationOrder(
  _ lhs: PolicyCanvasBodyHitViolation,
  _ rhs: PolicyCanvasBodyHitViolation
) -> Bool {
  if lhs.edgeID != rhs.edgeID {
    return lhs.edgeID < rhs.edgeID
  }
  if lhs.obstacle != rhs.obstacle {
    return lhs.obstacle.rawValue < rhs.obstacle.rawValue
  }
  return lhs.obstacleID < rhs.obstacleID
}
