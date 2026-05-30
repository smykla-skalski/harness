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
  return nil
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
