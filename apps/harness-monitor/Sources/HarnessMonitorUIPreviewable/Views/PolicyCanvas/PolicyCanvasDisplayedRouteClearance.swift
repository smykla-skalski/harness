import SwiftUI

struct PolicyCanvasDisplayedRouteClearance {
  let edge: PolicyCanvasEdge
  let route: PolicyCanvasEdgeRoute
  let minimumSpacing: CGFloat
}

func policyCanvasCollisionAwareDisplayedRoute(
  _ request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance]
) -> PolicyCanvasEdgeRoute {
  let baseRoute = policyCanvasDisplayedRoute(request)
  guard !previousRoutes.isEmpty else {
    return baseRoute
  }
  let baseMetrics = policyCanvasRouteMetrics(baseRoute)

  let baseScore = policyCanvasDisplayedRouteCandidateScore(
    baseRoute,
    request: request,
    previousRoutes: previousRoutes,
    offset: .zero,
    baseMetrics: baseMetrics
  )
  var best = (route: baseRoute, score: baseScore)
  guard
    policyCanvasDisplayedRouteHasHardDefect(
      baseRoute,
      request: request,
      previousRoutes: previousRoutes
    )
  else {
    return best.route
  }

  for offset in policyCanvasRouteRetryOffsets() {
    for candidate in policyCanvasDisplayedRouteCandidates(request, offset: offset) {
      let score = policyCanvasDisplayedRouteCandidateScore(
        candidate.route,
        request: request,
        previousRoutes: previousRoutes,
        offset: offset,
        baseMetrics: baseMetrics
      )
      if score < best.score {
        best = (candidate.route, score)
      }
    }
  }
  return policyCanvasBundledDisplayedRoute(
    best.route,
    request: request,
    previousRoutes: previousRoutes,
    baseMetrics: baseMetrics,
    currentScore: best.score
  )
}

private func policyCanvasDisplayedRouteHasHardDefect(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance]
) -> Bool {
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let bundlePreviousRoutes = previousRoutes.filter {
    policyCanvasRoutesMayShareInteriorCorridor(request.edge, with: $0.edge)
  }
  let conflictingPreviousRoutes = previousRoutes.filter {
    !policyCanvasRoutesMayShareInteriorCorridor(request.edge, with: $0.edge)
  }
  return policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing) > 0
    || policyCanvasHorizontalBandPenalty(route) > 0
    || (!bundlePreviousRoutes.isEmpty
      && !policyCanvasRouteSharesInteriorCorridor(
        route,
        with: bundlePreviousRoutes.map(\.route)
      ))
    || conflictingPreviousRoutes.contains { previousRoute in
      policyCanvasRouteViolatesMinimumSpacing(
        route,
        with: [previousRoute.route],
        minimumSpacing: min(minimumSpacing, previousRoute.minimumSpacing)
      )
    }
}

private func policyCanvasDisplayedRouteCandidateScore(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance],
  offset: PolicyCanvasRouteRetryOffset,
  baseMetrics: PolicyCanvasRouteMetrics
) -> CGFloat {
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let bundlePreviousRoutes = previousRoutes.filter {
    policyCanvasRoutesMayShareInteriorCorridor(request.edge, with: $0.edge)
  }
  let conflictingPreviousRoutes = previousRoutes.filter {
    !policyCanvasRoutesMayShareInteriorCorridor(request.edge, with: $0.edge)
  }
  let previousPolylines = conflictingPreviousRoutes.map(\.route)
  let spacingPenalty = conflictingPreviousRoutes.reduce(0) { total, previousRoute in
    total
      + policyCanvasRouteSpacingPenalty(
        route,
        with: [previousRoute.route],
        minimumSpacing: min(minimumSpacing, previousRoute.minimumSpacing)
      )
  }
  let hardViolationPenalty: CGFloat =
    policyCanvasRouteViolatesMinimumSpacing(
      route,
      with: previousPolylines,
      minimumSpacing: minimumSpacing
    )
    ? 4_000_000
    : 0
  let sharedBundleBonus: CGFloat =
    policyCanvasRouteSharesInteriorCorridor(
      route,
      with: bundlePreviousRoutes.map(\.route)
    )
    ? -250_000
    : 0
  let siblingBusPenalty = policyCanvasSiblingBundleBusPenalty(
    route,
    with: bundlePreviousRoutes.map(\.route)
  )
  return policyCanvasRouteIntrinsicScore(route)
    + policyCanvasHorizontalBandPenalty(route)
    + spacingPenalty
    + hardViolationPenalty
    + sharedBundleBonus
    + siblingBusPenalty
    + policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing)
    + policyCanvasRouteDetourPenalty(route, baseMetrics: baseMetrics)
    + offset.penalty
}

private func policyCanvasRouteRetryOffsets() -> [PolicyCanvasRouteRetryOffset] {
  [
    .zero,
    PolicyCanvasRouteRetryOffset(routeLaneDelta: 1),
    PolicyCanvasRouteRetryOffset(sourceFanoutDelta: 1),
    PolicyCanvasRouteRetryOffset(targetFanoutDelta: 1),
    PolicyCanvasRouteRetryOffset(routeLaneDelta: 1, sourceFanoutDelta: 1, targetFanoutDelta: 1),
    PolicyCanvasRouteRetryOffset(routeLaneDelta: 2),
    PolicyCanvasRouteRetryOffset(sourceFanoutDelta: 2),
    PolicyCanvasRouteRetryOffset(targetFanoutDelta: 2),
    PolicyCanvasRouteRetryOffset(routeLaneDelta: 2, sourceFanoutDelta: 1, targetFanoutDelta: 1),
    PolicyCanvasRouteRetryOffset(routeLaneDelta: 3),
    PolicyCanvasRouteRetryOffset(sourceFanoutDelta: 3),
    PolicyCanvasRouteRetryOffset(targetFanoutDelta: 3),
    PolicyCanvasRouteRetryOffset(routeLaneDelta: 3, sourceFanoutDelta: 2, targetFanoutDelta: 2),
    PolicyCanvasRouteRetryOffset(routeLaneDelta: 4, sourceFanoutDelta: 1, targetFanoutDelta: 1),
  ]
}

private func policyCanvasRouteIntrinsicScore(_ route: PolicyCanvasEdgeRoute) -> CGFloat {
  let metrics = policyCanvasRouteMetrics(route)
  guard metrics.segmentCount > 0 else {
    return 100_000_000
  }
  return metrics.length + (CGFloat(metrics.bends) * PolicyCanvasVisibilityRouter.bendPenalty)
}

private func policyCanvasRouteDetourPenalty(
  _ route: PolicyCanvasEdgeRoute,
  baseMetrics: PolicyCanvasRouteMetrics
) -> CGFloat {
  let metrics = policyCanvasRouteMetrics(route)
  let lengthLimit = max(baseMetrics.length * 1.75, baseMetrics.length + 700)
  var penalty: CGFloat = 0
  if metrics.length > lengthLimit {
    penalty += 2_000_000 + ((metrics.length - lengthLimit) * 7_500)
  }
  let bendLimit = baseMetrics.bends + 4
  if metrics.bends > bendLimit {
    penalty += CGFloat(metrics.bends - bendLimit) * 350_000
  }
  return penalty
}

private func policyCanvasRoutesMayShareInteriorCorridor(
  _ edge: PolicyCanvasEdge,
  with otherEdge: PolicyCanvasEdge
) -> Bool {
  edge.target == otherEdge.target
}

private func policyCanvasSiblingBundleBusPenalty(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute]
) -> CGFloat {
  guard
    let lane = policyCanvasDominantHorizontalLaneCoordinate(route)
  else {
    return 0
  }
  let siblingLanes = previousRoutes.compactMap(policyCanvasDominantHorizontalLaneCoordinate)
  guard !siblingLanes.isEmpty else {
    return 0
  }
  let nearestDistance = siblingLanes.map { abs($0 - lane) }.min() ?? 0
  return nearestDistance * 12_000
}

private func policyCanvasBundledDisplayedRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance],
  baseMetrics: PolicyCanvasRouteMetrics,
  currentScore: CGFloat
) -> PolicyCanvasEdgeRoute {
  let bundlePreviousRoutes = previousRoutes.filter {
    policyCanvasRoutesMayShareInteriorCorridor(request.edge, with: $0.edge)
  }
  guard !bundlePreviousRoutes.isEmpty else {
    return route
  }

  var bestRoute = route
  var bestScore = currentScore
  for siblingLane in bundlePreviousRoutes.compactMap({ policyCanvasDominantHorizontalLaneCoordinate($0.route) }) {
    guard
      let candidate = policyCanvasAlignedHorizontalBundleRoute(route, targetY: siblingLane),
      !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles)
    else {
      continue
    }
    let score = policyCanvasDisplayedRouteCandidateScore(
      candidate,
      request: request,
      previousRoutes: previousRoutes,
      offset: .zero,
      baseMetrics: baseMetrics
    )
    if score < bestScore {
      bestScore = score
      bestRoute = candidate
    }
  }
  return bestRoute
}

private func policyCanvasAlignedHorizontalBundleRoute(
  _ route: PolicyCanvasEdgeRoute,
  targetY: CGFloat
) -> PolicyCanvasEdgeRoute? {
  guard let dominant = policyCanvasDominantHorizontalSegment(route),
    abs(dominant.y - targetY) > 0.5
  else {
    return nil
  }

  var points = route.points
  points[dominant.index].y = targetY
  points[dominant.index + 1].y = targetY
  let compressed = PolicyCanvasVisibilityRouter.compressCollinear(points)
  return PolicyCanvasEdgeRoute(
    points: compressed,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
  )
}

private func policyCanvasDominantHorizontalSegment(
  _ route: PolicyCanvasEdgeRoute
) -> (index: Int, y: CGFloat, length: CGFloat)? {
  guard route.points.count >= 4 else {
    return nil
  }
  var best: (index: Int, y: CGFloat, length: CGFloat)?
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    guard abs(start.y - end.y) < 0.001 else {
      continue
    }
    let length = abs(end.x - start.x)
    if best.map({ length > $0.length }) ?? true {
      best = (index, start.y, length)
    }
  }
  return best
}

private func policyCanvasRouteIntersectsObstacles(
  _ route: PolicyCanvasEdgeRoute,
  obstacles: [CGRect]
) -> Bool {
  policyCanvasInteriorRouteSegments(route).contains { segment in
    obstacles.contains { obstacle in
      policyCanvasRouteSegment(segment, intersects: obstacle)
    }
  }
}

private func policyCanvasRouteSegment(
  _ segment: PolicyCanvasRouteSegment,
  intersects rect: CGRect
) -> Bool {
  if segment.isHorizontal {
    let xRange = min(segment.start.x, segment.end.x)...max(segment.start.x, segment.end.x)
    return rect.minY < segment.start.y
      && rect.maxY > segment.start.y
      && max(0, min(xRange.upperBound, rect.maxX) - max(xRange.lowerBound, rect.minX)) > 0.001
  }
  if segment.isVertical {
    let yRange = min(segment.start.y, segment.end.y)...max(segment.start.y, segment.end.y)
    return rect.minX < segment.start.x
      && rect.maxX > segment.start.x
      && max(0, min(yRange.upperBound, rect.maxY) - max(yRange.lowerBound, rect.minY)) > 0.001
  }
  return false
}

private func policyCanvasRouteArtifactPenalty(
  _ route: PolicyCanvasEdgeRoute,
  minimumSpacing: CGFloat
) -> CGFloat {
  var penalty: CGFloat = 0
  let minimumSegmentLength = max(
    PolicyCanvasVisibilityRouter.channelStep * 2,
    min(minimumSpacing / 2, PolicyCanvasLayout.portDiameter)
  )
  for (start, end) in zip(route.points, route.points.dropFirst()) {
    let dx = abs(end.x - start.x)
    let dy = abs(end.y - start.y)
    if dx > 0.001, dy > 0.001 {
      penalty += 50_000_000
    }
    let length = dx + dy
    if length > 0.001, length < minimumSegmentLength {
      penalty += 10_000_000 + ((minimumSegmentLength - length) * 100_000)
    }
  }
  return penalty
}
