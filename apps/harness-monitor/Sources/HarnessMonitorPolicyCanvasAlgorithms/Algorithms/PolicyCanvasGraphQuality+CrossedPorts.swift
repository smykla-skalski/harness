import CoreGraphics

/// One wire terminal resolved onto a node side: where it attaches (`offset`
/// along the side, `point` in content space) and where it comes from (`far`,
/// the opposite route endpoint projected onto the same axis).
private struct PolicyCanvasSideTerminal {
  let edgeID: String
  let offset: CGFloat
  let far: CGFloat
  let point: CGPoint
}

/// Measure wires that picked the wrong port: two edges on one node side - inputs
/// on a leading/top side, outputs on a trailing/bottom side - whose attach order
/// along that side is inverted relative to where they come from, so the wires
/// cross between the node and their far ends. The crossing-free order is the order
/// of the far endpoints along the side axis (the same far-endpoint ordering the
/// port-marker layout aims for). Every inverted pair is a crossing, so all pairs
/// on a side are compared, not just adjacent ones: a fan where two ports share an
/// attach offset (overlapping markers) would otherwise break the adjacency chain
/// and hide the real crossings on either side of it. These are crossings between
/// edges that share the node, which the independent-crossing metric deliberately
/// ignores, so they need their own signal.
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
      far: last,
      route: routed.route,
      nodeID: routed.edge.source.nodeID,
      edgeID: routed.edge.id,
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      byNodeSide: &byNodeSide
    )
    policyCanvasRegisterSideTerminal(
      point: last,
      far: first,
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
          // Distinct attach points coming from distinct far positions, inverted:
          // the earlier port is fed from farther along the axis than the later one.
          guard
            abs(lower.offset - upper.offset) > 0.5,
            abs(lower.far - upper.far) > 0.5,
            lower.far > upper.far
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
  far: CGPoint,
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
  // The far-position inversion test assumes a direct approach: the wire moves
  // monotonically across the side axis from its port to its far end. A wire that
  // reverses (dives past then climbs back, or routes around) sits in the channel
  // somewhere its far position does not predict, so its inclusion would invent a
  // crossing that is really a routing detour - flagged elsewhere as a wrong turn,
  // not a wrong port. Skip it here.
  guard policyCanvasRoutePerpendicularlyMonotonic(route, horizontalSide: horizontalSide) else {
    return
  }
  let terminal = PolicyCanvasSideTerminal(
    edgeID: edgeID,
    offset: horizontalSide ? point.y : point.x,
    far: horizontalSide ? far.y : far.x,
    point: point
  )
  byNodeSide[nodeID, default: [:]][side, default: []].append(terminal)
}

/// True when the route never reverses along the side's perpendicular axis (y for
/// a leading/trailing side, x for top/bottom). A monotone run - flat steps
/// allowed - is a direct approach the far-position test can reason about; a sign
/// flip is a backtracking detour.
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
