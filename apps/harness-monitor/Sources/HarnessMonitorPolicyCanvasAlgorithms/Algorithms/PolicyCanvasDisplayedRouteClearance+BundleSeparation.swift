import SwiftUI

func policyCanvasBundledDisplayedRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  previousRoutePartition: PolicyCanvasDisplayedRoutePreviousRoutePartition,
  baseMetrics: PolicyCanvasRouteMetrics,
  currentScore: CGFloat
) -> PolicyCanvasEdgeRoute {
  let conflictingPreviousRoutes = previousRoutePartition.conflictingRoutes(for: route)
  var bestRoute = route
  var bestScore = currentScore
  var horizontalCandidateLanes: [CGFloat] = []
  if let corridorLane = request.corridorHint?.horizontalLaneY {
    horizontalCandidateLanes.append(corridorLane)
  }
  for siblingLane in previousRoutePartition.bundlePolylines.compactMap({
    policyCanvasDominantHorizontalLaneCoordinate($0)
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
  for siblingLane in previousRoutePartition.bundlePolylines.compactMap({
    policyCanvasDominantVerticalLaneCoordinate($0)
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
    let candidateSegments = policyCanvasRouteSegments(candidate)
    let candidateMinimumSpacing = policyCanvasRouteMinimumSpacing(
      request: request, route: candidate)
    guard
      !conflictingPreviousRoutes.contains(where: { previousRoute in
        policyCanvasRouteViolatesMinimumSpacing(
          segments: candidateSegments,
          with: [previousRoute.segments],
          minimumSpacing: min(candidateMinimumSpacing, previousRoute.clearance.minimumSpacing)
        )
      })
    else {
      continue
    }
    let score = policyCanvasDisplayedRouteCandidateScore(
      candidate,
      request: request,
      previousRoutePartition: previousRoutePartition,
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
  previousRoutePartition: PolicyCanvasDisplayedRoutePreviousRoutePartition,
  baseMetrics: PolicyCanvasRouteMetrics
) -> PolicyCanvasEdgeRoute {
  guard !previousRoutePartition.incompatiblePolylines.isEmpty else {
    return route
  }

  let previousInteriorSegments = previousRoutePartition.incompatibleRoutes.map(\.interiorSegments)
  let minimumSpacing = policyCanvasRouteMinimumSpacing(request: request, route: route)
  let currentInteriorSegments = policyCanvasInteriorRouteSegments(route)
  let currentCost = policyCanvasRouteMaxIncompatibleParallelCost(
    segments: currentInteriorSegments,
    with: previousInteriorSegments,
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
    previousRoutePartition: previousRoutePartition,
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
  let sourceSide = policyCanvasRouteSourceSide(route) ?? request.sourceAnchor.side
  let sourceDepartureCost = policyCanvasRouteMaxIncompatibleParallelCost(
    segments: policyCanvasSourceDepartureVerticalSegments(route),
    with: previousInteriorSegments,
    minimumSpacing: minimumSpacing
  )
  let horizontalCandidates = policyCanvasSeparationHorizontalLanes(
    request: request,
    baseLane: baseLane,
    targetSide: targetSide
  )
  let candidateRoutes = policyCanvasSeparationCandidateRoutes(
    route,
    horizontalCandidates: horizontalCandidates,
    includesSourceHandoffCandidates:
      sourceDepartureCost + 0.001 >= currentCost * 0.9
      && policyCanvasSourceDepartureNeedsAdditionalHandoff(route, sourceSide: sourceSide)
      && policyCanvasRouteHasNearLevelEndpoints(route),
    sourceSide: sourceSide,
    targetSide: targetSide,
    lineSpacing: request.lineSpacing
  )
  var seen: Set<[CGPoint]> = []
  for candidate in candidateRoutes
  where seen.insert(candidate.points).inserted
    && !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles)
  {
    let candidateInteriorSegments = policyCanvasInteriorRouteSegments(candidate)
    let cost = policyCanvasRouteMaxIncompatibleParallelCost(
      segments: candidateInteriorSegments,
      with: previousInteriorSegments,
      minimumSpacing: minimumSpacing
    )
    let score = policyCanvasDisplayedRouteCandidateScore(
      candidate,
      request: request,
      previousRoutePartition: previousRoutePartition,
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
  for delta in [1, -1, 2, -2, 3, -3, 4, -4] {
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
  includesSourceHandoffCandidates: Bool,
  sourceSide: PolicyCanvasPortSide,
  targetSide: PolicyCanvasPortSide,
  lineSpacing: CGFloat
) -> [PolicyCanvasEdgeRoute] {
  var candidateRoutes: [PolicyCanvasEdgeRoute] = []
  candidateRoutes.reserveCapacity(horizontalCandidates.count * 4)
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
  if includesSourceHandoffCandidates {
    candidateRoutes.append(
      contentsOf: policyCanvasSourcePortHandoffColumnCandidates(
        route,
        sourceSide: sourceSide,
        lineSpacing: lineSpacing
      )
    )
  }
  candidateRoutes.append(
    contentsOf: policyCanvasSidePortHandoffColumnCandidates(
      route,
      targetSide: targetSide,
      lineSpacing: lineSpacing
    )
  )
  return candidateRoutes
}

private func policyCanvasSourceDepartureVerticalSegments(
  _ route: PolicyCanvasEdgeRoute
) -> [PolicyCanvasRouteSegment] {
  let segments = policyCanvasRouteSegments(route)
  guard !segments.isEmpty else {
    return []
  }
  if segments[0].isVertical {
    return [segments[0]]
  }
  guard segments.count > 1, segments[0].isHorizontal, segments[1].isVertical else {
    return []
  }
  return [segments[1]]
}

private func policyCanvasSourceDepartureNeedsAdditionalHandoff(
  _ route: PolicyCanvasEdgeRoute,
  sourceSide: PolicyCanvasPortSide
) -> Bool {
  guard sourceSide == .leading || sourceSide == .trailing else {
    return false
  }
  guard route.points.count >= 3 else {
    return false
  }
  let source = route.points[0]
  let stubEnd = route.points[1]
  let jogEnd = route.points[2]
  guard
    abs(source.y - stubEnd.y) < 0.001, abs(source.x - stubEnd.x) > 0.001,
    abs(stubEnd.x - jogEnd.x) < 0.001, abs(stubEnd.y - jogEnd.y) > 0.001
  else {
    return false
  }
  let minimumHandoff = max(PolicyCanvasLayout.nodeSize.width / 2, PolicyCanvasLayout.gridSize * 4)
  return abs(stubEnd.x - source.x) + 0.5 < minimumHandoff
}

private func policyCanvasRouteHasNearLevelEndpoints(_ route: PolicyCanvasEdgeRoute) -> Bool {
  guard let source = route.points.first, let target = route.points.last else {
    return false
  }
  return abs(target.y - source.y) <= PolicyCanvasLayout.nodeSize.height
}

private func policyCanvasSourcePortHandoffColumnCandidates(
  _ route: PolicyCanvasEdgeRoute,
  sourceSide: PolicyCanvasPortSide,
  lineSpacing: CGFloat
) -> [PolicyCanvasEdgeRoute] {
  guard sourceSide == .leading || sourceSide == .trailing else {
    return []
  }
  guard route.points.count >= 4 else {
    return []
  }
  let source = route.points[0]
  let stubEnd = route.points[1]
  let jogEnd = route.points[2]
  let corridorEnd = route.points[3]
  guard
    abs(source.y - stubEnd.y) < 0.001, abs(source.x - stubEnd.x) > 0.001,
    abs(stubEnd.x - jogEnd.x) < 0.001, abs(stubEnd.y - jogEnd.y) > 0.001,
    abs(jogEnd.y - corridorEnd.y) < 0.001, abs(jogEnd.x - corridorEnd.x) > 0.001
  else {
    return []
  }

  let targetSide = policyCanvasRouteTargetSide(route)
  let minimumHandoff = max(PolicyCanvasLayout.nodeSize.width / 2, PolicyCanvasLayout.gridSize * 4)
  let step = max(lineSpacing, PolicyCanvasLayout.gridSize)
  var candidates: [PolicyCanvasEdgeRoute] = []
  for delta in [1, -1, 2, -2, 3, -3] {
    let handoffX = jogEnd.x + (CGFloat(delta) * step)
    switch sourceSide {
    case .leading:
      guard handoffX + PolicyCanvasLayout.gridSize * 2 < source.x else {
        continue
      }
      guard source.x - handoffX >= minimumHandoff else {
        continue
      }
    case .trailing:
      guard handoffX - PolicyCanvasLayout.gridSize * 2 > source.x else {
        continue
      }
      guard handoffX - source.x >= minimumHandoff else {
        continue
      }
    case .top, .bottom:
      continue
    }
    guard (handoffX - source.x).sign == (corridorEnd.x - source.x).sign else {
      continue
    }
    var points = route.points
    points[1] = CGPoint(x: handoffX, y: stubEnd.y)
    points[2] = CGPoint(x: handoffX, y: jogEnd.y)
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
      continue
    }
    candidates.append(candidate)
  }
  return candidates
}

private func policyCanvasSidePortHandoffColumnCandidates(
  _ route: PolicyCanvasEdgeRoute,
  targetSide: PolicyCanvasPortSide,
  lineSpacing: CGFloat
) -> [PolicyCanvasEdgeRoute] {
  guard targetSide == .leading || targetSide == .trailing else {
    return []
  }
  let count = route.points.count
  guard count >= 5 else {
    return []
  }
  let target = route.points[count - 1]
  let stubStart = route.points[count - 2]
  let jogStart = route.points[count - 3]
  let exitStart = route.points[count - 4]
  guard
    abs(stubStart.y - target.y) < 0.001, abs(stubStart.x - target.x) > 0.001,
    abs(jogStart.x - stubStart.x) < 0.001, abs(jogStart.y - stubStart.y) > 0.001,
    abs(exitStart.y - jogStart.y) < 0.001, abs(exitStart.x - jogStart.x) > 0.001
  else {
    return []
  }

  let sourceSide = policyCanvasRouteSourceSide(route)
  let minimumHandoff = max(PolicyCanvasLayout.nodeSize.width / 2, PolicyCanvasLayout.gridSize * 4)
  let step = max(lineSpacing, PolicyCanvasLayout.gridSize)
  var candidates: [PolicyCanvasEdgeRoute] = []
  for delta in [1, -1, 2, -2, 3, -3] {
    let handoffX = jogStart.x + (CGFloat(delta) * step)
    switch targetSide {
    case .leading:
      guard handoffX + PolicyCanvasLayout.gridSize * 2 < target.x else {
        continue
      }
      guard target.x - handoffX >= minimumHandoff else {
        continue
      }
    case .trailing:
      guard handoffX - PolicyCanvasLayout.gridSize * 2 > target.x else {
        continue
      }
      guard handoffX - target.x >= minimumHandoff else {
        continue
      }
    case .top, .bottom:
      continue
    }
    guard (handoffX - exitStart.x).sign == (target.x - exitStart.x).sign else {
      continue
    }
    var points = route.points
    points[count - 3] = CGPoint(x: handoffX, y: jogStart.y)
    points[count - 2] = CGPoint(x: handoffX, y: stubStart.y)
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
      continue
    }
    candidates.append(candidate)
  }
  return candidates
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
  let currentMetrics = policyCanvasRouteMetrics(route)
  let currentScore =
    policyCanvasRouteIntrinsicScore(metrics: currentMetrics)
    + policyCanvasDisplayedRouteCorridorPenalty(route, context: routeContext)
    + policyCanvasRouteArtifactPenalty(route, minimumSpacing: minimumSpacing)
  var bestRoute = route
  var bestScore = currentScore + 30_000
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
      policyCanvasRouteIntrinsicScore(metrics: candidateMetrics)
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
