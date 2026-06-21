import CoreGraphics

/// One wire terminal resolved onto a node side: where it attaches (`offset`
/// along the side, `point` in content space) plus the full route, so a pair of
/// terminals on one side can be tested for an actual crossing rather than an
/// inferred one.
struct PolicyCanvasSideTerminal {
  let edgeID: String
  let offset: CGFloat
  let point: CGPoint
  let points: [CGPoint]
  /// False when the route reverses across the side's perpendicular axis (a detour
  /// or channel overshoot). A proper interior crossing between two such routes is
  /// a routing backtrack, not a wrong port, so it is ignored - but a swap inside a
  /// shared channel still counts even when one wire overshoots.
  let isMonotonic: Bool
}

/// A node side, used to key the crossed-port terminal groups. Crossed-port
/// violations are computed independently per node side, so the incremental
/// repair measurement recomputes only the sides whose terminals changed.
struct PolicyCanvasCrossedPortNodeSide: Hashable {
  let nodeID: String
  let side: PolicyCanvasPortSide
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
  let registration = policyCanvasCrossedPortTerminalsByNodeSide(
    routedEdges: routedEdges,
    nodeFramesByID: nodeFramesByID,
    tolerance: tolerance
  )
  var violations: [PolicyCanvasCrossedPortsViolation] = []
  for (nodeSide, terminals) in registration.terminalsByNodeSide {
    violations.append(
      contentsOf: policyCanvasCrossedPortViolationsForSide(
        nodeSide, terminals: terminals, tolerance: tolerance))
  }
  return violations.sorted(by: policyCanvasCrossedPortsOrder)
}

/// Per-node-side terminal groups for the crossed-port metric, plus the sides
/// each edge contributed a terminal to. Crossed-port violations are computed
/// independently per node side, so the incremental repair measurement reuses
/// these groups and recomputes only the sides whose terminals a candidate moved.
struct PolicyCanvasCrossedPortRegistration {
  var terminalsByNodeSide: [PolicyCanvasCrossedPortNodeSide: [PolicyCanvasSideTerminal]]
  var nodeSidesByEdge: [String: [PolicyCanvasCrossedPortNodeSide]]
}

func policyCanvasCrossedPortTerminalsByNodeSide(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect],
  tolerance: CGFloat
) -> PolicyCanvasCrossedPortRegistration {
  var terminalsByNodeSide: [PolicyCanvasCrossedPortNodeSide: [PolicyCanvasSideTerminal]] = [:]
  var nodeSidesByEdge: [String: [PolicyCanvasCrossedPortNodeSide]] = [:]
  for routed in routedEdges {
    guard let first = routed.route.points.first, let last = routed.route.points.last else {
      continue
    }
    for (point, nodeID) in [
      (first, routed.edge.source.nodeID), (last, routed.edge.target.nodeID),
    ] {
      guard
        let resolved = policyCanvasResolveCrossedPortSideTerminal(
          point: point, routedEdge: routed, nodeID: nodeID,
          nodeFramesByID: nodeFramesByID, tolerance: tolerance)
      else {
        continue
      }
      terminalsByNodeSide[resolved.nodeSide, default: []].append(resolved.terminal)
      nodeSidesByEdge[routed.edge.id, default: []].append(resolved.nodeSide)
    }
  }
  return PolicyCanvasCrossedPortRegistration(
    terminalsByNodeSide: terminalsByNodeSide, nodeSidesByEdge: nodeSidesByEdge)
}

/// Resolve one edge terminal onto its node side. Nil when the point is not on
/// any side of its node frame.
func policyCanvasResolveCrossedPortSideTerminal(
  point: CGPoint,
  routedEdge: PolicyCanvasRoutedEdge,
  nodeID: String,
  nodeFramesByID: [String: CGRect],
  tolerance: CGFloat
) -> (nodeSide: PolicyCanvasCrossedPortNodeSide, terminal: PolicyCanvasSideTerminal)? {
  guard
    let frame = nodeFramesByID[nodeID],
    let side = policyCanvasMarkerSide(point: point, frame: frame, tolerance: tolerance)
  else {
    return nil
  }
  let horizontalSide = side == .leading || side == .trailing
  let terminal = PolicyCanvasSideTerminal(
    edgeID: routedEdge.edge.id,
    offset: horizontalSide ? point.y : point.x,
    point: point,
    points: routedEdge.route.points,
    isMonotonic: policyCanvasRoutePerpendicularlyMonotonic(
      routedEdge.route, horizontalSide: horizontalSide)
  )
  return (PolicyCanvasCrossedPortNodeSide(nodeID: nodeID, side: side), terminal)
}

/// Crossed-port violations within one node side. Self-contained per side so the
/// driver and the incremental repair measurement share identical logic.
func policyCanvasCrossedPortViolationsForSide(
  _ nodeSide: PolicyCanvasCrossedPortNodeSide,
  terminals: [PolicyCanvasSideTerminal],
  tolerance: CGFloat
) -> [PolicyCanvasCrossedPortsViolation] {
  guard terminals.count >= 2 else {
    return []
  }
  let side = nodeSide.side
  let horizontalSide = side == .leading || side == .trailing
  let sorted = terminals.sorted {
    abs($0.offset - $1.offset) > 0.5 ? $0.offset < $1.offset : $0.edgeID < $1.edgeID
  }
  var violations: [PolicyCanvasCrossedPortsViolation] = []
  for index in 0..<sorted.count {
    for jndex in (index + 1)..<sorted.count {
      let lower = sorted[index]
      let upper = sorted[jndex]
      // Two ways two ports read as crossed: their direct routes properly
      // intersect between the ports (a clean X, only trusted when neither wire
      // detours), or they share one channel and attach in swapped order (a
      // collinear swap the intersection test cannot see). Either counts.
      let properCross =
        lower.isMonotonic && upper.isMonotonic
        && policyCanvasRoutesCrossNearTerminals(lower, upper, tolerance: tolerance)
      let channelSwap = policyCanvasRoutesSwapInSharedChannel(
        lower, upper, horizontalSide: horizontalSide, tolerance: tolerance
      )
      guard abs(lower.offset - upper.offset) > 0.5, properCross || channelSwap else {
        continue
      }
      let spansPort = sorted.contains {
        $0.offset > lower.offset + 0.5 && $0.offset < upper.offset - 0.5
      }
      violations.append(
        PolicyCanvasCrossedPortsViolation(
          nodeID: nodeSide.nodeID,
          side: side,
          edgeA: lower.edgeID,
          edgeB: upper.edgeID,
          pointA: lower.point,
          pointB: upper.point,
          markPoint: policyCanvasCrossedPortMark(
            lower.point, upper.point, side: side, spansPort: spansPort)
        )
      )
    }
  }
  return violations
}

/// The point where the overlay draws the crossing X. Two adjacent crossed ports
/// have nothing between them, so the plain midpoint sits in the gap between the
/// dots - between the ports, clear of the node body. When another port lies
/// between the pair the midpoint would fall on that intermediate dot, so the mark
/// is pushed one port diameter off the node side (outward, onto the wire margin,
/// never into the body) to clear it while staying level with the two ports.
private func policyCanvasCrossedPortMark(
  _ pointA: CGPoint,
  _ pointB: CGPoint,
  side: PolicyCanvasPortSide,
  spansPort: Bool
) -> CGPoint {
  let mid = CGPoint(x: (pointA.x + pointB.x) / 2, y: (pointA.y + pointB.y) / 2)
  guard spansPort else {
    return mid
  }
  let bow = PolicyCanvasLayout.portDiameter
  switch side {
  case .leading:
    return CGPoint(x: mid.x - bow, y: mid.y)
  case .trailing:
    return CGPoint(x: mid.x + bow, y: mid.y)
  case .top:
    return CGPoint(x: mid.x, y: mid.y - bow)
  case .bottom:
    return CGPoint(x: mid.x, y: mid.y + bow)
  }
}

/// True when the two terminals funnel through one shared channel and attach in
/// swapped order. Two wires sharing a collinear channel run (same x for a vertical
/// channel feeding a leading/trailing side, same y for a horizontal channel
/// feeding a top/bottom side) cannot reorder without crossing: if the wire
/// attaching at the smaller offset reaches PAST the other wire's far end inside
/// the shared run, they swap and so cross. This is the case the proper-crossing
/// test misses, because collinear segments never produce an interior intersection
/// and a channel overshoot reverses the route so the monotonic guard would drop
/// it. It stays specific to a genuinely shared channel: wires in separate lanes
/// (m13's fan-in) are not collinear, so they never reach this test.
private func policyCanvasRoutesSwapInSharedChannel(
  _ lower: PolicyCanvasSideTerminal,
  _ upper: PolicyCanvasSideTerminal,
  horizontalSide: Bool,
  tolerance: CGFloat
) -> Bool {
  for segLower in policyCanvasRouteSegments(lower.points) {
    for segUpper in policyCanvasRouteSegments(upper.points) {
      guard
        let lowerFar = policyCanvasSharedChannelFarEnd(
          segment: segLower, other: segUpper, attach: lower.point,
          horizontalSide: horizontalSide, tolerance: tolerance),
        let upperFar = policyCanvasSharedChannelFarEnd(
          segment: segUpper, other: segLower, attach: upper.point,
          horizontalSide: horizontalSide, tolerance: tolerance)
      else {
        continue
      }
      // `lower` attaches at the smaller offset; a swap means its far end overshoots
      // beyond `upper`'s far end along the side axis.
      if lowerFar > upperFar {
        return true
      }
    }
  }
  return false
}

/// For a segment that shares a collinear channel with `other` (both run along the
/// channel axis - constant x for a vertical channel, constant y for a horizontal
/// one - at the same position, with an overlapping extent longer than
/// `tolerance`), the coordinate of this segment's end farthest from `attach` along
/// the side axis. Nil when the two segments do not form a shared channel.
private func policyCanvasSharedChannelFarEnd(
  segment: (CGPoint, CGPoint),
  other: (CGPoint, CGPoint),
  attach: CGPoint,
  horizontalSide: Bool,
  tolerance: CGFloat
) -> CGFloat? {
  // A vertical channel (constant x) feeds a leading/trailing side; a horizontal
  // channel (constant y) feeds a top/bottom side. The side axis runs along the
  // channel: y for a vertical channel, x for a horizontal one.
  let along: (CGPoint) -> CGFloat = horizontalSide ? { $0.y } : { $0.x }
  let across: (CGPoint) -> CGFloat = horizontalSide ? { $0.x } : { $0.y }
  guard
    abs(across(segment.0) - across(segment.1)) <= 0.5,
    abs(across(other.0) - across(other.1)) <= 0.5,
    abs(across(segment.0) - across(other.0)) <= 0.5
  else {
    return nil
  }
  let segLo = min(along(segment.0), along(segment.1))
  let segHi = max(along(segment.0), along(segment.1))
  let otherLo = min(along(other.0), along(other.1))
  let otherHi = max(along(other.0), along(other.1))
  guard min(segHi, otherHi) - max(segLo, otherLo) > tolerance else {
    return nil
  }
  let attachAlong = along(attach)
  return abs(segLo - attachAlong) >= abs(segHi - attachAlong) ? segLo : segHi
}

/// The ordered point pairs of a polyline.
private func policyCanvasRouteSegments(_ points: [CGPoint]) -> [(CGPoint, CGPoint)] {
  guard points.count >= 2 else {
    return []
  }
  return (1..<points.count).map { (points[$0 - 1], points[$0]) }
}

/// True when the two polylines properly cross at an interior point that sits more
/// than `tolerance` from either polyline's own endpoints. The endpoint guard drops
/// the fan-in convergence near the shared node, where neighbouring wires crowd but
/// do not tangle, so only a genuine crossing between the ports counts.
private func policyCanvasRoutesCrossNearTerminals(
  _ lower: PolicyCanvasSideTerminal,
  _ upper: PolicyCanvasSideTerminal,
  tolerance: CGFloat
) -> Bool {
  let lowerPoints = lower.points
  let upperPoints = upper.points
  let endpoints = [lowerPoints.first, lowerPoints.last, upperPoints.first, upperPoints.last]
    .compactMap { $0 }
  guard lowerPoints.count >= 2, upperPoints.count >= 2 else {
    return false
  }
  let terminalReach =
    PolicyCanvasLayout.edgePortTurnMinimumLead + PolicyCanvasLayout.defaultEdgeLineSpacing
  for indexA in 1..<lowerPoints.count {
    for indexB in 1..<upperPoints.count {
      guard
        let point = policyCanvasSegmentCrossing(
          lowerPoints[indexA - 1],
          lowerPoints[indexA],
          upperPoints[indexB - 1],
          upperPoints[indexB]
        )
      else {
        continue
      }
      if endpoints.contains(where: { hypot($0.x - point.x, $0.y - point.y) < tolerance }) {
        continue
      }
      guard
        hypot(lower.point.x - point.x, lower.point.y - point.y) <= terminalReach
          || hypot(upper.point.x - point.x, upper.point.y - point.y) <= terminalReach
      else {
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
  let tFraction = ((p3.x - p1.x) * (p4.y - p3.y) - (p3.y - p1.y) * (p4.x - p3.x)) / denominator
  let uFraction = ((p3.x - p1.x) * (p2.y - p1.y) - (p3.y - p1.y) * (p2.x - p1.x)) / denominator
  guard tFraction > 0.0001, tFraction < 0.9999, uFraction > 0.0001, uFraction < 0.9999 else {
    return nil
  }
  return CGPoint(x: p1.x + tFraction * (p2.x - p1.x), y: p1.y + tFraction * (p2.y - p1.y))
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

func policyCanvasCrossedPortsOrder(
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
