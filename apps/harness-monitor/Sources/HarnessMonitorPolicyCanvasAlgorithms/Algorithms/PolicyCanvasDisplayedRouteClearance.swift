import SwiftUI

public struct PolicyCanvasDisplayedRouteClearance {
  public let edge: PolicyCanvasEdge
  public let corridorKey: PolicyCanvasRouteCorridorKey?
  public let route: PolicyCanvasEdgeRoute
  public let minimumSpacing: CGFloat

  public init(
    edge: PolicyCanvasEdge,
    corridorKey: PolicyCanvasRouteCorridorKey?,
    route: PolicyCanvasEdgeRoute,
    minimumSpacing: CGFloat
  ) {
    self.edge = edge
    self.corridorKey = corridorKey
    self.route = route
    self.minimumSpacing = minimumSpacing
  }
}

struct PolicyCanvasDisplayedRouteCachedClearance {
  let clearance: PolicyCanvasDisplayedRouteClearance
  let segments: [PolicyCanvasRouteSegment]
  let interiorSegments: [PolicyCanvasRouteSegment]

  init(_ clearance: PolicyCanvasDisplayedRouteClearance) {
    self.clearance = clearance
    segments = policyCanvasRouteSegments(clearance.route)
    interiorSegments = policyCanvasInteriorRouteSegments(clearance.route)
  }
}

struct PolicyCanvasDisplayedRoutePreviousRoutePartition {
  let edge: PolicyCanvasEdge
  let comparisonKey: PolicyCanvasRouteCorridorKey?
  let bundleRoutes: [PolicyCanvasDisplayedRouteCachedClearance]
  let bundlePolylines: [PolicyCanvasEdgeRoute]
  let preferredFamilyPolylines: [PolicyCanvasEdgeRoute]
  let sourceFamilyPolylines: [PolicyCanvasEdgeRoute]
  let incompatibleRoutes: [PolicyCanvasDisplayedRouteCachedClearance]
  let incompatiblePolylines: [PolicyCanvasEdgeRoute]

  init(
    request: PolicyCanvasResolvedDisplayedRouteRequest,
    previousRoutes: [PolicyCanvasDisplayedRouteCachedClearance]
  ) {
    let comparisonKey = policyCanvasCorridorComparisonKey(
      hint: request.corridorHint,
      lineSpacing: request.lineSpacing
    )
    let bundleRoutes = previousRoutes.filter {
      policyCanvasRoutesMayShareInteriorCorridor(
        edge: request.edge,
        corridorKey: comparisonKey,
        with: $0.clearance.edge,
        otherCorridorKey: $0.clearance.corridorKey
      )
    }
    let bundlePolylines = bundleRoutes.map { $0.clearance.route }
    let preferredFamilyPolylines = previousRoutes.filter {
      policyCanvasRoutesPreferSharedTransportFamily(
        edge: request.edge,
        corridorKey: comparisonKey,
        with: $0.clearance.edge,
        otherCorridorKey: $0.clearance.corridorKey
      )
    }.map { $0.clearance.route }
    let sourceFamilyPolylines = previousRoutes.filter {
      policyCanvasRoutesPreferSharedSourceDepartureFamily(
        edge: request.edge,
        corridorKey: comparisonKey,
        with: $0.clearance.edge,
        otherCorridorKey: $0.clearance.corridorKey
      )
    }.map { $0.clearance.route }
    let incompatibleRoutes = previousRoutes.filter {
      !policyCanvasRoutesMayShareInteriorCorridor(
        edge: request.edge,
        corridorKey: comparisonKey,
        with: $0.clearance.edge,
        otherCorridorKey: $0.clearance.corridorKey
      )
    }
    let incompatiblePolylines = incompatibleRoutes.map { $0.clearance.route }

    self.edge = request.edge
    self.comparisonKey = comparisonKey
    self.bundleRoutes = bundleRoutes
    self.bundlePolylines = bundlePolylines
    self.preferredFamilyPolylines = preferredFamilyPolylines
    self.sourceFamilyPolylines = sourceFamilyPolylines
    self.incompatibleRoutes = incompatibleRoutes
    self.incompatiblePolylines = incompatiblePolylines
  }

  func conflictingRoutes(
    for route: PolicyCanvasEdgeRoute
  ) -> [PolicyCanvasDisplayedRouteCachedClearance] {
    return incompatibleRoutes.filter {
      policyCanvasRoutesRequirePairwiseSpacing(
        edge: edge,
        route: route,
        with: $0.clearance.edge,
        otherRoute: $0.clearance.route
      )
    }
  }
}

public func policyCanvasCollisionAwareDisplayedRoute(
  _ request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance]
) -> PolicyCanvasEdgeRoute {
  policyCanvasCollisionAwareDisplayedRoute(
    request,
    previousRoutes: previousRoutes.map(PolicyCanvasDisplayedRouteCachedClearance.init)
  )
}

func policyCanvasCollisionAwareDisplayedRoute(
  _ request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteCachedClearance]
) -> PolicyCanvasEdgeRoute {
  let previousRoutePartition = PolicyCanvasDisplayedRoutePreviousRoutePartition(
    request: request,
    previousRoutes: previousRoutes
  )
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
    previousRoutePartition: previousRoutePartition,
    offset: .zero,
    baseMetrics: baseMetrics
  )
  var best = (route: baseRoute, score: baseScore)
  guard
    policyCanvasDisplayedRouteHasHardDefect(
      baseRoute,
      request: request,
      previousRoutePartition: previousRoutePartition
    )
  else {
    return policyCanvasTargetLocalVerticalPortApproachRoute(
      policyCanvasTargetLocalSidePortApproachRoute(
        best.route,
        request: request,
        previousRoutePartition: previousRoutePartition
      ),
      request: request
    )
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
      previousRoutePartition: previousRoutePartition,
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
    previousRoutePartition: previousRoutePartition,
    baseMetrics: baseMetrics,
    currentScore: best.score
  )
  let separatedRoute = policyCanvasSeparatedIncompatibleDisplayedRoute(
    bundledRoute,
    request: request,
    previousRoutePartition: previousRoutePartition,
    baseMetrics: baseMetrics
  )
  let targetLocalRoute = policyCanvasTargetLocalHorizontalDisplayedRoute(
    separatedRoute,
    request: request
  )
  let secondSeparatedRoute = policyCanvasSeparatedIncompatibleDisplayedRoute(
    targetLocalRoute,
    request: request,
    previousRoutePartition: previousRoutePartition,
    baseMetrics: baseMetrics
  )
  let sidePortRoute = policyCanvasTargetLocalSidePortApproachRoute(
    secondSeparatedRoute,
    request: request,
    previousRoutePartition: previousRoutePartition
  )
  return policyCanvasTargetLocalVerticalPortApproachRoute(
    sidePortRoute,
    request: request
  )
}

private func policyCanvasDisplayedRouteHasHardDefect(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutePartition: PolicyCanvasDisplayedRoutePreviousRoutePartition
) -> Bool {
  let routeSegments = policyCanvasRouteSegments(route)
  let interiorSegments = policyCanvasInteriorRouteSegments(route)
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let conflictingPreviousRoutes = previousRoutePartition.conflictingRoutes(for: route)
  let conflictingInteriorSegments = conflictingPreviousRoutes.map(\.interiorSegments)
  let incompatibleOverlap = policyCanvasRouteMaxInteriorSharedOverlap(
    interiorSegments: interiorSegments,
    with: conflictingInteriorSegments
  )
  return policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing) > 0
    || policyCanvasRouteIntersectsObstacles(route, obstacles: request.obstacles)
    || (!previousRoutePartition.bundlePolylines.isEmpty
      && !policyCanvasRouteSharesInteriorCorridor(
        route,
        with: previousRoutePartition.bundlePolylines
      ))
    || conflictingPreviousRoutes.contains { previousRoute in
      policyCanvasRouteViolatesMinimumSpacing(
        segments: routeSegments,
        with: [previousRoute.segments],
        minimumSpacing: min(minimumSpacing, previousRoute.clearance.minimumSpacing)
      )
    }
    || incompatibleOverlap > 0.001
}

func policyCanvasDisplayedRouteCandidateScore(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutePartition: PolicyCanvasDisplayedRoutePreviousRoutePartition,
  offset: PolicyCanvasRouteRetryOffset,
  baseMetrics: PolicyCanvasRouteMetrics
) -> CGFloat {
  let routeMetrics = policyCanvasRouteMetrics(route)
  let routeSegments = policyCanvasRouteSegments(route)
  let interiorSegments = policyCanvasInteriorRouteSegments(route)
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let routeContext = policyCanvasRouteContext(for: request)
  let conflictingPreviousRoutes = previousRoutePartition.conflictingRoutes(for: route)
  let conflictPenalty = policyCanvasDisplayedRouteConflictPenalty(
    route,
    routeSegments: routeSegments,
    interiorSegments: interiorSegments,
    request: request,
    conflictingPreviousRoutes: conflictingPreviousRoutes,
    minimumSpacing: minimumSpacing
  )
  let usesPreferredCorridor = policyCanvasRouteUsesPreferredCorridor(route, context: routeContext)
  let sharedBundleBonus: CGFloat =
    usesPreferredCorridor
      && policyCanvasRouteSharesInteriorCorridor(
        route,
        with: previousRoutePartition.preferredFamilyPolylines
      )
    ? -80_000
    : 0
  let siblingBusPenalty = policyCanvasSiblingBundleBusPenalty(
    route,
    with: usesPreferredCorridor ? previousRoutePartition.preferredFamilyPolylines : []
  )
  let sourceDeparturePenalty = policyCanvasSourceFamilyDeparturePenalty(
    route,
    with: usesPreferredCorridor ? previousRoutePartition.sourceFamilyPolylines : [],
    minimumSeparation: max(request.lineSpacing, PolicyCanvasLayout.gridSize)
  )
  return policyCanvasRouteIntrinsicScore(metrics: routeMetrics)
    + policyCanvasDisplayedRouteCorridorPenalty(route, context: routeContext)
    + conflictPenalty
    + sharedBundleBonus
    + siblingBusPenalty
    + sourceDeparturePenalty
    + policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing)
    + policyCanvasRouteDetourPenalty(metrics: routeMetrics, baseMetrics: baseMetrics)
    + offset.penalty
}

// Sum of the spacing, hard-violation, obstacle, and incompatible-overlap
// penalties a candidate accrues against the previous routes it conflicts with.
private func policyCanvasDisplayedRouteConflictPenalty(
  _ route: PolicyCanvasEdgeRoute,
  routeSegments: [PolicyCanvasRouteSegment],
  interiorSegments: [PolicyCanvasRouteSegment],
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  conflictingPreviousRoutes: [PolicyCanvasDisplayedRouteCachedClearance],
  minimumSpacing: CGFloat
) -> CGFloat {
  let conflictingRouteSegments = conflictingPreviousRoutes.map(\.segments)
  let conflictingInteriorSegments = conflictingPreviousRoutes.map(\.interiorSegments)
  let incompatibleOverlap = policyCanvasRouteMaxInteriorSharedOverlap(
    interiorSegments: interiorSegments,
    with: conflictingInteriorSegments
  )
  let spacingPenalty = conflictingPreviousRoutes.reduce(0) { total, previousRoute in
    total
      + policyCanvasRouteSpacingPenalty(
        segments: routeSegments,
        with: [previousRoute.segments],
        minimumSpacing: min(minimumSpacing, previousRoute.clearance.minimumSpacing)
      )
  }
  let hardViolationPenalty: CGFloat =
    policyCanvasRouteViolatesMinimumSpacing(
      segments: routeSegments,
      with: conflictingRouteSegments,
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
  policyCanvasRouteIntrinsicScore(metrics: policyCanvasRouteMetrics(route))
}

func policyCanvasRouteIntrinsicScore(metrics: PolicyCanvasRouteMetrics) -> CGFloat {
  guard metrics.segmentCount > 0 else {
    // Empty/degenerate routes must always lose min-selection. Use the same
    // sentinel as policyCanvasDisplayedRouteScore so the two codepaths stay
    // aligned and a future real-route score increase can never overtake it.
    return .greatestFiniteMagnitude
  }
  return metrics.length + (CGFloat(metrics.bends) * PolicyCanvasVisibilityRouter.bendPenalty)
}

private func policyCanvasRouteDetourPenalty(
  metrics: PolicyCanvasRouteMetrics,
  baseMetrics: PolicyCanvasRouteMetrics
) -> CGFloat {
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
