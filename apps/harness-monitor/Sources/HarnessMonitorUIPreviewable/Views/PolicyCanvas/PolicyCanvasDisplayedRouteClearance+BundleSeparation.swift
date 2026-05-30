import SwiftUI

func policyCanvasBundledDisplayedRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance],
  baseMetrics: PolicyCanvasRouteMetrics,
  currentScore: CGFloat
) -> PolicyCanvasEdgeRoute {
  let bundlePreviousRoutes = previousRoutes.filter {
    policyCanvasRoutesMayShareInteriorCorridor(
      edge: request.edge,
      corridorKey: request.corridorHint?.key,
      with: $0.edge,
      otherCorridorKey: $0.corridorKey
    )
  }
  let conflictingPreviousRoutes = previousRoutes.filter {
    !policyCanvasRoutesMayShareInteriorCorridor(
      edge: request.edge,
      corridorKey: request.corridorHint?.key,
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
  var bestRoute = route
  var bestScore = currentScore
  var horizontalCandidateLanes: [CGFloat] = []
  if let corridorLane = request.corridorHint?.horizontalLaneY {
    horizontalCandidateLanes.append(corridorLane)
  }
  for siblingLane in bundlePreviousRoutes.compactMap({
    policyCanvasDominantHorizontalLaneCoordinate($0.route)
  }) where !horizontalCandidateLanes.contains(where: { abs($0 - siblingLane) < 0.5 }) {
    horizontalCandidateLanes.append(siblingLane)
  }
  var verticalCandidateLanes: [CGFloat] = []
  if let corridorLane = request.corridorHint?.verticalLaneX {
    verticalCandidateLanes.append(corridorLane)
  }
  // Bundle-ordinal-staggered X: for an N-sibling bundle, hand the bundle
  // an X centered symmetrically around the hint via the edge's
  // bundleOrdinal/bundleSize, so the family converges on hint X +/- a
  // lineSpacing step instead of stacking N-1 steps below it.
  if let hint = request.corridorHint, let corridorLane = hint.verticalLaneX, hint.bundleSize > 1 {
    let centeredOrdinal = CGFloat(hint.bundleOrdinal) - CGFloat(hint.bundleSize - 1) / 2.0
    let ordinalLane = corridorLane + centeredOrdinal * request.lineSpacing
    if !verticalCandidateLanes.contains(where: { abs($0 - ordinalLane) < 0.5 }) {
      verticalCandidateLanes.append(ordinalLane)
    }
  }
  for siblingLane in bundlePreviousRoutes.compactMap({
    policyCanvasDominantVerticalLaneCoordinate($0.route)
  }) where !verticalCandidateLanes.contains(where: { abs($0 - siblingLane) < 0.5 }) {
    verticalCandidateLanes.append(siblingLane)
  }
  guard !horizontalCandidateLanes.isEmpty || !verticalCandidateLanes.isEmpty else {
    return route
  }
  for candidate in policyCanvasAlignedBundleCandidates(
    route: route,
    horizontalLanes: horizontalCandidateLanes,
    verticalLanes: verticalCandidateLanes
  ) where !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
    let candidateMinimumSpacing = policyCanvasRouteMinimumSpacing(
      request: request, route: candidate)
    guard
      !conflictingPreviousRoutes.contains(where: { previousRoute in
        policyCanvasRouteViolatesMinimumSpacing(
          candidate,
          with: [previousRoute.route],
          minimumSpacing: min(candidateMinimumSpacing, previousRoute.minimumSpacing)
        )
      })
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

func policyCanvasSeparatedIncompatibleDisplayedRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance],
  baseMetrics: PolicyCanvasRouteMetrics
) -> PolicyCanvasEdgeRoute {
  let incompatiblePreviousRoutes = previousRoutes.filter { previousRoute in
    !policyCanvasRoutesMayShareInteriorCorridor(
      edge: request.edge,
      corridorKey: request.corridorHint?.key,
      with: previousRoute.edge,
      otherCorridorKey: previousRoute.corridorKey
    )
  }
  guard !incompatiblePreviousRoutes.isEmpty else {
    return route
  }

  let previousPolylines = incompatiblePreviousRoutes.map(\.route)
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let currentCost = policyCanvasRouteMaxIncompatibleParallelCost(
    route,
    with: previousPolylines,
    minimumSpacing: minimumSpacing
  )
  guard currentCost > 0.001 else {
    return route
  }

  var bestRoute = route
  var bestCost = currentCost
  var bestScore = policyCanvasDisplayedRouteCandidateScore(
    route,
    request: request,
    previousRoutes: previousRoutes,
    offset: .zero,
    baseMetrics: baseMetrics
  )

  let baseLane =
    policyCanvasDominantHorizontalLaneCoordinate(route)
    ?? request.corridorHint?.horizontalLaneY
  guard let baseLane else {
    return route
  }

  let targetSide = policyCanvasRouteTargetSide(route) ?? request.targetAnchor.side
  let horizontalCandidates = policyCanvasSeparationHorizontalLanes(
    request: request,
    baseLane: baseLane,
    targetSide: targetSide
  )
  let candidateRoutes = policyCanvasSeparationCandidateRoutes(
    route,
    horizontalCandidates: horizontalCandidates,
    targetSide: targetSide
  )
  var seen: Set<[CGPoint]> = []
  for candidate in candidateRoutes
  where seen.insert(candidate.points).inserted
    && !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles)
  {
    let cost = policyCanvasRouteMaxIncompatibleParallelCost(
      candidate,
      with: previousPolylines,
      minimumSpacing: minimumSpacing
    )
    let score = policyCanvasDisplayedRouteCandidateScore(
      candidate,
      request: request,
      previousRoutes: previousRoutes,
      offset: .zero,
      baseMetrics: baseMetrics
    )
    if cost + 0.001 < bestCost || (abs(cost - bestCost) < 0.001 && score < bestScore) {
      bestRoute = candidate
      bestCost = cost
      bestScore = score
      if bestCost < 0.001 {
        break
      }
    }
  }

  return bestRoute
}

// Horizontal lane offsets the separation pass tries when an incompatible route
// runs near-parallel: a +/- lineSpacing ladder off the base lane plus the
// target-local corridor lanes, deduped.
private func policyCanvasSeparationHorizontalLanes(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  baseLane: CGFloat,
  targetSide: PolicyCanvasPortSide
) -> [CGFloat] {
  var horizontalCandidates: [CGFloat] = []
  for delta in [1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7] {
    let candidateLane = baseLane + (CGFloat(delta) * request.lineSpacing)
    if !horizontalCandidates.contains(where: { abs($0 - candidateLane) < 0.5 }) {
      horizontalCandidates.append(candidateLane)
    }
  }
  for targetLane in policyCanvasTargetLocalHorizontalCorridorLanes(
    request: request,
    targetSide: targetSide
  ) where !horizontalCandidates.contains(where: { abs($0 - targetLane) < 0.5 }) {
    horizontalCandidates.append(targetLane)
  }
  return horizontalCandidates
}

// Builds the separation candidate routes for each lane: the bundle-aligned
// route and the target-local terminal handoff route, when each exists.
private func policyCanvasSeparationCandidateRoutes(
  _ route: PolicyCanvasEdgeRoute,
  horizontalCandidates: [CGFloat],
  targetSide: PolicyCanvasPortSide
) -> [PolicyCanvasEdgeRoute] {
  var candidateRoutes: [PolicyCanvasEdgeRoute] = []
  candidateRoutes.reserveCapacity(horizontalCandidates.count * 2)
  for lane in horizontalCandidates {
    if let aligned = policyCanvasAlignedHorizontalBundleRoute(route, targetY: lane) {
      candidateRoutes.append(aligned)
    }
    if let handoff = policyCanvasTargetLocalHorizontalTerminalHandoffRoute(
      route,
      targetY: lane,
      targetSide: targetSide
    ) {
      candidateRoutes.append(handoff)
    }
  }
  return candidateRoutes
}

func policyCanvasTargetLocalHorizontalDisplayedRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  guard
    let targetSide = policyCanvasRouteTargetSide(route),
    let targetLocalLane = policyCanvasLateTargetLocalHorizontalCorridorLanes(
      request: request,
      targetSide: targetSide
    ).first
  else {
    return route
  }
  let routeContext = policyCanvasRouteContext(for: request)
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let currentScore =
    policyCanvasRouteIntrinsicScore(route)
    + policyCanvasDisplayedRouteCorridorPenalty(route, context: routeContext)
    + policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing)
  var bestRoute = route
  var bestScore = currentScore + 30_000
  let currentMetrics = policyCanvasRouteMetrics(route)
  let currentDistance =
    abs((policyCanvasRouteFinalHorizontalBeforeTargetY(route) ?? targetLocalLane) - targetLocalLane)
  let candidates = [
    policyCanvasAlignedHorizontalBundleRoute(route, targetY: targetLocalLane),
    policyCanvasTargetLocalHorizontalTerminalHandoffRoute(
      route,
      targetY: targetLocalLane,
      targetSide: targetSide
    ),
  ].compactMap { $0 }
  for candidate in candidates {
    if policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
      continue
    }
    let candidateMetrics = policyCanvasRouteMetrics(candidate)
    let candidateDistance =
      abs(
        (policyCanvasRouteFinalHorizontalBeforeTargetY(candidate) ?? targetLocalLane)
          - targetLocalLane)
    let candidateScore =
      policyCanvasRouteIntrinsicScore(candidate)
      + policyCanvasDisplayedRouteCorridorPenalty(candidate, context: routeContext)
      + policyCanvasRouteArtifactPenalty(candidate, minimumSpacing: minimumSpacing)
    let distanceImprovement = currentDistance - candidateDistance
    let acceptsAdditionalBends =
      candidateMetrics.bends <= currentMetrics.bends
      || distanceImprovement >= request.lineSpacing
    if candidateDistance + 0.5 < currentDistance,
      candidateScore <= bestScore,
      acceptsAdditionalBends
    {
      bestScore = candidateScore
      bestRoute = candidate
    }
  }
  return bestRoute
}

private func policyCanvasTargetLocalHorizontalTerminalHandoffRoute(
  _ route: PolicyCanvasEdgeRoute,
  targetY: CGFloat,
  targetSide: PolicyCanvasPortSide
) -> PolicyCanvasEdgeRoute? {
  guard
    route.points.count >= 4,
    targetSide == .top || targetSide == .bottom,
    let sourceSide = policyCanvasRouteSourceSide(route),
    let existingTargetSide = policyCanvasRouteTargetSide(route),
    existingTargetSide == targetSide
  else {
    return nil
  }
  let target = route.points[route.points.count - 1]
  let finalApproach = route.points[route.points.count - 2]
  let horizontalStart = route.points[route.points.count - 3]
  guard
    abs(finalApproach.x - target.x) < 0.001,
    abs(horizontalStart.y - finalApproach.y) < 0.001,
    abs(horizontalStart.x - finalApproach.x) >= PolicyCanvasLayout.gridSize * 8
  else {
    return nil
  }
  let handoffLead = max(PolicyCanvasLayout.nodeSize.width / 2, PolicyCanvasLayout.gridSize * 4)
  let handoffX: CGFloat
  if horizontalStart.x < finalApproach.x {
    handoffX = max(horizontalStart.x + handoffLead, finalApproach.x - handoffLead)
  } else {
    handoffX = min(horizontalStart.x - handoffLead, finalApproach.x + handoffLead)
  }
  guard abs(handoffX - finalApproach.x) >= PolicyCanvasLayout.gridSize * 2 else {
    return nil
  }

  var points = Array(route.points.dropLast(2))
  points.append(CGPoint(x: handoffX, y: finalApproach.y))
  points.append(CGPoint(x: handoffX, y: targetY))
  points.append(CGPoint(x: target.x, y: targetY))
  points.append(target)
  let compressed = PolicyCanvasVisibilityRouter.compressCollinear(points)
  let candidate = PolicyCanvasEdgeRoute(
    points: compressed,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
  )
  guard
    policyCanvasRouteIsOrthogonal(candidate),
    policyCanvasRouteSourceSide(candidate) == sourceSide,
    policyCanvasRouteTargetSide(candidate) == targetSide
  else {
    return nil
  }
  return candidate
}

private func policyCanvasRouteFinalHorizontalBeforeTargetY(
  _ route: PolicyCanvasEdgeRoute
) -> CGFloat? {
  guard route.points.count >= 3 else {
    return nil
  }
  let start = route.points[route.points.count - 3]
  let end = route.points[route.points.count - 2]
  guard abs(start.y - end.y) < 0.001, abs(start.x - end.x) > 0.001 else {
    return nil
  }
  return start.y
}
