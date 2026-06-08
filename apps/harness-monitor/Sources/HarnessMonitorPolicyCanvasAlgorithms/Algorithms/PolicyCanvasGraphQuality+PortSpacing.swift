import CoreGraphics

private struct PolicyCanvasResolvedMarker {
  let nodeID: String
  let side: PolicyCanvasPortSide
  let alongAxis: CGFloat
  let point: CGPoint
  let edgeIDs: [String]
}

/// Measure port-marker spacing on every node side. Each route attaches its dot
/// exactly at `route.points.first` (source) / `.last` (target). Every dot is
/// judged on the node side it actually lands on - a single logical port can fan
/// its wires onto more than one side, so collapsing a port into one centroid
/// would invent a mid-body point with no dot under it and report a phantom
/// detached marker. Dots on one side that stack below the port diameter are an
/// overlap; below the minimum spacing, a too-close warning; a dot that lands off
/// every node edge is genuinely detached.
func policyCanvasMeasurePortSpacing(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasPortSpacingViolation] {
  var markersByNodeSide: [String: [PolicyCanvasPortSide: [PolicyCanvasResolvedMarker]]] = [:]
  var detachedByNode: [String: [PolicyCanvasResolvedMarker]] = [:]
  let tolerance = PolicyCanvasLayout.portDiameter
  for routed in routedEdges {
    guard let first = routed.route.points.first, let last = routed.route.points.last else {
      continue
    }
    policyCanvasRegisterPortMarker(
      point: first,
      endpoint: routed.edge.source,
      edgeID: routed.edge.id,
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      markersByNodeSide: &markersByNodeSide,
      detachedByNode: &detachedByNode
    )
    policyCanvasRegisterPortMarker(
      point: last,
      endpoint: routed.edge.target,
      edgeID: routed.edge.id,
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      markersByNodeSide: &markersByNodeSide,
      detachedByNode: &detachedByNode
    )
  }
  var violations: [PolicyCanvasPortSpacingViolation] = []
  for markers in detachedByNode.values {
    for marker in markers {
      violations.append(
        PolicyCanvasPortSpacingViolation(
          kind: .detached,
          nodeID: marker.nodeID,
          side: marker.side,
          point: marker.point,
          otherPoint: nil,
          gap: 0,
          edgeIDs: marker.edgeIDs
        )
      )
    }
  }
  for sideMap in markersByNodeSide.values {
    for markers in sideMap.values {
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

/// Resolve one route terminal to the node side it lands on and merge it into the
/// per-side marker set, or the detached set when it lands off every edge.
private func policyCanvasRegisterPortMarker(
  point: CGPoint,
  endpoint: PolicyCanvasPortEndpoint,
  edgeID: String,
  nodeFramesByID: [String: CGRect],
  tolerance: CGFloat,
  markersByNodeSide: inout [String: [PolicyCanvasPortSide: [PolicyCanvasResolvedMarker]]],
  detachedByNode: inout [String: [PolicyCanvasResolvedMarker]]
) {
  guard let frame = nodeFramesByID[endpoint.nodeID] else {
    return
  }
  guard let side = policyCanvasMarkerSide(point: point, frame: frame, tolerance: tolerance) else {
    let fallbackSide: PolicyCanvasPortSide = endpoint.kind == .input ? .leading : .trailing
    policyCanvasMergePortMarker(
      into: &detachedByNode[endpoint.nodeID, default: []],
      nodeID: endpoint.nodeID,
      side: fallbackSide,
      alongAxis: point.x,
      point: point,
      edgeID: edgeID
    )
    return
  }
  let along: CGFloat = (side == .leading || side == .trailing) ? point.y : point.x
  policyCanvasMergePortMarker(
    into: &markersByNodeSide[endpoint.nodeID, default: [:]][side, default: []],
    nodeID: endpoint.nodeID,
    side: side,
    alongAxis: along,
    point: point,
    edgeID: edgeID
  )
}

/// Merge a terminal into an existing dot at the same position (several wires can
/// share one visible dot) or append it as a new dot, keeping `edgeIDs` sorted so
/// the result is reproducible.
private func policyCanvasMergePortMarker(
  into markers: inout [PolicyCanvasResolvedMarker],
  nodeID: String,
  side: PolicyCanvasPortSide,
  alongAxis: CGFloat,
  point: CGPoint,
  edgeID: String
) {
  if let index = markers.firstIndex(where: {
    abs($0.point.x - point.x) < 0.5 && abs($0.point.y - point.y) < 0.5
  }) {
    let merged = (markers[index].edgeIDs + [edgeID]).sorted()
    markers[index] = PolicyCanvasResolvedMarker(
      nodeID: nodeID,
      side: side,
      alongAxis: alongAxis,
      point: point,
      edgeIDs: merged
    )
    return
  }
  markers.append(
    PolicyCanvasResolvedMarker(
      nodeID: nodeID,
      side: side,
      alongAxis: alongAxis,
      point: point,
      edgeIDs: [edgeID]
    )
  )
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
    if let current = best, distance >= current.distance {
      return
    }
    best = (side, distance)
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
