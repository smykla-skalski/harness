import CoreGraphics

private struct PolicyCanvasLabeledEdge {
  let edgeID: String
  let frame: CGRect
  let position: CGPoint
  let route: PolicyCanvasEdgeRoute
  let endpoints: Set<String>
}

/// Measure label problems: two labels overlapping, a label sitting on a foreign
/// node body, and a label drifted far from its own wire. Label frames are
/// estimated from text length capped at the layout's max label width, so the
/// overlap test errs toward the rendered size rather than overstating it.
func policyCanvasMeasureLabels(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasLabelViolation] {
  let labeled =
    routedEdges
    .compactMap { routed -> PolicyCanvasLabeledEdge? in
      let text = routed.edge.label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        return nil
      }
      return PolicyCanvasLabeledEdge(
        edgeID: routed.edge.id,
        frame: policyCanvasLabelFrame(text: text, center: routed.route.labelPosition),
        position: routed.route.labelPosition,
        route: routed.route,
        endpoints: [routed.edge.source.nodeID, routed.edge.target.nodeID]
      )
    }
    .sorted { $0.edgeID < $1.edgeID }
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
          frame: lhs.frame.intersection(rhs.frame),
          distance: 0
        )
      )
    }
  }
  let sortedNodes = nodeFramesByID.sorted { $0.key < $1.key }
  for item in labeled {
    for (nodeID, frame) in sortedNodes where !item.endpoints.contains(nodeID) {
      guard item.frame.intersects(frame) else {
        continue
      }
      violations.append(
        PolicyCanvasLabelViolation(
          kind: .onBody,
          edgeID: item.edgeID,
          otherID: nodeID,
          frame: item.frame.intersection(frame),
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
  }
  return violations.sorted(by: policyCanvasLabelViolationOrder)
}

private func policyCanvasLabelFrame(text: String, center: CGPoint) -> CGRect {
  let width = min(max(24, CGFloat(text.count) * 7 + 16), PolicyCanvasLayout.edgeLabelMaxWidth)
  let height = PolicyCanvasLayout.edgeLabelHeight
  return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
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
