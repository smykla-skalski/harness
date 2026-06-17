import CoreGraphics

/// One wire terminal resolved onto a node side: where it attaches (`offset`
/// along the side, `point` in content space) plus the full route, so a pair of
/// terminals on one side can be tested for an actual crossing rather than an
/// inferred one.
private struct PolicyCanvasSideTerminal {
  let edgeID: String
  let offset: CGFloat
  let point: CGPoint
  let points: [CGPoint]
}

/// Measure wires that picked the wrong port: two edges meeting one node side -
/// inputs on a leading/top side, outputs on a trailing/bottom side - whose routes
/// actually cross between their ports. Swapping the two ports would untangle them.
///
/// Earlier versions inferred the crossing from a one-dimensional order key (where
/// each wire came from along the side axis). That is unreliable once several wires
/// funnel through a shared fan-in channel: the channel re-stacks them, so the
/// order key both invents crossings between wires that end up running parallel and
/// misses real ones. The order key is replaced by a direct geometric test - two
/// terminals are crossed only when their polylines properly intersect away from
/// the shared node. Detour wires (a route that reverses across the side axis) are
/// still skipped: their crossing is a routing backtrack flagged as a wrong turn,
/// not a wrong port. These are crossings between edges that share the node, which
/// the independent-crossing metric deliberately ignores, so they need their own
/// signal.
func policyCanvasMeasureCrossedPorts(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect]
) -> [PolicyCanvasCrossedPortsViolation] {
  let tolerance = PolicyCanvasLayout.portDiameter
  var byNodeSide: [String: [PolicyCanvasPortSide: [PolicyCanvasSideTerminal]]] = [:]
  for routed in routedEdges {
    guard let first = routed.route.points.first, let last = routed.route.points.last else {
      continue
    }
    policyCanvasRegisterSideTerminal(
      point: first,
      route: routed.route,
      nodeID: routed.edge.source.nodeID,
      edgeID: routed.edge.id,
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      byNodeSide: &byNodeSide
    )
    policyCanvasRegisterSideTerminal(
      point: last,
      route: routed.route,
      nodeID: routed.edge.target.nodeID,
      edgeID: routed.edge.id,
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      byNodeSide: &byNodeSide
    )
  }
  var violations: [PolicyCanvasCrossedPortsViolation] = []
  for (nodeID, sideMap) in byNodeSide {
    for (side, terminals) in sideMap where terminals.count >= 2 {
      let sorted = terminals.sorted {
        abs($0.offset - $1.offset) > 0.5 ? $0.offset < $1.offset : $0.edgeID < $1.edgeID
      }
      for index in 0..<sorted.count {
        for jndex in (index + 1)..<sorted.count {
          let lower = sorted[index]
          let upper = sorted[jndex]
          // Distinct attach points whose routes actually cross between the ports.
          guard
            abs(lower.offset - upper.offset) > 0.5,
            policyCanvasRoutesCross(lower.points, upper.points, tolerance: tolerance)
          else {
            continue
          }
          violations.append(
            PolicyCanvasCrossedPortsViolation(
              nodeID: nodeID,
              side: side,
              edgeA: lower.edgeID,
              edgeB: upper.edgeID,
              pointA: lower.point,
              pointB: upper.point
            )
          )
        }
      }
    }
  }
  return violations.sorted(by: policyCanvasCrossedPortsOrder)
}

private func policyCanvasRegisterSideTerminal(
  point: CGPoint,
  route: PolicyCanvasEdgeRoute,
  nodeID: String,
  edgeID: String,
  nodeFramesByID: [String: CGRect],
  tolerance: CGFloat,
  byNodeSide: inout [String: [PolicyCanvasPortSide: [PolicyCanvasSideTerminal]]]
) {
  guard
    let frame = nodeFramesByID[nodeID],
    let side = policyCanvasMarkerSide(point: point, frame: frame, tolerance: tolerance)
  else {
    return
  }
  let horizontalSide = side == .leading || side == .trailing
  // A wire that reverses across the side axis (dives past its port then climbs
  // back, or routes around) crosses its neighbours because of that backtrack, not
  // because it picked the wrong port. That is a routing detour - flagged elsewhere
  // as a wrong turn - so it must not read as a crossed port. Skip it here.
  guard policyCanvasRoutePerpendicularlyMonotonic(route, horizontalSide: horizontalSide) else {
    return
  }
  let terminal = PolicyCanvasSideTerminal(
    edgeID: edgeID,
    offset: horizontalSide ? point.y : point.x,
    point: point,
    points: route.points
  )
  byNodeSide[nodeID, default: [:]][side, default: []].append(terminal)
}

/// True when the two polylines properly cross at an interior point that sits more
/// than `tolerance` from either polyline's own endpoints. The endpoint guard drops
/// the fan-in convergence near the shared node, where neighbouring wires crowd but
/// do not tangle, so only a genuine crossing between the ports counts.
private func policyCanvasRoutesCross(
  _ a: [CGPoint],
  _ b: [CGPoint],
  tolerance: CGFloat
) -> Bool {
  let endpoints = [a.first, a.last, b.first, b.last].compactMap { $0 }
  guard a.count >= 2, b.count >= 2 else {
    return false
  }
  for indexA in 1..<a.count {
    for indexB in 1..<b.count {
      guard
        let point = policyCanvasSegmentCrossing(a[indexA - 1], a[indexA], b[indexB - 1], b[indexB])
      else {
        continue
      }
      if endpoints.contains(where: { hypot($0.x - point.x, $0.y - point.y) < tolerance }) {
        continue
      }
      return true
    }
  }
  return false
}

/// Proper interior intersection of two segments, or nil when they miss, only meet
/// at an endpoint, or are collinear (a shared corridor, not a crossing).
private func policyCanvasSegmentCrossing(
  _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint
) -> CGPoint? {
  let denominator = (p2.x - p1.x) * (p4.y - p3.y) - (p2.y - p1.y) * (p4.x - p3.x)
  guard abs(denominator) > 0.0001 else {
    return nil
  }
  let t = ((p3.x - p1.x) * (p4.y - p3.y) - (p3.y - p1.y) * (p4.x - p3.x)) / denominator
  let u = ((p3.x - p1.x) * (p2.y - p1.y) - (p3.y - p1.y) * (p2.x - p1.x)) / denominator
  guard t > 0.0001, t < 0.9999, u > 0.0001, u < 0.9999 else {
    return nil
  }
  return CGPoint(x: p1.x + t * (p2.x - p1.x), y: p1.y + t * (p2.y - p1.y))
}

/// True when the route never reverses along the side's perpendicular axis (y for
/// a leading/trailing side, x for top/bottom). A monotone run - flat steps
/// allowed - is a direct approach; a sign flip is a backtracking detour.
private func policyCanvasRoutePerpendicularlyMonotonic(
  _ route: PolicyCanvasEdgeRoute,
  horizontalSide: Bool
) -> Bool {
  let coordinates = route.points.map { horizontalSide ? $0.y : $0.x }
  guard coordinates.count >= 3 else {
    return true
  }
  var direction = 0
  for index in 1..<coordinates.count {
    let delta = coordinates[index] - coordinates[index - 1]
    guard abs(delta) > 0.5 else {
      continue
    }
    let sign = delta > 0 ? 1 : -1
    if direction == 0 {
      direction = sign
    } else if direction != sign {
      return false
    }
  }
  return true
}

private func policyCanvasCrossedPortsOrder(
  _ lhs: PolicyCanvasCrossedPortsViolation,
  _ rhs: PolicyCanvasCrossedPortsViolation
) -> Bool {
  if lhs.nodeID != rhs.nodeID {
    return lhs.nodeID < rhs.nodeID
  }
  if lhs.side != rhs.side {
    return lhs.side.rawValue < rhs.side.rawValue
  }
  if abs(lhs.pointA.y - rhs.pointA.y) > 0.001 {
    return lhs.pointA.y < rhs.pointA.y
  }
  return lhs.pointA.x < rhs.pointA.x
}
