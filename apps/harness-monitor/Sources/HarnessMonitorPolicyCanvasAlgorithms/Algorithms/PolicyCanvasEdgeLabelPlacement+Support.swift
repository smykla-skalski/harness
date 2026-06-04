import SwiftUI

struct PolicyCanvasDuplicateLabelPairPlacement {
  let score: CGFloat
  let leftCenter: CGPoint
  let rightCenter: CGPoint
}

private struct PolicyCanvasDuplicateLabelPairSearch {
  let left: PolicyCanvasLabelPlacementRoute
  let right: PolicyCanvasLabelPlacementRoute
  let leftCandidates: [CGPoint]
  let rightCandidates: [CGPoint]
  let blockers: [CGRect]
  let graphHull: CGRect?
}

struct PolicyCanvasDuplicateLabelPairContext {
  let left: PolicyCanvasLabelPlacementRoute
  let right: PolicyCanvasLabelPlacementRoute
  let nodeFrames: [CGRect]
  let occupied: [CGRect]
  let pairRouteBlockers: [CGRect]
  let sharedSegmentAvoidance: [String: [PolicyCanvasSharedLabelSegment]]
  let graphHull: CGRect?
}

func policyCanvasResolveDuplicateLabelPair(
  _ context: PolicyCanvasDuplicateLabelPairContext
) -> PolicyCanvasDuplicateLabelPairPlacement? {
  let leftAvoidedSegments = context.sharedSegmentAvoidance[context.left.id, default: []]
  let rightAvoidedSegments = context.sharedSegmentAvoidance[context.right.id, default: []]
  let leftPreferredAxis = policyCanvasPreferredLabelAxis(avoidedSegments: leftAvoidedSegments)
  let rightPreferredAxis = policyCanvasPreferredLabelAxis(avoidedSegments: rightAvoidedSegments)
  let leftCandidates = policyCanvasLabelCandidates(
    route: context.left.route,
    labelSize: context.left.size,
    avoidedSegments: leftAvoidedSegments,
    preferredAxis: leftPreferredAxis,
    includesAdjacentFallback: true
  )
  let rightCandidates = policyCanvasLabelCandidates(
    route: context.right.route,
    labelSize: context.right.size,
    avoidedSegments: rightAvoidedSegments,
    preferredAxis: rightPreferredAxis,
    includesAdjacentFallback: true
  )
  return policyCanvasBestDuplicateLabelPairPlacement(
    PolicyCanvasDuplicateLabelPairSearch(
      left: context.left,
      right: context.right,
      leftCandidates: leftCandidates,
      rightCandidates: rightCandidates,
      blockers: context.nodeFrames + context.occupied + context.pairRouteBlockers,
      graphHull: context.graphHull
    )
  )
    ?? policyCanvasBestDuplicateLabelPairPlacement(
      PolicyCanvasDuplicateLabelPairSearch(
        left: context.left,
        right: context.right,
        leftCandidates: leftCandidates,
        rightCandidates: rightCandidates,
        blockers: context.nodeFrames + context.occupied,
        graphHull: context.graphHull
      )
    )
}

private func policyCanvasBestDuplicateLabelPairPlacement(
  _ search: PolicyCanvasDuplicateLabelPairSearch
) -> PolicyCanvasDuplicateLabelPairPlacement? {
  let leftBase = policyCanvasClosestRoutePoint(
    to: search.left.route.labelPosition,
    route: search.left.route
  )
  let rightBase = policyCanvasClosestRoutePoint(
    to: search.right.route.labelPosition,
    route: search.right.route
  )
  var bestPlacement: PolicyCanvasDuplicateLabelPairPlacement?
  for leftCandidate in search.leftCandidates {
    guard
      policyCanvasIsClearLabelCenter(
        leftCandidate,
        size: search.left.size,
        blockers: search.blockers,
        graphHull: search.graphHull
      )
    else {
      continue
    }
    let leftFrame = policyCanvasLabelFrame(center: leftCandidate, size: search.left.size)
    for rightCandidate in search.rightCandidates {
      guard
        policyCanvasIsClearLabelCenter(
          rightCandidate,
          size: search.right.size,
          blockers: search.blockers,
          graphHull: search.graphHull
        )
      else {
        continue
      }
      let rightFrame = policyCanvasLabelFrame(center: rightCandidate, size: search.right.size)
      guard !leftFrame.intersects(rightFrame) else {
        continue
      }
      let placement = PolicyCanvasDuplicateLabelPairPlacement(
        score:
          policyCanvasDistanceSquared(leftCandidate, leftBase)
          + policyCanvasDistanceSquared(rightCandidate, rightBase),
        leftCenter: leftCandidate,
        rightCenter: rightCandidate
      )
      if let currentBest = bestPlacement, currentBest.score <= placement.score {
        continue
      }
      bestPlacement = placement
    }
  }
  return bestPlacement
}

private func policyCanvasIsClearLabelCenter(
  _ center: CGPoint,
  size: CGSize,
  blockers: [CGRect],
  graphHull: CGRect?
) -> Bool {
  let frame = policyCanvasLabelFrame(center: center, size: size)
  if let graphHull, !graphHull.contains(frame) {
    return false
  }
  return !blockers.contains(where: { $0.intersects(frame) })
}

private func policyCanvasDistanceSquared(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
  let dx = left.x - right.x
  let dy = left.y - right.y
  return (dx * dx) + (dy * dy)
}

func policyCanvasDuplicateLabelFamilyAnchor(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> CGPoint {
  routes.map(\.route.labelPosition).min { left, right in
    if left.y != right.y {
      return left.y < right.y
    }
    return left.x < right.x
  } ?? .zero
}

func policyCanvasRoutesShareLabelTrunk(
  _ left: PolicyCanvasEdgeRoute,
  _ right: PolicyCanvasEdgeRoute
) -> Bool {
  let leftSegments = zip(left.points, left.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
  let rightSegments = zip(right.points, right.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
  for leftSegment in leftSegments {
    for rightSegment in rightSegments {
      guard leftSegment.axis == rightSegment.axis else {
        continue
      }
      switch leftSegment.axis {
      case .horizontal:
        guard abs(leftSegment.start.y - rightSegment.start.y) < 0.5 else {
          continue
        }
        if policyCanvasSharedLabelOverlap(leftSegment.xRange, rightSegment.xRange)
          >= policyCanvasMinimumSharedLabelOverlap
        {
          return true
        }
      case .vertical:
        guard abs(leftSegment.start.x - rightSegment.start.x) < 0.5 else {
          continue
        }
        if policyCanvasSharedLabelOverlap(leftSegment.yRange, rightSegment.yRange)
          >= policyCanvasMinimumSharedLabelOverlap
        {
          return true
        }
      }
    }
  }
  return false
}

// Frame collections a label must avoid: already-placed label frames, node
// bodies, and the routed polyline frames of other edges.
struct PolicyCanvasLabelObstacleFrames {
  let occupied: [CGRect]
  let nodes: [CGRect]
  let routes: [CGRect]

  var graphHull: CGRect? {
    let hull = nodes.reduce(into: CGRect.null) { partial, frame in
      partial = partial.union(frame)
    }
    return hull.isNull ? nil : hull
  }
}

func policyCanvasResolvedLabelPosition(
  route: PolicyCanvasEdgeRoute,
  size: CGSize,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?,
  obstacleFrames: PolicyCanvasLabelObstacleFrames
) -> CGPoint {
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  let lineBlockers = obstacleFrames.occupied + obstacleFrames.routes
  var allCandidates: [CGPoint] = []
  let preferredSegments = policyCanvasPreferredLabelSegments(
    route: route,
    base: base,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  if !preferredSegments.isEmpty {
    let candidates = policyCanvasLabelCandidates(
      segments: preferredSegments,
      base: base,
      labelSize: size,
      preferredAxis: preferredAxis
    )
    if let candidate = policyCanvasFirstClearLabelCandidate(
      candidates,
      size: size,
      obstacleFrames: obstacleFrames,
      requiresGraphHull: true
    ) {
      return candidate
    }
    allCandidates.append(contentsOf: candidates)
  }
  let candidates = policyCanvasLabelCandidates(
    route: route,
    labelSize: size,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  if let candidate = policyCanvasFirstClearLabelCandidate(
    candidates,
    size: size,
    obstacleFrames: obstacleFrames,
    requiresGraphHull: true
  ) {
    return candidate
  }
  allCandidates.append(contentsOf: candidates)
  // Keep labels inside the graph hull even when that means grazing a sibling
  // route, instead of jumping to a perfectly clear off-canvas stub.
  if let candidate = policyCanvasLeastBadGraphHullCandidate(
    allCandidates,
    size: size,
    obstacleFrames: obstacleFrames,
    lineBlockers: lineBlockers,
    fallback: base
  ) {
    return candidate
  }
  if let candidate = policyCanvasFirstClearLabelCandidate(
    allCandidates,
    size: size,
    obstacleFrames: obstacleFrames,
    requiresGraphHull: false
  ) {
    return candidate
  }

  // Crowded: no collision-free spot exists on this edge. Pick the least-bad
  // candidate, ranking node-body overlap ahead of route/label overlap so the
  // label slides onto its own run rather than covering a node - see
  // policyCanvasLeastBadLabelCandidate.
  return policyCanvasLeastBadLabelCandidate(
    allCandidates,
    size: size,
    nodeFrames: obstacleFrames.nodes,
    lineBlockers: lineBlockers,
    fallback: base
  )
}

private func policyCanvasFirstClearLabelCandidate(
  _ candidates: [CGPoint],
  size: CGSize,
  obstacleFrames: PolicyCanvasLabelObstacleFrames,
  requiresGraphHull: Bool
) -> CGPoint? {
  for candidate in candidates {
    let frame = policyCanvasLabelFrame(center: candidate, size: size)
    guard policyCanvasLabelFrameIsClear(frame, obstacleFrames: obstacleFrames) else {
      continue
    }
    if requiresGraphHull, !policyCanvasFitsGraphHull(frame, obstacleFrames: obstacleFrames) {
      continue
    }
    return candidate
  }
  return nil
}

private func policyCanvasLeastBadGraphHullCandidate(
  _ candidates: [CGPoint],
  size: CGSize,
  obstacleFrames: PolicyCanvasLabelObstacleFrames,
  lineBlockers: [CGRect],
  fallback: CGPoint
) -> CGPoint? {
  let inHullCandidates = candidates.filter { candidate in
    policyCanvasFitsGraphHull(
      policyCanvasLabelFrame(center: candidate, size: size),
      obstacleFrames: obstacleFrames
    )
  }
  guard !inHullCandidates.isEmpty else {
    return nil
  }
  return policyCanvasLeastBadLabelCandidate(
    inHullCandidates,
    size: size,
    nodeFrames: obstacleFrames.nodes,
    lineBlockers: lineBlockers,
    fallback: fallback
  )
}

private func policyCanvasLabelFrameIsClear(
  _ frame: CGRect,
  obstacleFrames: PolicyCanvasLabelObstacleFrames
) -> Bool {
  !obstacleFrames.occupied.contains(where: { $0.intersects(frame) })
    && !obstacleFrames.nodes.contains(where: { $0.intersects(frame) })
    && !obstacleFrames.routes.contains(where: { $0.intersects(frame) })
}

private func policyCanvasFitsGraphHull(
  _ frame: CGRect,
  obstacleFrames: PolicyCanvasLabelObstacleFrames
) -> Bool {
  guard let graphHull = obstacleFrames.graphHull else {
    return true
  }
  return graphHull.contains(frame)
}
