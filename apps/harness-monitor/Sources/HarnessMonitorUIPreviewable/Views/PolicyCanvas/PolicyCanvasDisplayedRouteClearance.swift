import SwiftUI

struct PolicyCanvasDisplayedRouteClearance {
  let edge: PolicyCanvasEdge
  let corridorKey: PolicyCanvasRouteCorridorKey?
  let route: PolicyCanvasEdgeRoute
  let minimumSpacing: CGFloat
}

func policyCanvasCollisionAwareDisplayedRoute(
  _ request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance]
) -> PolicyCanvasEdgeRoute {
  let baseRoute = policyCanvasTargetLocalHorizontalDisplayedRoute(
    policyCanvasPreferredCorridorDisplayedRoute(
      policyCanvasDisplayedRoute(request),
      request: request
    ),
    request: request
  )
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
    return policyCanvasTargetLocalSidePortApproachRoute(best.route, request: request)
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
  // After the retry sweep, re-test the corridor-aligned candidate against the
  // best retry result. Otherwise a portMarkerLayout-shifted A* sometimes
  // discards the corridor-facing source side entirely and the retry pool
  // never re-emits a candidate at the hint X.
  for corridorCandidateRoute in policyCanvasCorridorAlignedCandidates(request: request) {
    if policyCanvasRouteIntersectsObstacles(corridorCandidateRoute, obstacles: request.obstacles) {
      continue
    }
    let score = policyCanvasDisplayedRouteCandidateScore(
      corridorCandidateRoute,
      request: request,
      previousRoutes: previousRoutes,
      offset: .zero,
      baseMetrics: baseMetrics
    )
    if score < best.score {
      best = (corridorCandidateRoute, score)
    }
  }
  let bundledRoute = policyCanvasBundledDisplayedRoute(
    best.route,
    request: request,
    previousRoutes: previousRoutes,
    baseMetrics: baseMetrics,
    currentScore: best.score
  )
  let separatedRoute = policyCanvasSeparatedIncompatibleDisplayedRoute(
    bundledRoute,
    request: request,
    previousRoutes: previousRoutes,
    baseMetrics: baseMetrics
  )
  let targetLocalRoute = policyCanvasTargetLocalHorizontalDisplayedRoute(
    separatedRoute,
    request: request
  )
  return policyCanvasTargetLocalSidePortApproachRoute(
    policyCanvasSeparatedIncompatibleDisplayedRoute(
      targetLocalRoute,
      request: request,
      previousRoutes: previousRoutes,
      baseMetrics: baseMetrics
    ),
    request: request
  )
}

private func policyCanvasDisplayedRouteHasHardDefect(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance]
) -> Bool {
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let comparisonKey = policyCanvasCorridorComparisonKey(
    hint: request.corridorHint, lineSpacing: request.lineSpacing)
  let bundlePreviousRoutes = previousRoutes.filter {
    policyCanvasRoutesMayShareInteriorCorridor(
      edge: request.edge,
      corridorKey: comparisonKey,
      with: $0.edge,
      otherCorridorKey: $0.corridorKey
    )
  }
  let conflictingPreviousRoutes = previousRoutes.filter {
    !policyCanvasRoutesMayShareInteriorCorridor(
      edge: request.edge,
      corridorKey: comparisonKey,
      with: $0.edge,
      otherCorridorKey: $0.corridorKey
    )
      && policyCanvasRoutesRequirePairwiseSpacing(
        edge: request.edge,
        route: route,
        with: $0.edge,
        otherRoute: $0.route
      )
  }
  let incompatibleOverlap = policyCanvasRouteMaxInteriorSharedOverlap(
    route,
    with: conflictingPreviousRoutes.map(\.route)
  )
  return policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing) > 0
    || policyCanvasRouteIntersectsObstacles(route, obstacles: request.obstacles)
    || !policyCanvasRouteUsesPreferredCorridor(
      route, context: policyCanvasRouteContext(for: request))
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
    || incompatibleOverlap > 0.001
}

func policyCanvasDisplayedRouteCandidateScore(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance],
  offset: PolicyCanvasRouteRetryOffset,
  baseMetrics: PolicyCanvasRouteMetrics
) -> CGFloat {
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let routeContext = policyCanvasRouteContext(for: request)
  let comparisonKey = policyCanvasCorridorComparisonKey(
    hint: request.corridorHint, lineSpacing: request.lineSpacing)
  let preferredFamilyRoutes = previousRoutes.filter {
    policyCanvasRoutesPreferSharedTransportFamily(
      edge: request.edge,
      corridorKey: comparisonKey,
      with: $0.edge,
      otherCorridorKey: $0.corridorKey
    )
  }
  let sourceFamilyRoutes = previousRoutes.filter {
    policyCanvasRoutesPreferSharedSourceDepartureFamily(
      edge: request.edge,
      corridorKey: comparisonKey,
      with: $0.edge,
      otherCorridorKey: $0.corridorKey
    )
  }
  let conflictingPreviousRoutes = previousRoutes.filter {
    !policyCanvasRoutesMayShareInteriorCorridor(
      edge: request.edge,
      corridorKey: comparisonKey,
      with: $0.edge,
      otherCorridorKey: $0.corridorKey
    )
      && policyCanvasRoutesRequirePairwiseSpacing(
        edge: request.edge,
        route: route,
        with: $0.edge,
        otherRoute: $0.route
      )
  }
  let conflictPenalty = policyCanvasDisplayedRouteConflictPenalty(
    route,
    request: request,
    conflictingPreviousRoutes: conflictingPreviousRoutes,
    minimumSpacing: minimumSpacing
  )
  let usesPreferredCorridor = policyCanvasRouteUsesPreferredCorridor(route, context: routeContext)
  let sharedBundleBonus: CGFloat =
    usesPreferredCorridor
      && policyCanvasRouteSharesInteriorCorridor(
        route,
        with: preferredFamilyRoutes.map(\.route)
      )
    ? -80_000
    : 0
  let siblingBusPenalty = policyCanvasSiblingBundleBusPenalty(
    route,
    with: usesPreferredCorridor ? preferredFamilyRoutes.map(\.route) : []
  )
  let sourceDeparturePenalty = policyCanvasSourceFamilyDeparturePenalty(
    route,
    with: usesPreferredCorridor ? sourceFamilyRoutes.map(\.route) : [],
    minimumSeparation: max(request.lineSpacing, PolicyCanvasLayout.gridSize)
  )
  return policyCanvasRouteIntrinsicScore(route)
    + policyCanvasDisplayedRouteCorridorPenalty(route, context: routeContext)
    + conflictPenalty
    + sharedBundleBonus
    + siblingBusPenalty
    + sourceDeparturePenalty
    + policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing)
    + policyCanvasRouteDetourPenalty(route, baseMetrics: baseMetrics)
    + offset.penalty
}

// Sum of the spacing, hard-violation, obstacle, and incompatible-overlap
// penalties a candidate accrues against the previous routes it conflicts with.
private func policyCanvasDisplayedRouteConflictPenalty(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  conflictingPreviousRoutes: [PolicyCanvasDisplayedRouteClearance],
  minimumSpacing: CGFloat
) -> CGFloat {
  let previousPolylines = conflictingPreviousRoutes.map(\.route)
  let incompatibleOverlap = policyCanvasRouteMaxInteriorSharedOverlap(
    route,
    with: previousPolylines
  )
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
  let obstaclePenalty: CGFloat =
    policyCanvasRouteIntersectsObstacles(route, obstacles: request.obstacles)
    ? 50_000_000
    : 0
  let incompatibleOverlapPenalty: CGFloat =
    incompatibleOverlap > 0.001
    ? 8_000_000 + (incompatibleOverlap * 200_000)
    : 0
  return spacingPenalty + hardViolationPenalty + obstaclePenalty + incompatibleOverlapPenalty
}

// Curated retry-offset ladder. The list is deliberately not a Cartesian
// product over (lane, sourceFanout, targetFanout) - those combinations
// would explode the candidate count and most do not produce visually
// distinct routes. The chosen 14 entries cover the high-yield permutations
// (single-axis nudges first, then a small multi-axis blend, then larger
// step sizes) in an order tuned to surface improvements earliest.
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

func policyCanvasRouteIntrinsicScore(_ route: PolicyCanvasEdgeRoute) -> CGFloat {
  let metrics = policyCanvasRouteMetrics(route)
  guard metrics.segmentCount > 0 else {
    // Empty/degenerate routes must always lose min-selection. Use the same
    // sentinel as policyCanvasDisplayedRouteScore so the two codepaths stay
    // aligned and a future real-route score increase can never overtake it.
    return .greatestFiniteMagnitude
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
