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
  return policyCanvasTargetLocalHorizontalDisplayedRoute(
    policyCanvasBundledDisplayedRoute(
      best.route,
      request: request,
      previousRoutes: previousRoutes,
      baseMetrics: baseMetrics,
      currentScore: best.score
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
}

private func policyCanvasDisplayedRouteCandidateScore(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutes: [PolicyCanvasDisplayedRouteClearance],
  offset: PolicyCanvasRouteRetryOffset,
  baseMetrics: PolicyCanvasRouteMetrics
) -> CGFloat {
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let routeContext = policyCanvasRouteContext(for: request)
  let preferredFamilyRoutes = previousRoutes.filter {
    policyCanvasRoutesPreferSharedTransportFamily(
      edge: request.edge,
      corridorKey: request.corridorHint?.key,
      with: $0.edge,
      otherCorridorKey: $0.corridorKey
    )
  }
  let sourceFamilyRoutes = previousRoutes.filter {
    policyCanvasRoutesPreferSharedSourceDepartureFamily(
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
  let obstaclePenalty: CGFloat =
    policyCanvasRouteIntersectsObstacles(route, obstacles: request.obstacles)
    ? 50_000_000
    : 0
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
    with: usesPreferredCorridor ? sourceFamilyRoutes.map(\.route) : []
  )
  return policyCanvasRouteIntrinsicScore(route)
    + policyCanvasDisplayedRouteCorridorPenalty(route, context: routeContext)
    + spacingPenalty
    + hardViolationPenalty
    + obstaclePenalty
    + sharedBundleBonus
    + siblingBusPenalty
    + sourceDeparturePenalty
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
  edge: PolicyCanvasEdge,
  corridorKey: PolicyCanvasRouteCorridorKey?,
  with otherEdge: PolicyCanvasEdge,
  otherCorridorKey: PolicyCanvasRouteCorridorKey?
) -> Bool {
  if let corridorKey, let otherCorridorKey {
    return corridorKey == otherCorridorKey
  }
  if corridorKey == nil && otherCorridorKey == nil {
    return edge.target == otherEdge.target
  }
  return false
}

private func policyCanvasRoutesPreferSharedTransportFamily(
  edge: PolicyCanvasEdge,
  corridorKey: PolicyCanvasRouteCorridorKey?,
  with otherEdge: PolicyCanvasEdge,
  otherCorridorKey: PolicyCanvasRouteCorridorKey?
) -> Bool {
  policyCanvasRoutesMayShareInteriorCorridor(
    edge: edge,
    corridorKey: corridorKey,
    with: otherEdge,
    otherCorridorKey: otherCorridorKey
  )
    || (edge.source == otherEdge.source && edge.target == otherEdge.target)
}

private func policyCanvasRoutesPreferSharedSourceDepartureFamily(
  edge: PolicyCanvasEdge,
  corridorKey: PolicyCanvasRouteCorridorKey?,
  with otherEdge: PolicyCanvasEdge,
  otherCorridorKey: PolicyCanvasRouteCorridorKey?
) -> Bool {
  guard
    edge.source.nodeID == otherEdge.source.nodeID,
    let corridorKey,
    let otherCorridorKey,
    corridorKey.sourceScopeID == otherCorridorKey.sourceScopeID
  else {
    return false
  }
  return true
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

private func policyCanvasSourceFamilyDeparturePenalty(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute]
) -> CGFloat {
  guard let departureBus = policyCanvasPrimaryDepartureBus(route) else {
    return 0
  }
  let siblingCoordinates = previousRoutes.compactMap { previousRoute -> CGFloat? in
    guard let siblingDepartureBus = policyCanvasPrimaryDepartureBus(previousRoute),
      siblingDepartureBus.axis == departureBus.axis
    else {
      return nil
    }
    return siblingDepartureBus.coordinate
  }
  guard !siblingCoordinates.isEmpty else {
    return 0
  }
  let nearestDistance = siblingCoordinates.map { abs($0 - departureBus.coordinate) }.min() ?? 0
  return nearestDistance * 18_000
}

private func policyCanvasPrimaryDepartureBus(
  _ route: PolicyCanvasEdgeRoute
) -> (axis: PolicyCanvasSegmentAxis, coordinate: CGFloat)? {
  guard route.points.count >= 4 else {
    return nil
  }
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    if abs(start.y - end.y) < 0.001, abs(start.x - end.x) > 0.001 {
      return (.horizontal, start.y)
    }
    if abs(start.x - end.x) < 0.001, abs(start.y - end.y) > 0.001 {
      return (.vertical, start.x)
    }
  }
  return nil
}

private func policyCanvasBundledDisplayedRoute(
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
  }) {
    if !horizontalCandidateLanes.contains(where: { abs($0 - siblingLane) < 0.5 }) {
      horizontalCandidateLanes.append(siblingLane)
    }
  }
  var verticalCandidateLanes: [CGFloat] = []
  if let corridorLane = request.corridorHint?.verticalLaneX {
    verticalCandidateLanes.append(corridorLane)
  }
  for siblingLane in bundlePreviousRoutes.compactMap({
    policyCanvasDominantVerticalLaneCoordinate($0.route)
  }) {
    if !verticalCandidateLanes.contains(where: { abs($0 - siblingLane) < 0.5 }) {
      verticalCandidateLanes.append(siblingLane)
    }
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

private func policyCanvasTargetLocalHorizontalDisplayedRoute(
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
    let candidateMetrics = policyCanvasRouteMetrics(candidate)
    let candidateDistance =
      abs((policyCanvasRouteFinalHorizontalBeforeTargetY(candidate) ?? targetLocalLane) - targetLocalLane)
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

private func policyCanvasPreferredCorridorDisplayedRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  guard let corridorHint = request.corridorHint else {
    return route
  }
  let routeContext = policyCanvasRouteContext(for: request)
  let routeScore =
    policyCanvasRouteIntrinsicScore(route)
    + policyCanvasDisplayedRouteCorridorPenalty(route, context: routeContext)
  var bestRoute = route
  var bestScore = routeScore
  let sourceSide = policyCanvasRouteSourceSide(route) ?? request.sourceAnchor.side
  let targetSide = policyCanvasRouteTargetSide(route) ?? request.targetAnchor.side
  if let candidate = policyCanvasAlignedCorridorIntersectionRoute(
    request: request,
    sourceSide: sourceSide,
    targetSide: targetSide
  ), !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
    let candidateScore =
      policyCanvasRouteIntrinsicScore(candidate)
      + policyCanvasDisplayedRouteCorridorPenalty(candidate, context: routeContext)
    if candidateScore <= bestScore {
      bestScore = candidateScore
      bestRoute = candidate
    }
  }
  if let candidate = policyCanvasAlignedVerticalDominantCorridorRoute(
    request: request,
    sourceSide: sourceSide,
    targetSide: targetSide
  ), !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
    let candidateScore =
      policyCanvasRouteIntrinsicScore(candidate)
      + policyCanvasDisplayedRouteCorridorPenalty(candidate, context: routeContext)
    if candidateScore <= bestScore {
      bestScore = candidateScore
      bestRoute = candidate
    }
  }
  if !policyCanvasRouteUsesPreferredCorridor(bestRoute, context: routeContext) {
    for routeLaneDelta in 1...3 {
      for candidate in policyCanvasDisplayedRouteCandidates(
        request,
        offset: PolicyCanvasRouteRetryOffset(routeLaneDelta: routeLaneDelta)
      ).map(\.route)
      where !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
        let candidateScore =
          policyCanvasRouteIntrinsicScore(candidate)
          + policyCanvasDisplayedRouteCorridorPenalty(candidate, context: routeContext)
        if candidateScore <= bestScore {
          bestScore = candidateScore
          bestRoute = candidate
        }
      }
    }
  }
  var preferredHorizontalLanes: [CGFloat] = [corridorHint.horizontalLaneY]
  for candidateLane in policyCanvasTargetLocalHorizontalCorridorLanes(
    request: request,
    targetSide: targetSide
  ) where !preferredHorizontalLanes.contains(where: { abs($0 - candidateLane) < 0.5 }) {
    preferredHorizontalLanes.append(candidateLane)
  }
  for candidate in policyCanvasAlignedBundleCandidates(
    route: bestRoute,
    horizontalLanes: preferredHorizontalLanes,
    verticalLanes: corridorHint.verticalLaneX.map { [$0] } ?? []
  ) where !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
    let candidateScore =
      policyCanvasRouteIntrinsicScore(candidate)
      + policyCanvasDisplayedRouteCorridorPenalty(candidate, context: routeContext)
    if candidateScore <= bestScore {
      bestScore = candidateScore
      bestRoute = candidate
    }
  }
  if let targetLocalHorizontalLane =
    policyCanvasTargetLocalHorizontalCorridorLanes(
      request: request,
      targetSide: policyCanvasRouteTargetSide(bestRoute) ?? targetSide
    ).first,
    let candidate = policyCanvasAlignedHorizontalBundleRoute(
      bestRoute,
      targetY: targetLocalHorizontalLane
    ),
    !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles)
  {
    let candidateScore =
      policyCanvasRouteIntrinsicScore(candidate)
      + policyCanvasDisplayedRouteCorridorPenalty(candidate, context: routeContext)
    let currentDistance =
      abs((policyCanvasDominantHorizontalLaneCoordinate(bestRoute) ?? targetLocalHorizontalLane)
        - targetLocalHorizontalLane)
    let candidateDistance =
      abs((policyCanvasDominantHorizontalLaneCoordinate(candidate) ?? targetLocalHorizontalLane)
        - targetLocalHorizontalLane)
    if candidateDistance + 0.5 < currentDistance,
      candidateScore <= bestScore + 30_000
    {
      bestScore = candidateScore
      bestRoute = candidate
    }
  }
  return bestRoute
}

private func policyCanvasTargetLocalHorizontalCorridorLanes(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  targetSide: PolicyCanvasPortSide
) -> [CGFloat] {
  policyCanvasTargetLocalHorizontalCorridorLanes(
    request: request,
    targetSide: targetSide,
    targetReferencePoint: request.target
  )
}

private func policyCanvasLateTargetLocalHorizontalCorridorLanes(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  targetSide: PolicyCanvasPortSide
) -> [CGFloat] {
  let baseLanes = policyCanvasTargetLocalHorizontalCorridorLanes(
    request: request,
    targetSide: targetSide
  )
  let anchorAwareLanes = policyCanvasTargetLocalHorizontalCorridorLanes(
    request: request,
    targetSide: targetSide,
    targetReferencePoint: policyCanvasTargetLocalReferencePoint(
      request: request,
      targetSide: targetSide
    )
  )
  var lanes: [CGFloat] = []
  lanes.reserveCapacity(anchorAwareLanes.count + baseLanes.count)
  for lane in anchorAwareLanes + baseLanes
  where !lanes.contains(where: { abs($0 - lane) < 0.5 }) {
    lanes.append(lane)
  }
  return lanes
}

private func policyCanvasTargetLocalHorizontalCorridorLanes(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  targetSide: PolicyCanvasPortSide,
  targetReferencePoint: CGPoint
) -> [CGFloat] {
  guard let corridorHint = request.corridorHint else {
    return []
  }
  let offset = max(request.lineSpacing * 1.5, PolicyCanvasLayout.gridSize * 2)
  switch targetSide {
  case .top:
    let lane = min(corridorHint.horizontalLaneY, targetReferencePoint.y - offset)
    return lane < targetReferencePoint.y - 0.5 ? [lane] : []
  case .bottom:
    let lane = max(corridorHint.horizontalLaneY, targetReferencePoint.y + offset)
    return lane > targetReferencePoint.y + 0.5 ? [lane] : []
  case .leading, .trailing:
    return []
  }
}

private func policyCanvasTargetLocalReferencePoint(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  targetSide: PolicyCanvasPortSide
) -> CGPoint {
  if request.targetAnchor.side == targetSide {
    return request.targetAnchor.point
  }
  return request.target
}

private func policyCanvasRoutesRequirePairwiseSpacing(
  edge: PolicyCanvasEdge,
  route: PolicyCanvasEdgeRoute,
  with otherEdge: PolicyCanvasEdge,
  otherRoute: PolicyCanvasEdgeRoute
) -> Bool {
  let sharedNodeIDs = Set([
    edge.source.nodeID == otherEdge.source.nodeID ? edge.source.nodeID : nil,
    edge.source.nodeID == otherEdge.target.nodeID ? edge.source.nodeID : nil,
    edge.target.nodeID == otherEdge.source.nodeID ? edge.target.nodeID : nil,
    edge.target.nodeID == otherEdge.target.nodeID ? edge.target.nodeID : nil,
  ].compactMap { $0 })
  guard !sharedNodeIDs.isEmpty else {
    return true
  }
  for sharedNodeID in sharedNodeIDs {
    guard
      let routeSide = policyCanvasRouteSide(for: edge, nodeID: sharedNodeID, route: route),
      let otherRouteSide = policyCanvasRouteSide(
        for: otherEdge,
        nodeID: sharedNodeID,
        route: otherRoute
      )
    else {
      continue
    }
    if routeSide != otherRouteSide {
      return false
    }
  }
  if edge.source.nodeID == otherEdge.source.nodeID {
    let oppositeAxisDepartureBias =
      (policyCanvasRouteHasStrongVerticalBias(route)
        && policyCanvasRouteHasStrongHorizontalBias(otherRoute))
      || (policyCanvasRouteHasStrongHorizontalBias(route)
        && policyCanvasRouteHasStrongVerticalBias(otherRoute))
    if oppositeAxisDepartureBias {
      return false
    }
  }
  return true
}

private func policyCanvasRouteSide(
  for edge: PolicyCanvasEdge,
  nodeID: String,
  route: PolicyCanvasEdgeRoute
) -> PolicyCanvasPortSide? {
  if edge.source.nodeID == nodeID {
    return policyCanvasRouteSourceSide(route)
  }
  if edge.target.nodeID == nodeID {
    return policyCanvasRouteTargetSide(route)
  }
  return nil
}

private func policyCanvasRouteHasStrongVerticalBias(_ route: PolicyCanvasEdgeRoute) -> Bool {
  guard let source = route.points.first, let target = route.points.last else {
    return false
  }
  return abs(target.y - source.y) >= abs(target.x - source.x) * 2
}

private func policyCanvasRouteHasStrongHorizontalBias(_ route: PolicyCanvasEdgeRoute) -> Bool {
  guard let source = route.points.first, let target = route.points.last else {
    return false
  }
  return abs(target.x - source.x) >= abs(target.y - source.y) * 2
}

private func policyCanvasAlignedVerticalDominantCorridorRoute(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  sourceSide: PolicyCanvasPortSide,
  targetSide: PolicyCanvasPortSide
) -> PolicyCanvasEdgeRoute? {
  guard
    let corridorHint = request.corridorHint,
    let verticalLaneX = corridorHint.verticalLaneX
  else {
    return nil
  }
  let sourceAnchor = policyCanvasRouteAnchorCandidateForSide(
    side: sourceSide,
    preferred: request.sourceAnchor,
    candidates: request.sourceCandidates
  )
  let targetAnchor = policyCanvasRouteAnchorCandidateForSide(
    side: targetSide,
    preferred: request.targetAnchor,
    candidates: request.targetCandidates
  )
  let sourceEscape = policyCanvasPortEscapeCandidate(
    from: sourceAnchor.point,
    side: sourceAnchor.side,
    lane: request.sourceFanoutLane,
    lineSpacing: request.lineSpacing
  )
  let targetEscape = policyCanvasPortEscapeCandidate(
    from: targetAnchor.point,
    side: targetAnchor.side,
    lane: request.targetFanoutLane,
    lineSpacing: request.lineSpacing
  )
  let alignedVerticalLaneX: CGFloat =
    abs(targetEscape.routed.x - verticalLaneX) <= max(request.lineSpacing, PolicyCanvasLayout.gridSize)
    ? targetEscape.routed.x
    : verticalLaneX
  let verticalSpan = abs(targetEscape.routed.y - sourceEscape.routed.y)
  let horizontalSpan = abs(targetEscape.routed.x - sourceEscape.routed.x)
  guard
    verticalSpan >= max(PolicyCanvasLayout.nodeSize.height, horizontalSpan * 2),
    abs(targetEscape.routed.x - alignedVerticalLaneX) > 0.5
      || abs(verticalLaneX - alignedVerticalLaneX) > 0.5
  else {
    return nil
  }

  let basePoints = [
    sourceEscape.routed,
    CGPoint(x: alignedVerticalLaneX, y: sourceEscape.routed.y),
    CGPoint(x: alignedVerticalLaneX, y: corridorHint.horizontalLaneY),
    CGPoint(x: targetEscape.routed.x, y: corridorHint.horizontalLaneY),
    targetEscape.routed,
  ]
  let compressedBase = PolicyCanvasVisibilityRouter.compressCollinear(basePoints)
  let baseRoute = PolicyCanvasEdgeRoute(
    points: compressedBase,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressedBase)
  )
  let candidate = policyCanvasBridgedRoute(
    baseRoute: baseRoute,
    source: sourceEscape,
    target: targetEscape
  )
  guard policyCanvasRouteIsOrthogonal(candidate) else {
    return nil
  }
  return candidate
}

private func policyCanvasAlignedHorizontalBundleRoute(
  _ route: PolicyCanvasEdgeRoute,
  targetY: CGFloat
) -> PolicyCanvasEdgeRoute? {
  let originalSourceSide = policyCanvasRouteSourceSide(route)
  let originalTargetSide = policyCanvasRouteTargetSide(route)
  guard let dominant = policyCanvasDominantHorizontalSegment(route),
    abs(dominant.y - targetY) > 0.5
  else {
    return nil
  }

  var points = route.points
  points[dominant.index].y = targetY
  points[dominant.index + 1].y = targetY
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

private func policyCanvasAlignedVerticalBundleRoute(
  _ route: PolicyCanvasEdgeRoute,
  targetX: CGFloat
) -> PolicyCanvasEdgeRoute? {
  let originalSourceSide = policyCanvasRouteSourceSide(route)
  let originalTargetSide = policyCanvasRouteTargetSide(route)
  guard let dominant = policyCanvasDominantVerticalSegment(route),
    abs(dominant.x - targetX) > 0.5
  else {
    return nil
  }

  var points = route.points
  points[dominant.index].x = targetX
  points[dominant.index + 1].x = targetX
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

private func policyCanvasAlignedCorridorIntersectionRoute(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  sourceSide: PolicyCanvasPortSide,
  targetSide: PolicyCanvasPortSide
) -> PolicyCanvasEdgeRoute? {
  guard
    let corridorHint = request.corridorHint,
    let verticalLaneX = corridorHint.verticalLaneX
  else {
    return nil
  }
  let sourceAnchor = policyCanvasRouteAnchorCandidateForSide(
    side: sourceSide,
    preferred: request.sourceAnchor,
    candidates: request.sourceCandidates
  )
  let targetAnchor = policyCanvasRouteAnchorCandidateForSide(
    side: targetSide,
    preferred: request.targetAnchor,
    candidates: request.targetCandidates
  )
  let sourceEscape = policyCanvasPortEscapeCandidate(
    from: sourceAnchor.point,
    side: sourceAnchor.side,
    lane: request.sourceFanoutLane,
    lineSpacing: request.lineSpacing
  )
  let targetEscape = policyCanvasPortEscapeCandidate(
    from: targetAnchor.point,
    side: targetAnchor.side,
    lane: request.targetFanoutLane,
    lineSpacing: request.lineSpacing
  )
  let alignedVerticalLaneX: CGFloat =
    abs(targetEscape.routed.x - verticalLaneX) <= max(request.lineSpacing, PolicyCanvasLayout.gridSize)
    ? targetEscape.routed.x
    : verticalLaneX
  let routeContext = policyCanvasRouteContext(for: request)
  let candidates: [PolicyCanvasEdgeRoute] =
    policyCanvasCorridorIntersectionBaseRoutes(
      request: request,
      source: sourceEscape.routed,
      target: targetEscape.routed,
      verticalLaneX: alignedVerticalLaneX,
      horizontalLaneY: corridorHint.horizontalLaneY
    ).compactMap { basePoints in
      let compressedBase = PolicyCanvasVisibilityRouter.compressCollinear(basePoints)
      let baseRoute = PolicyCanvasEdgeRoute(
        points: compressedBase,
        labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressedBase)
      )
      let candidate = policyCanvasBridgedRoute(
        baseRoute: baseRoute,
        source: sourceEscape,
        target: targetEscape
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
  return candidates.min { left, right in
    let leftScore =
      policyCanvasRouteIntrinsicScore(left)
      + policyCanvasDisplayedRouteCorridorPenalty(left, context: routeContext)
    let rightScore =
      policyCanvasRouteIntrinsicScore(right)
      + policyCanvasDisplayedRouteCorridorPenalty(right, context: routeContext)
    return leftScore < rightScore
  }
}

private func policyCanvasCorridorIntersectionBaseRoutes(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  source: CGPoint,
  target: CGPoint,
  verticalLaneX: CGFloat,
  horizontalLaneY: CGFloat
) -> [[CGPoint]] {
  let manualCandidates = [
    [
      source,
      CGPoint(x: verticalLaneX, y: source.y),
      CGPoint(x: verticalLaneX, y: horizontalLaneY),
      CGPoint(x: target.x, y: horizontalLaneY),
      target,
    ],
    [
      source,
      CGPoint(x: source.x, y: horizontalLaneY),
      CGPoint(x: verticalLaneX, y: horizontalLaneY),
      CGPoint(x: verticalLaneX, y: target.y),
      target,
    ],
  ]

  let junction = CGPoint(x: verticalLaneX, y: horizontalLaneY)
  let firstRoute = request.router.route(
    source: source,
    target: junction,
    context: PolicyCanvasRouteContext(
      lane: request.routeLane,
      groups: request.groups,
      sourceGroupID: request.sourceGroupID,
      targetGroupID: request.targetGroupID,
      obstacles: request.obstacles,
      sourceActual: request.source,
      targetActual: nil,
      lineSpacing: request.lineSpacing
    )
  )
  let secondRoute = request.router.route(
    source: junction,
    target: target,
    context: PolicyCanvasRouteContext(
      lane: request.routeLane,
      groups: request.groups,
      sourceGroupID: request.sourceGroupID,
      targetGroupID: request.targetGroupID,
      obstacles: request.obstacles,
      sourceActual: nil,
      targetActual: request.target,
      lineSpacing: request.lineSpacing
    )
  )
  var routedCandidate: [CGPoint] = []
  for point in firstRoute.points {
    if routedCandidate.last != point {
      routedCandidate.append(point)
    }
  }
  for point in secondRoute.points.dropFirst() {
    if routedCandidate.last != point {
      routedCandidate.append(point)
    }
  }

  return manualCandidates + [routedCandidate]
}

private func policyCanvasRouteAnchorCandidateForSide(
  side: PolicyCanvasPortSide,
  preferred: PolicyCanvasRouteAnchorCandidate,
  candidates: [PolicyCanvasRouteAnchorCandidate]
) -> PolicyCanvasRouteAnchorCandidate {
  candidates.first(where: { $0.side == side }) ?? preferred
}

private func policyCanvasRouteIsOrthogonal(_ route: PolicyCanvasEdgeRoute) -> Bool {
  zip(route.points, route.points.dropFirst()).allSatisfy { start, end in
    abs(start.x - end.x) < 0.001 || abs(start.y - end.y) < 0.001
  }
}

private func policyCanvasAlignedBundleCandidates(
  route: PolicyCanvasEdgeRoute,
  horizontalLanes: [CGFloat],
  verticalLanes: [CGFloat]
) -> [PolicyCanvasEdgeRoute] {
  var candidates: [PolicyCanvasEdgeRoute] = []

  for horizontalLane in horizontalLanes {
    if let candidate = policyCanvasAlignedHorizontalBundleRoute(route, targetY: horizontalLane) {
      candidates.append(candidate)
      for verticalLane in verticalLanes {
        if let aligned = policyCanvasAlignedVerticalBundleRoute(candidate, targetX: verticalLane) {
          candidates.append(aligned)
        }
      }
    }
  }

  for verticalLane in verticalLanes {
    if let candidate = policyCanvasAlignedVerticalBundleRoute(route, targetX: verticalLane) {
      candidates.append(candidate)
      for horizontalLane in horizontalLanes {
        if let aligned = policyCanvasAlignedHorizontalBundleRoute(
          candidate, targetY: horizontalLane)
        {
          candidates.append(aligned)
        }
      }
    }
  }

  var seen: Set<[CGPoint]> = []
  return candidates.filter { candidate in
    seen.insert(candidate.points).inserted
  }
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

private func policyCanvasDominantVerticalSegment(
  _ route: PolicyCanvasEdgeRoute
) -> (index: Int, x: CGFloat, length: CGFloat)? {
  guard route.points.count >= 4 else {
    return nil
  }
  var best: (index: Int, x: CGFloat, length: CGFloat)?
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    guard abs(start.x - end.x) < 0.001 else {
      continue
    }
    let length = abs(end.y - start.y)
    if best.map({ length > $0.length }) ?? true {
      best = (index, start.x, length)
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
