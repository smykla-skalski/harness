import CoreGraphics

private struct PolicyCanvasLabeledEdge {
  let edgeID: String
  let frame: CGRect
  let position: CGPoint
  let route: PolicyCanvasEdgeRoute
  let endpoints: Set<String>
}

/// Measure label problems: two labels overlapping, a label sitting on a foreign
/// node body, and a label drifted far from its own wire. Label frames come from
/// the same `PolicyCanvasEdgeLabelMetrics` the router and renderer use, so the
/// measured box matches the one drawn on screen instead of a taller, wider
/// estimate that fabricates overlaps in the gaps between separated labels. The
/// label center is resolved the same way the renderer resolves it -
/// `labelPositions[edgeID]` when the placement pass moved the label off its route
/// midpoint, else the route midpoint - so the measured box sits over the label as
/// drawn, not at a stale midpoint.
func policyCanvasMeasureLabels(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect],
  labelPositions: [String: CGPoint],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasLabelViolation] {
  let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
  let labeled =
    routedEdges
    .compactMap { routed -> PolicyCanvasLabeledEdge? in
      let text = routed.edge.label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        return nil
      }
      let center = labelPositions[routed.edge.id] ?? routed.route.labelPosition
      return PolicyCanvasLabeledEdge(
        edgeID: routed.edge.id,
        frame: metrics.frame(for: text, center: center),
        position: center,
        route: routed.route,
        endpoints: [routed.edge.source.nodeID, routed.edge.target.nodeID]
      )
    }
    .sorted { $0.edgeID < $1.edgeID }
  let sortedNodes = nodeFramesByID.sorted { $0.key < $1.key }
  // Turn points per edge, computed once: the label-near-turn pass compares every
  // label box against every wire's bends, its own included.
  let turnsByEdge =
    routedEdges
    .map { (edgeID: $0.edge.id, turns: policyCanvasRouteTurnPoints($0.route)) }
  var violations = policyCanvasLabelOverlapViolations(labeled: labeled)
  for item in labeled {
    violations.append(
      contentsOf: policyCanvasLabelPlacementViolations(
        item: item,
        routedEdges: routedEdges,
        sortedNodes: sortedNodes,
        turnsByEdge: turnsByEdge,
        thresholds: thresholds
      )
    )
  }
  return violations.sorted(by: policyCanvasLabelViolationOrder)
}

/// Pairwise label-box overlaps, walked in sorted order so each clashing pair is
/// reported once.
private func policyCanvasLabelOverlapViolations(
  labeled: [PolicyCanvasLabeledEdge]
) -> [PolicyCanvasLabelViolation] {
  var violations: [PolicyCanvasLabelViolation] = []
  for leftIndex in labeled.indices {
    for rightIndex in labeled.index(after: leftIndex)..<labeled.endIndex {
      let lhs = labeled[leftIndex]
      let rhs = labeled[rightIndex]
      guard lhs.frame.intersects(rhs.frame) else {
        continue
      }
      violations.append(
        PolicyCanvasLabelViolation(
          kind: .overlap,
          edgeID: lhs.edgeID,
          otherID: rhs.edgeID,
          frame: lhs.frame.union(rhs.frame),
          distance: 0
        )
      )
    }
  }
  return violations
}

/// The on-body, drift, foreign-edge, and near-turn checks for a single label,
/// appended in that fixed order (the caller re-sorts the combined set).
private func policyCanvasLabelPlacementViolations(
  item: PolicyCanvasLabeledEdge,
  routedEdges: [PolicyCanvasRoutedEdge],
  sortedNodes: [(key: String, value: CGRect)],
  turnsByEdge: [(edgeID: String, turns: [CGPoint])],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasLabelViolation] {
  var violations: [PolicyCanvasLabelViolation] = []
  for (nodeID, frame) in sortedNodes where !item.endpoints.contains(nodeID) {
    guard item.frame.intersects(frame) else {
      continue
    }
    violations.append(
      PolicyCanvasLabelViolation(
        kind: .onBody,
        edgeID: item.edgeID,
        otherID: nodeID,
        frame: item.frame,
        distance: 0
      )
    )
  }
  let distance = policyCanvasPointToRouteDistance(item.position, route: item.route)
  if distance > thresholds.labelFarDistance {
    violations.append(
      PolicyCanvasLabelViolation(
        kind: .farFromEdge,
        edgeID: item.edgeID,
        otherID: nil,
        frame: item.frame,
        distance: distance
      )
    )
  }
  // The label box laid over a wire that is not the one it names. The label's
  // own route runs through its box by design, so only foreign routes count.
  for routed in routedEdges where routed.edge.id != item.edgeID {
    guard policyCanvasRouteIntersectsObstacles(routed.route, obstacles: [item.frame]) else {
      continue
    }
    violations.append(
      PolicyCanvasLabelViolation(
        kind: .crossesEdge,
        edgeID: item.edgeID,
        otherID: routed.edge.id,
        frame: item.frame,
        distance: 0
      )
    )
  }
  // The label box overlapping or crowding a bend - one hit per crowding edge,
  // at its nearest qualifying turn.
  for entry in turnsByEdge {
    let nearest = entry.turns.reduce(CGFloat.greatestFiniteMagnitude) { best, turn in
      min(best, policyCanvasPointToRectGap(turn, item.frame))
    }
    guard nearest <= thresholds.labelTurnClearance else {
      continue
    }
    violations.append(
      PolicyCanvasLabelViolation(
        kind: .nearTurn,
        edgeID: item.edgeID,
        otherID: entry.edgeID,
        frame: item.frame,
        distance: nearest
      )
    )
  }
  return violations
}

/// Interior vertices where a route changes direction - the visible corners. A
/// vertex counts when the step direction of the segment arriving at it differs
/// from the segment leaving it (a 90-degree bend or a reversal). Collinear runs
/// produce no turn.
private func policyCanvasRouteTurnPoints(_ route: PolicyCanvasEdgeRoute) -> [CGPoint] {
  let segments = policyCanvasRouteSegments(route)
  guard segments.count >= 2 else {
    return []
  }
  var turns: [CGPoint] = []
  for index in 1..<segments.count
  where policyCanvasSegmentDirection(segments[index - 1])
    != policyCanvasSegmentDirection(segments[index])
  {
    turns.append(segments[index - 1].end)
  }
  return turns
}

private func policyCanvasSegmentDirection(_ segment: PolicyCanvasRouteSegment) -> (Int, Int) {
  func unit(_ value: CGFloat) -> Int {
    value > 0.001 ? 1 : (value < -0.001 ? -1 : 0)
  }
  return (unit(segment.end.x - segment.start.x), unit(segment.end.y - segment.start.y))
}

/// Shortest distance from a point to a rectangle, zero when the point is inside.
private func policyCanvasPointToRectGap(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
  let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
  let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
  return hypot(dx, dy)
}

private func policyCanvasPointToRouteDistance(
  _ point: CGPoint,
  route: PolicyCanvasEdgeRoute
) -> CGFloat {
  let segments = policyCanvasRouteSegments(route)
  guard !segments.isEmpty else {
    return 0
  }
  var best = CGFloat.greatestFiniteMagnitude
  for segment in segments {
    best = min(best, policyCanvasPointToSegmentDistance(point, segment.start, segment.end))
  }
  return best == .greatestFiniteMagnitude ? 0 : best
}

private func policyCanvasPointToSegmentDistance(
  _ point: CGPoint,
  _ start: CGPoint,
  _ end: CGPoint
) -> CGFloat {
  let clamped = CGPoint(
    x: min(max(point.x, min(start.x, end.x)), max(start.x, end.x)),
    y: min(max(point.y, min(start.y, end.y)), max(start.y, end.y))
  )
  return hypot(point.x - clamped.x, point.y - clamped.y)
}

private func policyCanvasLabelViolationOrder(
  _ lhs: PolicyCanvasLabelViolation,
  _ rhs: PolicyCanvasLabelViolation
) -> Bool {
  if lhs.kind != rhs.kind {
    return lhs.kind.rawValue < rhs.kind.rawValue
  }
  if lhs.edgeID != rhs.edgeID {
    return lhs.edgeID < rhs.edgeID
  }
  return (lhs.otherID ?? "") < (rhs.otherID ?? "")
}
