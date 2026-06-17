import CoreGraphics

/// Measure per-route length and bend figures, and flag cross-canvas long edges.
/// `horizontalSpan` (the route's bounding-box width) is the dominant long-edge
/// signal: a wire dragged across most of the canvas is the braid sample's
/// loudest defect and is invisible to the center-based production metric.
func policyCanvasMeasureEdgeLengths(
  routedEdges: [PolicyCanvasRoutedEdge],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> (
  summary: PolicyCanvasEdgeLengthSummary,
  longEdges: [PolicyCanvasLongEdgeViolation],
  detours: [PolicyCanvasDetourViolation],
  routeSegments: [PolicyCanvasRouteSegmentLengthViolation]
) {
  var lengths: [CGFloat] = []
  var bendCounts: [Int] = []
  var longEdges: [PolicyCanvasLongEdgeViolation] = []
  var detours: [PolicyCanvasDetourViolation] = []
  var routeSegments: [PolicyCanvasRouteSegmentLengthViolation] = []
  for routed in routedEdges {
    let points = routed.route.points
    guard points.count >= 2 else {
      continue
    }
    var length: CGFloat = 0
    for index in 1..<points.count {
      let start = points[index - 1]
      let end = points[index]
      let segment = PolicyCanvasRouteSegment(start: start, end: end)
      let segmentLength = hypot(end.x - start.x, end.y - start.y)
      length += segmentLength
      if let violation = policyCanvasRouteSegmentLengthViolation(
        edgeID: routed.edge.id,
        segment: segment,
        length: segmentLength,
        thresholds: thresholds
      ) {
        routeSegments.append(violation)
      }
    }
    let bendCount = policyCanvasRouteBendCount(points)
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    let minX = xs.min() ?? 0
    let maxX = xs.max() ?? 0
    let minY = ys.min() ?? 0
    let maxY = ys.max() ?? 0
    let horizontalSpan = maxX - minX
    let verticalSpan = maxY - minY
    lengths.append(length)
    bendCounts.append(bendCount)
    let bounds = CGRect(x: minX, y: minY, width: horizontalSpan, height: verticalSpan)
    if horizontalSpan >= thresholds.longEdgeSpan {
      longEdges.append(
        PolicyCanvasLongEdgeViolation(
          edgeID: routed.edge.id,
          length: length,
          horizontalSpan: horizontalSpan,
          verticalSpan: verticalSpan,
          bendCount: bendCount,
          bounds: bounds
        )
      )
    }
    if let first = points.first, let last = points.last {
      let ideal = abs(last.x - first.x) + abs(last.y - first.y)
      let excess = length - ideal
      if excess >= thresholds.detourExcess {
        detours.append(
          PolicyCanvasDetourViolation(
            edgeID: routed.edge.id,
            length: length,
            idealLength: ideal,
            excess: excess,
            points: points,
            bounds: bounds
          )
        )
      }
    }
  }
  let count = lengths.count
  let total = lengths.reduce(0, +)
  let summary = PolicyCanvasEdgeLengthSummary(
    routedEdgeCount: count,
    totalLength: total,
    averageLength: count == 0 ? 0 : total / CGFloat(count),
    maxLength: lengths.max() ?? 0,
    totalBends: bendCounts.reduce(0, +),
    maxBends: bendCounts.max() ?? 0
  )
  let sortedLongEdges = longEdges.sorted { lhs, rhs in
    abs(lhs.horizontalSpan - rhs.horizontalSpan) > 0.001
      ? lhs.horizontalSpan > rhs.horizontalSpan
      : lhs.edgeID < rhs.edgeID
  }
  let sortedDetours = detours.sorted { lhs, rhs in
    abs(lhs.excess - rhs.excess) > 0.001 ? lhs.excess > rhs.excess : lhs.edgeID < rhs.edgeID
  }
  return (
    summary,
    sortedLongEdges,
    sortedDetours,
    routeSegments.sorted(by: policyCanvasRouteSegmentLengthViolationOrder)
  )
}

private func policyCanvasRouteSegmentLengthViolation(
  edgeID: String,
  segment: PolicyCanvasRouteSegment,
  length: CGFloat,
  thresholds: PolicyCanvasGraphQualityThresholds
) -> PolicyCanvasRouteSegmentLengthViolation? {
  let tolerance: CGFloat = 0.001
  guard length > tolerance else {
    return nil
  }
  if !segment.isHorizontal && !segment.isVertical {
    return PolicyCanvasRouteSegmentLengthViolation(
      kind: .offGrid,
      edgeID: edgeID,
      start: segment.start,
      end: segment.end,
      length: length,
      remainder: length
    )
  }
  if length + tolerance < thresholds.minimumRouteSegmentLength {
    return PolicyCanvasRouteSegmentLengthViolation(
      kind: .tooShort,
      edgeID: edgeID,
      start: segment.start,
      end: segment.end,
      length: length,
      remainder: length
    )
  }
  let grid = max(thresholds.routeSegmentLengthGrid, 1)
  let remainder = length.truncatingRemainder(dividingBy: grid)
  let gridDistance = min(remainder, grid - remainder)
  guard gridDistance > tolerance else {
    return nil
  }
  return PolicyCanvasRouteSegmentLengthViolation(
    kind: .offGrid,
    edgeID: edgeID,
    start: segment.start,
    end: segment.end,
    length: length,
    remainder: gridDistance
  )
}

private func policyCanvasRouteSegmentLengthViolationOrder(
  _ lhs: PolicyCanvasRouteSegmentLengthViolation,
  _ rhs: PolicyCanvasRouteSegmentLengthViolation
) -> Bool {
  if lhs.edgeID != rhs.edgeID {
    return lhs.edgeID < rhs.edgeID
  }
  if lhs.kind != rhs.kind {
    return lhs.kind.rawValue < rhs.kind.rawValue
  }
  if abs(lhs.start.x - rhs.start.x) > 0.001 {
    return lhs.start.x < rhs.start.x
  }
  if abs(lhs.start.y - rhs.start.y) > 0.001 {
    return lhs.start.y < rhs.start.y
  }
  if abs(lhs.end.x - rhs.end.x) > 0.001 {
    return lhs.end.x < rhs.end.x
  }
  return lhs.end.y < rhs.end.y
}

/// Count direction changes in an orthogonal polyline. A vertex is a bend when
/// the incoming and outgoing segments differ in axis.
private func policyCanvasRouteBendCount(_ points: [CGPoint]) -> Int {
  guard points.count >= 3 else {
    return 0
  }
  var bends = 0
  for index in 1..<(points.count - 1) {
    let previous = points[index - 1]
    let current = points[index]
    let next = points[index + 1]
    let incomingHorizontal = abs(current.y - previous.y) < 0.001
    let outgoingHorizontal = abs(next.y - current.y) < 0.001
    if incomingHorizontal != outgoingHorizontal {
      bends += 1
    }
  }
  return bends
}
