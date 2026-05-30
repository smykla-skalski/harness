import SwiftUI

// Final declutter pass over the settled displayed routes. A feeder that grazes
// an incompatible fan - a route heading to a different target node that it runs
// near-parallel to within edge spacing - is rerouted by descending its dominant
// vertical past a blocking node, so its bus runs clear of the fan and crosses it
// perpendicularly instead of alongside it. This is the case the sequential
// separation cannot resolve: when a feeder reaches a node on the fan's own row
// there is no clear horizontal channel between the rows.
//
// It runs once on the final route set rather than inside the per-route
// separation, so moving one feeder never re-triggers the separation of the
// others (that sequential coupling is what makes lane nudges cascade). A variant
// is adopted only when it clears every graze against a different-target route
// and hits no node, so intentional same-target bundles and trunks are never
// disturbed: a route grazed from several sides finds no fully-clearing descent
// and is left exactly as it was.
func policyCanvasVerticalDescentDeclutteredRoutes(
  _ routes: [String: PolicyCanvasEdgeRoute],
  edges: [PolicyCanvasEdge],
  nodeFrames: [CGRect],
  lineSpacing: CGFloat = PolicyCanvasLayout.defaultEdgeLineSpacing
) -> [String: PolicyCanvasEdgeRoute] {
  let targetByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0.target.nodeID) })
  let minOverlap = PolicyCanvasLayout.gridSize * 3
  var result = routes
  for edge in edges {
    guard let route = result[edge.id], let target = targetByID[edge.id] else {
      continue
    }
    let rivals = edges.compactMap { other -> PolicyCanvasEdgeRoute? in
      guard other.id != edge.id, targetByID[other.id] != target, let rival = result[other.id]
      else {
        return nil
      }
      return rival
    }
    guard
      policyCanvasRouteGrazes(route, rivals: rivals, spacing: lineSpacing, minOverlap: minOverlap)
    else {
      continue
    }
    if let cleared = policyCanvasClearedDescentRoute(
      route,
      rivals: rivals,
      nodeFrames: nodeFrames,
      lineSpacing: lineSpacing,
      minOverlap: minOverlap
    ) {
      result[edge.id] = cleared
    }
  }
  return result
}

private func policyCanvasClearedDescentRoute(
  _ route: PolicyCanvasEdgeRoute,
  rivals: [PolicyCanvasEdgeRoute],
  nodeFrames: [CGRect],
  lineSpacing: CGFloat,
  minOverlap: CGFloat
) -> PolicyCanvasEdgeRoute? {
  for laneX in policyCanvasVerticalDescentLanes(
    route: route, obstacles: nodeFrames, lineSpacing: lineSpacing)
  {
    guard let candidate = policyCanvasAlignedVerticalBundleRoute(route, targetX: laneX),
      !policyCanvasRouteIntersectsObstacles(candidate, obstacles: nodeFrames),
      !policyCanvasRouteGrazes(
        candidate, rivals: rivals, spacing: lineSpacing, minOverlap: minOverlap)
    else {
      continue
    }
    return candidate
  }
  // Vertical descent did not clear the graze: the conflict is on the dominant
  // horizontal run, where this through-bus skims a non-endpoint node's top right
  // where a fan converges on it (action -> default-allow skimming merge-deny's
  // top beside the lowest fail run). Reroute the bus UNDER that node - dropping
  // before the node's near edge, clear of any shared departure lane, then running
  // along the node's far side - so the channel above the node is the fan's alone.
  for candidate in policyCanvasUnderNodeClearanceRoutes(
    route: route, nodeFrames: nodeFrames, lineSpacing: lineSpacing)
  {
    guard
      !policyCanvasRouteIntersectsObstacles(candidate, obstacles: nodeFrames),
      !policyCanvasRouteGrazes(
        candidate, rivals: rivals, spacing: lineSpacing, minOverlap: minOverlap)
    else {
      continue
    }
    return candidate
  }
  return nil
}

// Reroutes a through-bus that skims a non-endpoint node's top (or bottom) so it
// passes on the node's far side instead. A bus rising into the narrow channel
// above a node's top - the same channel a fan-in occupies as it converges on
// that node - reads as one line with the fan and squeezes the fan's lowest label
// out of its staircase. Simply lowering the bus's run does not help when the run
// shares a departure lane with a sibling bus, because the lowered run would then
// graze the sibling's vertical; so the reroute turns the bus down BEFORE the
// skimmed node's near edge - clear of that shared lane - and carries it along the
// node's far side. Only a node that is NOT this route's own endpoint is rerouted
// around, so a fan feeder approaching its target node is never pushed away.
private func policyCanvasUnderNodeClearanceRoutes(
  route: PolicyCanvasEdgeRoute,
  nodeFrames: [CGRect],
  lineSpacing: CGFloat
) -> [PolicyCanvasEdgeRoute] {
  guard
    let dominant = policyCanvasDominantInteriorHorizontalSegment(route),
    let source = route.points.first,
    let target = route.points.last
  else {
    return []
  }
  let entry = route.points[dominant.index]
  // The entry end is the one a vertical drops onto; the bus carries on toward the
  // exit end. Require that entry vertical so the drop column has something to move.
  guard
    abs(route.points[dominant.index - 1].x - entry.x) < 0.5,
    abs(route.points[dominant.index - 1].y - entry.y) > 0.5
  else {
    return []
  }
  let margin = max(lineSpacing, PolicyCanvasLayout.gridSize)
  let proximity = PolicyCanvasLayout.gridSize * 3
  let minimumXOverlap = PolicyCanvasLayout.gridSize
  var candidates: [PolicyCanvasEdgeRoute] = []
  for node in nodeFrames {
    let endpointNode = node.insetBy(dx: -1, dy: -1)
    if endpointNode.contains(source) || endpointNode.contains(target) {
      continue
    }
    guard
      min(dominant.high, node.maxX) - max(dominant.low, node.minX) >= minimumXOverlap,
      entry.x < node.minX || entry.x > node.maxX
    else {
      continue
    }
    let runY: CGFloat
    if dominant.y <= node.minY, node.minY - dominant.y <= proximity {
      runY = node.maxY + margin
    } else if dominant.y >= node.maxY, dominant.y - node.maxY <= proximity {
      runY = node.minY - margin
    } else {
      continue
    }
    let dropX = entry.x < node.minX ? node.minX - margin : node.maxX + margin
    if let candidate = policyCanvasUnderNodeReroute(
      route, dominantIndex: dominant.index, dropX: dropX, runY: runY)
    {
      candidates.append(candidate)
    }
  }
  return candidates
}

// Rebuilds a route so its dominant horizontal segment turns down at `dropX` and
// runs at `runY`, keeping every other vertex. The entry vertical slides to
// `dropX` and the run drops there, so the bus turns down before the skimmed node
// and runs along its far side.
private func policyCanvasUnderNodeReroute(
  _ route: PolicyCanvasEdgeRoute,
  dominantIndex index: Int,
  dropX: CGFloat,
  runY: CGFloat
) -> PolicyCanvasEdgeRoute? {
  let beforeEntry = route.points[index - 1]
  // The horizontal feeding the entry vertical must extend to dropX without
  // reversing direction.
  if index >= 2 {
    let feeder = route.points[index - 2]
    let originalSign = beforeEntry.x - feeder.x
    let reroutedSign = dropX - feeder.x
    guard originalSign == 0 || originalSign * reroutedSign > 0 else {
      return nil
    }
  }
  let originalSourceSide = policyCanvasRouteSourceSide(route)
  let originalTargetSide = policyCanvasRouteTargetSide(route)
  var points = route.points
  points[index - 1].x = dropX
  points[index] = CGPoint(x: dropX, y: runY)
  points[index + 1].y = runY
  let compressed = PolicyCanvasVisibilityRouter.compressCollinear(points)
  let candidate = PolicyCanvasEdgeRoute(
    points: compressed,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
  )
  guard
    candidate.points.first == route.points.first,
    candidate.points.last == route.points.last,
    policyCanvasRouteIsOrthogonal(candidate),
    policyCanvasRouteSourceSide(candidate) == originalSourceSide,
    policyCanvasRouteTargetSide(candidate) == originalTargetSide
  else {
    return nil
  }
  return candidate
}

private func policyCanvasDominantInteriorHorizontalSegment(
  _ route: PolicyCanvasEdgeRoute
) -> (index: Int, y: CGFloat, low: CGFloat, high: CGFloat)? {
  guard route.points.count >= 4 else {
    return nil
  }
  var best: (index: Int, y: CGFloat, low: CGFloat, high: CGFloat)?
  var bestLength: CGFloat = -1
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    guard abs(start.y - end.y) < 0.5, abs(start.x - end.x) > 0.5 else {
      continue
    }
    let length = abs(end.x - start.x)
    if length > bestLength {
      bestLength = length
      best = (index, start.y, min(start.x, end.x), max(start.x, end.x))
    }
  }
  return best
}

// Candidate X positions for the descent: a column just past the left and right
// edge of every node, plus local nudges of the current descent column. The
// past-the-edge columns are what matter for the fan: it turns down into its
// target well left of the node's right edge, so a feeder that descends just past
// that edge runs clear of the fan. Candidates are kept inside the route's own
// source -> target span so the descent never backtracks past its target, and
// ordered by how little they move the existing descent so the route takes the
// smallest detour that clears. Columns that do not help are discarded by the
// obstacle and graze checks, so this only narrows to the cleanest option.
func policyCanvasVerticalDescentLanes(
  route: PolicyCanvasEdgeRoute,
  obstacles: [CGRect],
  lineSpacing: CGFloat
) -> [CGFloat] {
  guard let sourceX = route.points.first?.x, let targetX = route.points.last?.x else {
    return []
  }
  let lowSpan = min(sourceX, targetX) - 0.5
  let highSpan = max(sourceX, targetX) + 0.5
  let baseVerticalX = policyCanvasDominantVerticalLaneCoordinate(route) ?? sourceX
  var lanes: [CGFloat] = []
  func add(_ value: CGFloat) {
    guard value >= lowSpan, value <= highSpan,
      !lanes.contains(where: { abs($0 - value) < 0.5 })
    else {
      return
    }
    lanes.append(value)
  }
  let margin = max(lineSpacing, PolicyCanvasLayout.gridSize)
  for obstacle in obstacles {
    add(obstacle.maxX + margin)
    add(obstacle.minX - margin)
  }
  for delta in [1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7] {
    add(baseVerticalX + (CGFloat(delta) * lineSpacing))
  }
  return lanes.sorted { abs($0 - baseVerticalX) < abs($1 - baseVerticalX) }
}

// Longest run over which `route` and `rival` share an axis-aligned lane within
// `spacing` of each other - the length they read as one colliding line.
private func policyCanvasRouteGrazes(
  _ route: PolicyCanvasEdgeRoute,
  rivals: [PolicyCanvasEdgeRoute],
  spacing: CGFloat,
  minOverlap: CGFloat
) -> Bool {
  for rival in rivals
  where policyCanvasMaxParallelOverlap(route, rival, spacing: spacing) >= minOverlap {
    return true
  }
  return false
}

private func policyCanvasMaxParallelOverlap(
  _ left: PolicyCanvasEdgeRoute,
  _ right: PolicyCanvasEdgeRoute,
  spacing: CGFloat
) -> CGFloat {
  var best: CGFloat = 0
  for (a0, a1) in zip(left.points, left.points.dropFirst()) {
    for (b0, b1) in zip(right.points, right.points.dropFirst()) {
      if abs(a0.y - a1.y) < 0.5, abs(b0.y - b1.y) < 0.5, abs(a0.y - b0.y) < spacing {
        best = max(
          best, min(max(a0.x, a1.x), max(b0.x, b1.x)) - max(min(a0.x, a1.x), min(b0.x, b1.x)))
      }
      if abs(a0.x - a1.x) < 0.5, abs(b0.x - b1.x) < 0.5, abs(a0.x - b0.x) < spacing {
        best = max(
          best, min(max(a0.y, a1.y), max(b0.y, b1.y)) - max(min(a0.y, a1.y), min(b0.y, b1.y)))
      }
    }
  }
  return best
}
