import CoreGraphics

/// Measure proper interior orthogonal crossings between every route pair. A
/// crossing where one segment runs horizontally and the other vertically, and
/// the intersection lies strictly inside both, is a real X (a shared endpoint
/// touching at a port is not). Edges that touch the same node are flagged so a
/// gate can budget those unavoidable crossings separately.
func policyCanvasMeasureCrossings(
  routedEdges: [PolicyCanvasRoutedEdge]
) -> [PolicyCanvasCrossingViolation] {
  var violations: [PolicyCanvasCrossingViolation] = []
  for leftIndex in routedEdges.indices {
    for rightIndex in routedEdges.index(after: leftIndex)..<routedEdges.endIndex {
      let lhs = routedEdges[leftIndex]
      let rhs = routedEdges[rightIndex]
      let points = policyCanvasRouteCrossingPoints(lhs.route, rhs.route)
      guard !points.isEmpty else {
        continue
      }
      let sharesEndpoint = policyCanvasEdgesShareEndpointNode(lhs.edge, rhs.edge)
      let edgeA = min(lhs.edge.id, rhs.edge.id)
      let edgeB = max(lhs.edge.id, rhs.edge.id)
      for point in points {
        violations.append(
          PolicyCanvasCrossingViolation(
            edgeA: edgeA,
            edgeB: edgeB,
            point: point,
            sharesEndpointNode: sharesEndpoint
          )
        )
      }
    }
  }
  return violations.sorted(by: policyCanvasCrossingViolationOrder)
}

/// Every distinct proper-crossing point between two routes. Canonical helper
/// the routing-quality tests share instead of re-deriving the crossing test in
/// each suite.
public func policyCanvasRouteCrossingPoints(
  _ lhs: PolicyCanvasEdgeRoute,
  _ rhs: PolicyCanvasEdgeRoute
) -> [CGPoint] {
  let leftSegments = policyCanvasRouteSegments(lhs)
  let rightSegments = policyCanvasRouteSegments(rhs)
  var points: [CGPoint] = []
  for left in leftSegments {
    for right in rightSegments {
      guard let point = policyCanvasSegmentsProperlyCross(left, right) else {
        continue
      }
      let alreadySeen = points.contains { existing in
        abs(existing.x - point.x) < 0.5 && abs(existing.y - point.y) < 0.5
      }
      if !alreadySeen {
        points.append(point)
      }
    }
  }
  return points
}

/// True when two routes cross at a proper interior orthogonal X. Consolidates
/// the `policyCanvasRoutesProperlyCross` helper that the lab, fan-in, and nudge
/// quality test suites each carried their own copy of.
public func policyCanvasRoutesProperlyCross(
  _ lhs: PolicyCanvasEdgeRoute,
  _ rhs: PolicyCanvasEdgeRoute
) -> Bool {
  !policyCanvasRouteCrossingPoints(lhs, rhs).isEmpty
}

func policyCanvasSegmentsProperlyCross(
  _ lhs: PolicyCanvasRouteSegment,
  _ rhs: PolicyCanvasRouteSegment
) -> CGPoint? {
  if lhs.isHorizontal, rhs.isVertical {
    return policyCanvasOrthogonalCrossPoint(horizontal: lhs, vertical: rhs)
  }
  if lhs.isVertical, rhs.isHorizontal {
    return policyCanvasOrthogonalCrossPoint(horizontal: rhs, vertical: lhs)
  }
  return nil
}

private func policyCanvasOrthogonalCrossPoint(
  horizontal: PolicyCanvasRouteSegment,
  vertical: PolicyCanvasRouteSegment
) -> CGPoint? {
  let tolerance: CGFloat = 0.5
  let y = horizontal.start.y
  let x = vertical.start.x
  let lowX = min(horizontal.start.x, horizontal.end.x)
  let highX = max(horizontal.start.x, horizontal.end.x)
  let lowY = min(vertical.start.y, vertical.end.y)
  let highY = max(vertical.start.y, vertical.end.y)
  guard
    x > lowX + tolerance, x < highX - tolerance,
    y > lowY + tolerance, y < highY - tolerance
  else {
    return nil
  }
  return CGPoint(x: x, y: y)
}

func policyCanvasEdgesShareEndpointNode(_ lhs: PolicyCanvasEdge, _ rhs: PolicyCanvasEdge) -> Bool {
  let leftNodes: Set<String> = [lhs.source.nodeID, lhs.target.nodeID]
  let rightNodes: Set<String> = [rhs.source.nodeID, rhs.target.nodeID]
  return !leftNodes.isDisjoint(with: rightNodes)
}

private func policyCanvasCrossingViolationOrder(
  _ lhs: PolicyCanvasCrossingViolation,
  _ rhs: PolicyCanvasCrossingViolation
) -> Bool {
  if lhs.edgeA != rhs.edgeA {
    return lhs.edgeA < rhs.edgeA
  }
  if lhs.edgeB != rhs.edgeB {
    return lhs.edgeB < rhs.edgeB
  }
  if abs(lhs.point.x - rhs.point.x) > 0.001 {
    return lhs.point.x < rhs.point.x
  }
  return lhs.point.y < rhs.point.y
}
