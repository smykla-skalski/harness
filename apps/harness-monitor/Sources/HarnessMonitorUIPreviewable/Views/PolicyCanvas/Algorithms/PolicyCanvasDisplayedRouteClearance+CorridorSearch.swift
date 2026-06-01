import SwiftUI

func policyCanvasPreferredCorridorDisplayedRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  guard let corridorHint = request.corridorHint else {
    return route
  }
  let context = PolicyCanvasCorridorSearchContext(
    request: request,
    routeContext: policyCanvasRouteContext(for: request),
    corridorHint: corridorHint,
    inputSourceSide: policyCanvasRouteSourceSide(route) ?? request.sourceAnchor.side,
    targetSide: policyCanvasRouteTargetSide(route) ?? request.targetAnchor.side
  )
  var best = PolicyCanvasCorridorRouteSearch(
    route: route,
    score: context.score(route)
  )
  // When a vertical corridor hint exists, generate the corridor candidate
  // using the source side that FACES the corridor X - not the one the A*
  // router happened to pick. The flex-anchor A* often selects bottom-source
  // for diagonal short paths, but a bottom-source route can never naturally
  // dominate at the corridor X; the corridor candidate must come from the
  // side facing the corridor or it produces an awkward U-shape and loses
  // scoring against the cheaper bottom-port path.
  let corridorSourceSides = policyCanvasCorridorAlignedSourceSides(
    inputSide: context.inputSourceSide,
    sourceAnchor: request.sourceAnchor.point,
    corridorHint: corridorHint
  )
  policyCanvasConsiderCorridorIntersectionRoutes(
    into: &best,
    context: context,
    corridorSourceSides: corridorSourceSides
  )
  policyCanvasConsiderCorridorRetryRoutes(into: &best, context: context)
  policyCanvasConsiderCorridorBundleRoutes(into: &best, context: context)
  policyCanvasConsiderCorridorTargetLocalRoute(into: &best, context: context)
  return best.route
}

// Shared inputs for the preferred-corridor candidate search: the resolved
// request, its route context, the corridor hint, and the resolved source/target
// port sides. `score` reproduces the original intrinsic + corridor-penalty sum.
private struct PolicyCanvasCorridorSearchContext {
  let request: PolicyCanvasResolvedDisplayedRouteRequest
  let routeContext: PolicyCanvasRouteContext
  let corridorHint: PolicyCanvasEdgeCorridorHint
  let inputSourceSide: PolicyCanvasPortSide
  let targetSide: PolicyCanvasPortSide

  func score(_ route: PolicyCanvasEdgeRoute) -> CGFloat {
    policyCanvasRouteIntrinsicScore(route)
      + policyCanvasDisplayedRouteCorridorPenalty(route, context: routeContext)
  }
}

// Running best route and score for the preferred-corridor search. `consider`
// adopts a candidate only when it does not worsen the score, matching the
// original `<=` comparisons exactly.
private struct PolicyCanvasCorridorRouteSearch {
  var route: PolicyCanvasEdgeRoute
  var score: CGFloat

  mutating func consider(_ candidate: PolicyCanvasEdgeRoute, score candidateScore: CGFloat) {
    if candidateScore <= score {
      score = candidateScore
      route = candidate
    }
  }
}

private func policyCanvasConsiderCorridorIntersectionRoutes(
  into best: inout PolicyCanvasCorridorRouteSearch,
  context: PolicyCanvasCorridorSearchContext,
  corridorSourceSides: [PolicyCanvasPortSide]
) {
  let request = context.request
  for candidateSourceSide in corridorSourceSides {
    guard
      let candidate = policyCanvasAlignedCorridorIntersectionRoute(
        request: request,
        sourceSide: candidateSourceSide,
        targetSide: context.targetSide
      ),
      !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles)
    else {
      continue
    }
    best.consider(candidate, score: context.score(candidate))
  }
  if let candidate = policyCanvasAlignedVerticalDominantCorridorRoute(
    request: request,
    sourceSide: corridorSourceSides.first ?? context.inputSourceSide,
    targetSide: context.targetSide
  ), !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
    best.consider(candidate, score: context.score(candidate))
  }
}

private func policyCanvasConsiderCorridorRetryRoutes(
  into best: inout PolicyCanvasCorridorRouteSearch,
  context: PolicyCanvasCorridorSearchContext
) {
  guard !policyCanvasRouteUsesPreferredCorridor(best.route, context: context.routeContext) else {
    return
  }
  let request = context.request
  for routeLaneDelta in 1...3 {
    for candidate in policyCanvasDisplayedRouteCandidates(
      request,
      offset: PolicyCanvasRouteRetryOffset(routeLaneDelta: routeLaneDelta)
    ).map(\.route)
    where !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
      best.consider(candidate, score: context.score(candidate))
    }
  }
}

private func policyCanvasConsiderCorridorBundleRoutes(
  into best: inout PolicyCanvasCorridorRouteSearch,
  context: PolicyCanvasCorridorSearchContext
) {
  let request = context.request
  let corridorHint = context.corridorHint
  var preferredHorizontalLanes: [CGFloat] = [corridorHint.horizontalLaneY]
  for candidateLane in policyCanvasTargetLocalHorizontalCorridorLanes(
    request: request,
    targetSide: context.targetSide
  ) where !preferredHorizontalLanes.contains(where: { abs($0 - candidateLane) < 0.5 }) {
    preferredHorizontalLanes.append(candidateLane)
  }
  for candidate in policyCanvasAlignedBundleCandidates(
    route: best.route,
    horizontalLanes: preferredHorizontalLanes,
    verticalLanes: corridorHint.verticalLaneX.map { [$0] } ?? []
  ) where !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles) {
    best.consider(candidate, score: context.score(candidate))
  }
}

private func policyCanvasConsiderCorridorTargetLocalRoute(
  into best: inout PolicyCanvasCorridorRouteSearch,
  context: PolicyCanvasCorridorSearchContext
) {
  let request = context.request
  guard
    let targetLocalHorizontalLane =
      policyCanvasTargetLocalHorizontalCorridorLanes(
        request: request,
        targetSide: policyCanvasRouteTargetSide(best.route) ?? context.targetSide
      ).first,
    let candidate = policyCanvasAlignedHorizontalBundleRoute(
      best.route,
      targetY: targetLocalHorizontalLane
    ),
    !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles)
  else {
    return
  }
  let candidateScore = context.score(candidate)
  let currentDistance =
    abs(
      (policyCanvasDominantHorizontalLaneCoordinate(best.route) ?? targetLocalHorizontalLane)
        - targetLocalHorizontalLane)
  let candidateDistance =
    abs(
      (policyCanvasDominantHorizontalLaneCoordinate(candidate) ?? targetLocalHorizontalLane)
        - targetLocalHorizontalLane)
  if candidateDistance + 0.5 < currentDistance, candidateScore <= best.score + 30_000 {
    best.score = candidateScore
    best.route = candidate
  }
}

func policyCanvasTargetLocalHorizontalCorridorLanes(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  targetSide: PolicyCanvasPortSide
) -> [CGFloat] {
  policyCanvasTargetLocalHorizontalCorridorLanes(
    request: request,
    targetSide: targetSide,
    targetReferencePoint: request.target
  )
}

func policyCanvasLateTargetLocalHorizontalCorridorLanes(
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

func policyCanvasTargetLocalHorizontalCorridorLanes(
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
