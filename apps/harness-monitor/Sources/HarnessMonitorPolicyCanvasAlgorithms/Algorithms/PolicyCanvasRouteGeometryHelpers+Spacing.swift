import SwiftUI

func policyCanvasRouteViolatesMinimumSpacing(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> Bool {
  policyCanvasRouteViolatesMinimumSpacing(
    segments: policyCanvasRouteSegments(route),
    with: previousRoutes,
    minimumSpacing: minimumSpacing
  )
}

func policyCanvasRouteViolatesMinimumSpacing(
  segments: [PolicyCanvasRouteSegment],
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> Bool {
  policyCanvasRouteViolatesMinimumSpacing(
    segments: segments,
    with: previousRoutes.map(policyCanvasRouteSegments),
    minimumSpacing: minimumSpacing
  )
}

func policyCanvasRouteViolatesMinimumSpacing(
  segments: [PolicyCanvasRouteSegment],
  with previousRouteSegments: [[PolicyCanvasRouteSegment]],
  minimumSpacing: CGFloat
) -> Bool {
  guard !segments.isEmpty else {
    return false
  }
  let threshold = max(0, minimumSpacing - 0.5)
  return previousRouteSegments.contains { previousSegments in
    previousSegments.contains { previousSegment in
      segments.contains { segment in
        guard
          let distance = segment.spacingDistance(
            to: previousSegment,
            minimumSpacing: threshold
          )
        else {
          return false
        }
        return distance < threshold
      }
    }
  }
}

func policyCanvasRouteSharesInteriorCorridor(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute]
) -> Bool {
  let segments = policyCanvasInteriorRouteSegments(route)
  guard !segments.isEmpty else {
    return false
  }
  return previousRoutes.contains { previousRoute in
    let previousSegments = policyCanvasInteriorRouteSegments(previousRoute)
    return segments.contains { segment in
      previousSegments.contains { previousSegment in
        segment.sharesCollinearRange(with: previousSegment)
          || segment.sharesAxisLane(with: previousSegment)
      }
    }
  }
}

func policyCanvasRouteMaxInteriorSharedOverlap(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute]
) -> CGFloat {
  policyCanvasRouteMaxInteriorSharedOverlap(
    interiorSegments: policyCanvasInteriorRouteSegments(route),
    with: previousRoutes
  )
}

func policyCanvasRouteMaxInteriorSharedOverlap(
  interiorSegments segments: [PolicyCanvasRouteSegment],
  with previousRoutes: [PolicyCanvasEdgeRoute]
) -> CGFloat {
  policyCanvasRouteMaxInteriorSharedOverlap(
    interiorSegments: segments,
    with: previousRoutes.map(policyCanvasInteriorRouteSegments)
  )
}

func policyCanvasRouteMaxInteriorSharedOverlap(
  interiorSegments segments: [PolicyCanvasRouteSegment],
  with previousRouteInteriorSegments: [[PolicyCanvasRouteSegment]]
) -> CGFloat {
  guard !segments.isEmpty else {
    return 0
  }
  return previousRouteInteriorSegments.reduce(CGFloat.zero) { routeMax, previousSegments in
    let previousMax = previousSegments.reduce(CGFloat.zero) { segmentMax, previousSegment in
      let shared = segments.reduce(CGFloat.zero) { overlapMax, segment in
        if segment.isHorizontal, previousSegment.isHorizontal,
          abs(segment.start.y - previousSegment.start.y) < 0.001
        {
          return max(overlapMax, segment.overlap(with: previousSegment))
        }
        if segment.isVertical, previousSegment.isVertical,
          abs(segment.start.x - previousSegment.start.x) < 0.001
        {
          return max(overlapMax, segment.overlap(with: previousSegment))
        }
        return overlapMax
      }
      return max(segmentMax, shared)
    }
    return max(routeMax, previousMax)
  }
}

func policyCanvasRouteSpacingPenalty(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> CGFloat {
  policyCanvasRouteSpacingPenalty(
    segments: policyCanvasRouteSegments(route),
    with: previousRoutes,
    minimumSpacing: minimumSpacing
  )
}

func policyCanvasRouteSpacingPenalty(
  segments: [PolicyCanvasRouteSegment],
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> CGFloat {
  policyCanvasRouteSpacingPenalty(
    segments: segments,
    with: previousRoutes.map(policyCanvasRouteSegments),
    minimumSpacing: minimumSpacing
  )
}

func policyCanvasRouteSpacingPenalty(
  segments: [PolicyCanvasRouteSegment],
  with previousRouteSegments: [[PolicyCanvasRouteSegment]],
  minimumSpacing: CGFloat
) -> CGFloat {
  guard !segments.isEmpty else {
    return 0
  }
  return previousRouteSegments.reduce(0) { total, previousSegments in
    total
      + previousSegments.reduce(0) { routeTotal, previousSegment in
        routeTotal
          + segments.reduce(0) { segmentTotal, segment in
            guard
              let distance = segment.spacingDistance(
                to: previousSegment,
                minimumSpacing: minimumSpacing
              )
            else {
              return segmentTotal
            }
            guard distance < minimumSpacing else {
              return segmentTotal
            }
            let overlapPenalty =
              segment.isSameAxis(as: previousSegment)
              ? segment.overlap(with: previousSegment) * 250
              : 0
            return segmentTotal
              + ((minimumSpacing - distance) * 10_000)
              + overlapPenalty
          }
      }
  }
}

func policyCanvasRouteClearanceObstacles(
  from routes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> [CGRect] {
  routes.flatMap { route in
    policyCanvasInteriorRouteSegments(route).compactMap { segment in
      guard segment.length >= minimumSpacing else {
        return nil
      }
      return policyCanvasRouteSegmentFrame(
        start: segment.start,
        end: segment.end,
        padding: minimumSpacing + PolicyCanvasVisibilityRouter.channelStep
      )
    }
  }
}

public func policyCanvasRouteMinimumSpacing(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  route: PolicyCanvasEdgeRoute
) -> CGFloat {
  policyCanvasRouteMinimumSpacing(
    edge: request.edge,
    route: route,
    sourceSpacingBySide: request.sourceSpacingBySide,
    targetSpacingBySide: request.targetSpacingBySide
  )
}

public func policyCanvasRouteMinimumSpacing(
  edge: PolicyCanvasEdge,
  route: PolicyCanvasEdgeRoute,
  sourceSpacingBySide: [PolicyCanvasPortSide: CGFloat],
  targetSpacingBySide: [PolicyCanvasPortSide: CGFloat]
) -> CGFloat {
  let sourceSide =
    policyCanvasRouteSourceSide(route) ?? policyCanvasResolvedPortSide(for: edge.source)
  let targetSide =
    policyCanvasRouteTargetSide(route) ?? policyCanvasResolvedPortSide(for: edge.target)
  return min(
    sourceSpacingBySide[sourceSide] ?? PolicyCanvasLayout.defaultEdgeLineSpacing,
    targetSpacingBySide[targetSide] ?? PolicyCanvasLayout.defaultEdgeLineSpacing
  )
}

public func policyCanvasGroupTitleFrames(_ groups: [PolicyCanvasGroup]) -> [CGRect] {
  groups.map { group in
    CGRect(
      x: group.frame.minX + 8,
      y: group.frame.minY + 8,
      width: min(group.frame.width - 16, 180),
      height: 34
    )
  }
}
