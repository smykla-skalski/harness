import CoreGraphics

private struct PolicyCanvasResolvedMarker {
  let nodeID: String
  let side: PolicyCanvasPortSide
  let alongAxis: CGFloat
  let point: CGPoint
  let edgeIDs: [String]
}

/// One route terminal awaiting bucketing onto a node side: the wire end point,
/// the port it belongs to, and the owning edge.
private struct PolicyCanvasPortMarkerTerminal {
  let point: CGPoint
  let endpoint: PolicyCanvasPortEndpoint
  let edgeID: String
}

/// Measure port-marker spacing on every node side. Each route attaches its dot
/// exactly at `route.points.first` (source) / `.last` (target). Every dot is
/// judged on the node side it actually lands on - a single logical port can fan
/// its wires onto more than one side, so collapsing a port into one centroid
/// would invent a mid-body point with no dot under it. Dots on one side that
/// stack below the port diameter are an overlap. The detached case (a wire that
/// does not reach its dot) is measured separately in
/// `policyCanvasMeasurePortDetachment`, which compares the wire end against the
/// rendered marker layout - a terminal landing off the node here is simply not
/// bucketed onto any side.
func policyCanvasMeasurePortSpacing(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasPortSpacingViolation] {
  var markersByNodeSide: [String: [PolicyCanvasPortSide: [PolicyCanvasResolvedMarker]]] = [:]
  let tolerance = PolicyCanvasLayout.portDiameter
  let thresholdTolerance: CGFloat = 0.001
  for routed in routedEdges {
    guard let first = routed.route.points.first, let last = routed.route.points.last else {
      continue
    }
    policyCanvasRegisterPortMarker(
      terminal: PolicyCanvasPortMarkerTerminal(
        point: first,
        endpoint: routed.edge.source,
        edgeID: routed.edge.id
      ),
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      markersByNodeSide: &markersByNodeSide
    )
    policyCanvasRegisterPortMarker(
      terminal: PolicyCanvasPortMarkerTerminal(
        point: last,
        endpoint: routed.edge.target,
        edgeID: routed.edge.id
      ),
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      markersByNodeSide: &markersByNodeSide
    )
  }
  var violations: [PolicyCanvasPortSpacingViolation] = []
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
        if gap + thresholdTolerance < thresholds.markerOverlap {
          violations.append(policyCanvasPortSpacingPairViolation(.overlap, lower, upper, gap: gap))
        }
      }
      violations.append(
        contentsOf: policyCanvasPortDistributionViolations(
          sorted: sorted,
          nodeFramesByID: nodeFramesByID,
          tolerance: thresholds.portEvenDistributionTolerance
        )
      )
    }
  }
  return violations.sorted(by: policyCanvasPortSpacingViolationOrder)
}

/// Flag the dots on one node side that sit far from the canonical evenly-spread
/// slot for their position. The k dots on a side should land at
/// `PolicyCanvasLayout.portY`/`portX(index:count:)` for `count = k` - the same
/// centered, equal-step distribution the node uses for its declared ports. The
/// slot is computed against the node's ACTUAL frame size, not the default node
/// size: a node sized by port demand is taller than the default, and judging its
/// dots against the default height would read every evenly-spread interior dot as
/// mis-placed. A dot more than `tolerance` off its slot (dots clustered at one
/// end, crammed toward the center, or unevenly gapped) is reported, carrying the
/// ideal slot as `otherPoint` so the overlay can show where it should have gone.
private func policyCanvasPortDistributionViolations(
  sorted: [PolicyCanvasResolvedMarker],
  nodeFramesByID: [String: CGRect],
  tolerance: CGFloat
) -> [PolicyCanvasPortSpacingViolation] {
  let count = sorted.count
  guard count >= 2, let first = sorted.first, let frame = nodeFramesByID[first.nodeID] else {
    return []
  }
  let horizontalSide = first.side == .leading || first.side == .trailing
  let base = horizontalSide ? frame.minY : frame.minX
  var violations: [PolicyCanvasPortSpacingViolation] = []
  for index in sorted.indices {
    let marker = sorted[index]
    let idealAlong =
      base
      + (horizontalSide
        ? PolicyCanvasLayout.portY(index: index, count: count, nodeHeight: frame.height)
        : PolicyCanvasLayout.portX(index: index, count: count, nodeWidth: frame.width))
    let deviation = abs(marker.alongAxis - idealAlong)
    guard deviation > tolerance else {
      continue
    }
    let idealPoint =
      horizontalSide
      ? CGPoint(x: marker.point.x, y: idealAlong)
      : CGPoint(x: idealAlong, y: marker.point.y)
    violations.append(
      PolicyCanvasPortSpacingViolation(
        kind: .uneven,
        nodeID: marker.nodeID,
        side: marker.side,
        point: marker.point,
        otherPoint: idealPoint,
        gap: deviation,
        edgeIDs: marker.edgeIDs
      )
    )
  }
  return violations
}

/// Resolve one route terminal to the node side it lands on and merge it into the
/// per-side marker set. A terminal that lands off every edge is dropped here -
/// the detached signal is measured against the rendered marker layout instead.
private func policyCanvasRegisterPortMarker(
  terminal: PolicyCanvasPortMarkerTerminal,
  nodeFramesByID: [String: CGRect],
  tolerance: CGFloat,
  markersByNodeSide: inout [String: [PolicyCanvasPortSide: [PolicyCanvasResolvedMarker]]]
) {
  let endpoint = terminal.endpoint
  let point = terminal.point
  guard let frame = nodeFramesByID[endpoint.nodeID] else {
    return
  }
  guard let side = policyCanvasMarkerSide(point: point, frame: frame, tolerance: tolerance) else {
    return
  }
  let along: CGFloat = (side == .leading || side == .trailing) ? point.y : point.x
  policyCanvasMergePortMarker(
    into: &markersByNodeSide[endpoint.nodeID, default: [:]][side, default: []],
    marker: PolicyCanvasResolvedMarker(
      nodeID: endpoint.nodeID,
      side: side,
      alongAxis: along,
      point: point,
      edgeIDs: [terminal.edgeID]
    )
  )
}

/// Merge a terminal into an existing dot at the same position (several wires can
/// share one visible dot) or append it as a new dot, keeping `edgeIDs` sorted so
/// the result is reproducible.
private func policyCanvasMergePortMarker(
  into markers: inout [PolicyCanvasResolvedMarker],
  marker: PolicyCanvasResolvedMarker
) {
  if let index = markers.firstIndex(where: {
    abs($0.point.x - marker.point.x) < 0.5 && abs($0.point.y - marker.point.y) < 0.5
  }) {
    let merged = (markers[index].edgeIDs + marker.edgeIDs).sorted()
    markers[index] = PolicyCanvasResolvedMarker(
      nodeID: marker.nodeID,
      side: marker.side,
      alongAxis: marker.alongAxis,
      point: marker.point,
      edgeIDs: merged
    )
    return
  }
  markers.append(marker)
}

/// The side of `frame` a marker sits on, or nil when the point is off the node
/// (a detached marker). A point counts as on a side when it is within
/// `tolerance` of that edge and inside the perpendicular extent.
func policyCanvasMarkerSide(
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

func policyCanvasPortSpacingViolationOrder(
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
