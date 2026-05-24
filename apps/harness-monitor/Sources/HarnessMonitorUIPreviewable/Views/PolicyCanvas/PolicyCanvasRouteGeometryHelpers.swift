import SwiftUI

func policyCanvasRouteBuildOrder(
  edges: [PolicyCanvasEdge],
  portAnchors: [PolicyCanvasPortEndpoint: CGPoint]
) -> [PolicyCanvasEdge] {
  edges.sorted { left, right in
    let leftKey = policyCanvasRouteBuildSortValues(edge: left, portAnchors: portAnchors)
    let rightKey = policyCanvasRouteBuildSortValues(edge: right, portAnchors: portAnchors)
    if abs(leftKey.span - rightKey.span) > 0.001 {
      return leftKey.span < rightKey.span
    }
    if abs(leftKey.source.x - rightKey.source.x) > 0.001 {
      return leftKey.source.x < rightKey.source.x
    }
    if abs(leftKey.source.y - rightKey.source.y) > 0.001 {
      return leftKey.source.y < rightKey.source.y
    }
    if abs(leftKey.target.x - rightKey.target.x) > 0.001 {
      return leftKey.target.x < rightKey.target.x
    }
    if abs(leftKey.target.y - rightKey.target.y) > 0.001 {
      return leftKey.target.y < rightKey.target.y
    }
    return left.id < right.id
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
      }
    }
  }
}

func policyCanvasRouteViolatesMinimumSpacing(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> Bool {
  let segments = policyCanvasRouteSegments(route)
  guard !segments.isEmpty else {
    return false
  }
  let threshold = max(0, minimumSpacing - 0.5)
  return previousRoutes.contains { previousRoute in
    policyCanvasRouteSegments(previousRoute).contains { previousSegment in
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

func policyCanvasRouteSpacingPenalty(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> CGFloat {
  let segments = policyCanvasRouteSegments(route)
  guard !segments.isEmpty else {
    return 0
  }
  return previousRoutes.reduce(0) { total, previousRoute in
    total
      + policyCanvasRouteSegments(previousRoute).reduce(0) { routeTotal, previousSegment in
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

@MainActor
func policyCanvasRouteMinimumSpacing(
  viewModel: PolicyCanvasViewModel,
  edge: PolicyCanvasEdge,
  route: PolicyCanvasEdgeRoute
) -> CGFloat {
  policyCanvasRouteMinimumSpacing(
    edge: edge,
    route: route,
    sourceSpacingBySide: Dictionary(
      uniqueKeysWithValues: PolicyCanvasPortSide.allSides.map { side in
        (side, viewModel.portSpacing(for: edge.source, side: side))
      }
    ),
    targetSpacingBySide: Dictionary(
      uniqueKeysWithValues: PolicyCanvasPortSide.allSides.map { side in
        (side, viewModel.portSpacing(for: edge.target, side: side))
      }
    )
  )
}

func policyCanvasRouteMinimumSpacing(
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

func policyCanvasRouteMinimumSpacing(
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

func policyCanvasGroupTitleFrames(_ groups: [PolicyCanvasGroup]) -> [CGRect] {
  groups.map { group in
    CGRect(
      x: group.frame.minX + 8,
      y: group.frame.minY + 8,
      width: min(group.frame.width - 16, 180),
      height: 34
    )
  }
}

func policyCanvasRouteFrames(
  _ routes: [(id: String, route: PolicyCanvasEdgeRoute)]
) -> [String: [CGRect]] {
  Dictionary(
    uniqueKeysWithValues: routes.map { entry in
      (entry.id, policyCanvasRouteSegmentFrames(entry.route))
    })
}
