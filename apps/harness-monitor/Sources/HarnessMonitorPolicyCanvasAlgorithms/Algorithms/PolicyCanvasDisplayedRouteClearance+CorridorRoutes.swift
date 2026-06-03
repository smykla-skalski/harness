import SwiftUI

func policyCanvasAlignedVerticalDominantCorridorRoute(
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
    abs(targetEscape.routed.x - verticalLaneX)
      <= max(request.lineSpacing, PolicyCanvasLayout.gridSize)
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

  let verticalDominantHorizontalRange =
    min(
      alignedVerticalLaneX, targetEscape.routed.x)...max(
      alignedVerticalLaneX, targetEscape.routed.x)
  let effectiveHorizontalLaneY = policyCanvasCorridorHorizontalLaneClearingTarget(
    hint: corridorHint.horizontalLaneY,
    targetSide: targetSide,
    targetAnchor: targetAnchor.point,
    lineSpacing: request.lineSpacing,
    obstacles: request.obstacles,
    horizontalRange: verticalDominantHorizontalRange
  )
  let basePoints = [
    sourceEscape.routed,
    CGPoint(x: alignedVerticalLaneX, y: sourceEscape.routed.y),
    CGPoint(x: alignedVerticalLaneX, y: effectiveHorizontalLaneY),
    CGPoint(x: targetEscape.routed.x, y: effectiveHorizontalLaneY),
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

func policyCanvasAlignedCorridorIntersectionRoute(
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
    abs(targetEscape.routed.x - verticalLaneX)
      <= max(request.lineSpacing, PolicyCanvasLayout.gridSize)
    ? targetEscape.routed.x
    : verticalLaneX
  let routeContext = policyCanvasRouteContext(for: request)
  let intersectionHorizontalRange =
    min(
      sourceEscape.routed.x, alignedVerticalLaneX, targetEscape.routed.x)...max(
      sourceEscape.routed.x, alignedVerticalLaneX, targetEscape.routed.x)
  let effectiveHorizontalLaneY = policyCanvasCorridorHorizontalLaneClearingTarget(
    hint: corridorHint.horizontalLaneY,
    targetSide: targetSide,
    targetAnchor: targetAnchor.point,
    lineSpacing: request.lineSpacing,
    obstacles: request.obstacles,
    horizontalRange: intersectionHorizontalRange
  )
  let candidates: [PolicyCanvasEdgeRoute] =
    policyCanvasCorridorIntersectionBaseRoutes(
      request: request,
      source: sourceEscape.routed,
      target: targetEscape.routed,
      verticalLaneX: alignedVerticalLaneX,
      horizontalLaneY: effectiveHorizontalLaneY
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

  // Test the two manual L-candidates against the obstacle set first. The
  // engine's flex-anchor A* router occasionally injects a one-lineSpacing
  // zigzag near the source when split at the corridor junction; that small
  // interior segment trips `policyCanvasRouteArtifactPenalty` (10M base +
  // 100k * deficit) and the corridor candidate loses scoring against a
  // bypass route at a non-corridor X. When AT LEAST one manual L already
  // clears the obstacles, route around A*'s contribution entirely.
  let anyManualClean = manualCandidates.contains { points in
    let segments = zip(points, points.dropFirst()).map { start, end in
      policyCanvasRouteSegmentFrame(
        start: start,
        end: end,
        padding: 0
      )
    }
    return segments.allSatisfy { segment in
      request.obstacles.allSatisfy { obstacle in
        !segment.intersects(obstacle)
      }
    }
  }
  if anyManualClean {
    return manualCandidates
  }

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
      obstaclesAreCanonical: true,
      sourceActual: request.source,
      targetActual: nil,
      lineSpacing: request.lineSpacing
    )
  )
  // Treat the first sub-route's segments as obstacles for the second so
  // the two halves cannot overlap away from the junction.
  let firstRouteSegments = zip(firstRoute.points, firstRoute.points.dropFirst())
  let firstRouteFootprint = firstRouteSegments.map { start, end in
    policyCanvasRouteSegmentFrame(
      start: start,
      end: end,
      padding: PolicyCanvasVisibilityRouter.channelStep
    )
  }
  let secondRoute = request.router.route(
    source: junction,
    target: target,
    context: PolicyCanvasRouteContext(
      lane: request.routeLane,
      groups: request.groups,
      sourceGroupID: request.sourceGroupID,
      targetGroupID: request.targetGroupID,
      obstacles: policyCanvasCanonicalObstacles(request.obstacles + firstRouteFootprint),
      obstaclesAreCanonical: true,
      sourceActual: nil,
      targetActual: request.target,
      lineSpacing: request.lineSpacing
    )
  )
  var routedCandidate: [CGPoint] = []
  for point in firstRoute.points where routedCandidate.last != point {
    routedCandidate.append(point)
  }
  for point in secondRoute.points.dropFirst() where routedCandidate.last != point {
    routedCandidate.append(point)
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
