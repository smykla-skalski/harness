import SwiftUI

func policyCanvasAlignedHorizontalBundleRoute(
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

func policyCanvasAlignedVerticalBundleRoute(
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

func policyCanvasRouteIsOrthogonal(_ route: PolicyCanvasEdgeRoute) -> Bool {
  zip(route.points, route.points.dropFirst()).allSatisfy { start, end in
    abs(start.x - end.x) < 0.001 || abs(start.y - end.y) < 0.001
  }
}

func policyCanvasAlignedBundleCandidates(
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
) -> PolicyCanvasDominantHorizontalSegment? {
  guard route.points.count >= 4 else {
    return nil
  }
  var best: PolicyCanvasDominantHorizontalSegment?
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    guard abs(start.y - end.y) < 0.001 else {
      continue
    }
    let length = abs(end.x - start.x)
    if best.map({ length > $0.length }) ?? true {
      best = PolicyCanvasDominantHorizontalSegment(index: index, y: start.y, length: length)
    }
  }
  return best
}

private func policyCanvasDominantVerticalSegment(
  _ route: PolicyCanvasEdgeRoute
) -> PolicyCanvasDominantVerticalSegment? {
  guard route.points.count >= 4 else {
    return nil
  }
  var best: PolicyCanvasDominantVerticalSegment?
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    guard abs(start.x - end.x) < 0.001 else {
      continue
    }
    let length = abs(end.y - start.y)
    if best.map({ length > $0.length }) ?? true {
      best = PolicyCanvasDominantVerticalSegment(index: index, x: start.x, length: length)
    }
  }
  return best
}

func policyCanvasRouteIntersectsObstacles(
  _ route: PolicyCanvasEdgeRoute,
  obstacles: [CGRect]
) -> Bool {
  policyCanvasRouteSegments(route).contains { segment in
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

func policyCanvasRouteArtifactPenalty(
  _ route: PolicyCanvasEdgeRoute,
  minimumSpacing: CGFloat
) -> CGFloat {
  var penalty: CGFloat = 0
  let minimumSegmentLength = max(
    PolicyCanvasVisibilityRouter.channelStep * 2,
    min(minimumSpacing / 2, PolicyCanvasLayout.portDiameter)
  )
  // Only score interior segments. The outermost segments are bridge
  // geometry that connects each port anchor to the routed polyline; their
  // lengths are intentionally tied to port-lead distances and would
  // otherwise mass-fire the short-segment penalty on every legitimate
  // bridged route, forcing the system into a permanent retry loop.
  for segment in policyCanvasInteriorRouteSegments(route) {
    let dx = abs(segment.end.x - segment.start.x)
    let dy = abs(segment.end.y - segment.start.y)
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
