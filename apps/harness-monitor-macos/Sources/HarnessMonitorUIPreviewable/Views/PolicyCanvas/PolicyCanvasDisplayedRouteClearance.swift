import SwiftUI

struct PolicyCanvasDisplayedRouteClearance {
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
  guard policyCanvasDisplayedRouteHasHardDefect(
    baseRoute,
    request: request,
    previousRoutes: previousRoutes
  ) else {
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
  return best.route
}

private func policyCanvasDisplayedRouteHasHardDefect(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance]
) -> Bool {
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  return policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing) > 0
    || previousRoutes.contains { previousRoute in
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
  let previousPolylines = previousRoutes.map(\.route)
  let spacingPenalty = previousRoutes.reduce(0) { total, previousRoute in
    total + policyCanvasRouteSpacingPenalty(
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
  let sharedPathPenalty: CGFloat =
    policyCanvasRouteSharesInteriorCorridor(route, with: previousPolylines)
      ? 12_000_000
      : 0
  return policyCanvasRouteIntrinsicScore(route)
    + spacingPenalty
    + hardViolationPenalty
    + sharedPathPenalty
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
