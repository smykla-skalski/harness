import CoreGraphics

private struct PolicyCanvasPortMarkerKey: Hashable {
  let nodeID: String
  let portID: String
  let kind: PolicyCanvasPortKind
}

private struct PolicyCanvasResolvedMarker {
  let nodeID: String
  let side: PolicyCanvasPortSide
  let alongAxis: CGFloat
  let point: CGPoint
  let edgeIDs: [String]
}

/// Measure port-marker spacing on every node side. Each route attaches its dot
/// exactly at `route.points.first` (source) / `.last` (target), so grouping
/// those attach points by node side reproduces the visible markers. A side that
/// stacks two markers below the port diameter is an overlap; below the minimum
/// spacing is a too-close warning; an attach point that lands off the node frame
/// is a detached marker.
func policyCanvasMeasurePortSpacing(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasPortSpacingViolation] {
  var sums: [PolicyCanvasPortMarkerKey: (sum: CGPoint, count: Int, edges: [String])] = [:]
  for routed in routedEdges {
    guard let first = routed.route.points.first, let last = routed.route.points.last else {
      continue
    }
    policyCanvasAccumulateMarker(&sums, endpoint: routed.edge.source, point: first, edgeID: routed.edge.id)
    policyCanvasAccumulateMarker(&sums, endpoint: routed.edge.target, point: last, edgeID: routed.edge.id)
  }
  var violations: [PolicyCanvasPortSpacingViolation] = []
  var markersByNodeSide: [String: [PolicyCanvasPortSide: [PolicyCanvasResolvedMarker]]] = [:]
  let tolerance = PolicyCanvasLayout.portDiameter
  for (key, value) in sums {
    let point = CGPoint(
      x: value.sum.x / CGFloat(value.count),
      y: value.sum.y / CGFloat(value.count)
    )
    guard let frame = nodeFramesByID[key.nodeID] else {
      continue
    }
    guard let side = policyCanvasMarkerSide(point: point, frame: frame, tolerance: tolerance) else {
      violations.append(
        PolicyCanvasPortSpacingViolation(
          kind: .detached,
          nodeID: key.nodeID,
          side: key.kind == .input ? .leading : .trailing,
          point: point,
          otherPoint: nil,
          gap: 0,
          edgeIDs: value.edges.sorted()
        )
      )
      continue
    }
    let along: CGFloat = (side == .leading || side == .trailing) ? point.y : point.x
    markersByNodeSide[key.nodeID, default: [:]][side, default: []].append(
      PolicyCanvasResolvedMarker(
        nodeID: key.nodeID,
        side: side,
        alongAxis: along,
        point: point,
        edgeIDs: value.edges.sorted()
      )
    )
  }
  for (_, sideMap) in markersByNodeSide {
    for (_, markers) in sideMap {
      let sorted = markers.sorted { $0.alongAxis < $1.alongAxis }
      guard sorted.count >= 2 else {
        continue
      }
      for index in 1..<sorted.count {
        let lower = sorted[index - 1]
        let upper = sorted[index]
        let gap = upper.alongAxis - lower.alongAxis
        if gap < thresholds.markerOverlap {
          violations.append(policyCanvasPortSpacingPairViolation(.overlap, lower, upper, gap: gap))
        } else if gap < thresholds.minimumPortSpacing {
          violations.append(policyCanvasPortSpacingPairViolation(.tooClose, lower, upper, gap: gap))
        }
      }
    }
  }
  return violations.sorted(by: policyCanvasPortSpacingViolationOrder)
}

private func policyCanvasAccumulateMarker(
  _ sums: inout [PolicyCanvasPortMarkerKey: (sum: CGPoint, count: Int, edges: [String])],
  endpoint: PolicyCanvasPortEndpoint,
  point: CGPoint,
  edgeID: String
) {
  let key = PolicyCanvasPortMarkerKey(
    nodeID: endpoint.nodeID,
    portID: endpoint.portID,
    kind: endpoint.kind
  )
  var entry = sums[key] ?? (sum: .zero, count: 0, edges: [])
  entry.sum.x += point.x
  entry.sum.y += point.y
  entry.count += 1
  entry.edges.append(edgeID)
  sums[key] = entry
}

/// The side of `frame` a marker sits on, or nil when the point is off the node
/// (a detached marker). A point counts as on a side when it is within
/// `tolerance` of that edge and inside the perpendicular extent.
private func policyCanvasMarkerSide(
  point: CGPoint,
  frame: CGRect,
  tolerance: CGFloat
) -> PolicyCanvasPortSide? {
  let withinVertical = point.y >= frame.minY - tolerance && point.y <= frame.maxY + tolerance
  let withinHorizontal = point.x >= frame.minX - tolerance && point.x <= frame.maxX + tolerance
  var best: (side: PolicyCanvasPortSide, distance: CGFloat)?
  func consider(_ side: PolicyCanvasPortSide, _ distance: CGFloat, _ valid: Bool) {
    guard valid, distance <= tolerance else {
      return
    }
    if best == nil || distance < best!.distance {
      best = (side, distance)
    }
  }
  consider(.leading, abs(point.x - frame.minX), withinVertical)
  consider(.trailing, abs(point.x - frame.maxX), withinVertical)
  consider(.top, abs(point.y - frame.minY), withinHorizontal)
  consider(.bottom, abs(point.y - frame.maxY), withinHorizontal)
  return best?.side
}

private func policyCanvasPortSpacingPairViolation(
  _ kind: PolicyCanvasPortSpacingViolation.Kind,
  _ lower: PolicyCanvasResolvedMarker,
  _ upper: PolicyCanvasResolvedMarker,
  gap: CGFloat
) -> PolicyCanvasPortSpacingViolation {
  PolicyCanvasPortSpacingViolation(
    kind: kind,
    nodeID: lower.nodeID,
    side: lower.side,
    point: lower.point,
    otherPoint: upper.point,
    gap: gap,
    edgeIDs: (lower.edgeIDs + upper.edgeIDs).sorted()
  )
}

private func policyCanvasPortSpacingViolationOrder(
  _ lhs: PolicyCanvasPortSpacingViolation,
  _ rhs: PolicyCanvasPortSpacingViolation
) -> Bool {
  if lhs.nodeID != rhs.nodeID {
    return lhs.nodeID < rhs.nodeID
  }
  if lhs.side != rhs.side {
    return lhs.side.rawValue < rhs.side.rawValue
  }
  if abs(lhs.point.y - rhs.point.y) > 0.001 {
    return lhs.point.y < rhs.point.y
  }
  return lhs.point.x < rhs.point.x
}
