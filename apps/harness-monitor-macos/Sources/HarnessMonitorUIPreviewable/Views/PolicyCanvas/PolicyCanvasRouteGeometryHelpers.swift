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
        guard let distance = segment.spacingDistance(
          to: previousSegment,
          minimumSpacing: threshold
        ) else {
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
    total + policyCanvasRouteSegments(previousRoute).reduce(0) { routeTotal, previousSegment in
      routeTotal + segments.reduce(0) { segmentTotal, segment in
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
  let sourceSide = policyCanvasRouteSourceSide(route) ?? policyCanvasResolvedPortSide(for: edge.source)
  let targetSide = policyCanvasRouteTargetSide(route) ?? policyCanvasResolvedPortSide(for: edge.target)
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
  Dictionary(uniqueKeysWithValues: routes.map { entry in
    (entry.id, policyCanvasRouteSegmentFrames(entry.route))
  })
}

private func policyCanvasRouteBuildSortValues(
  edge: PolicyCanvasEdge,
  portAnchors: [PolicyCanvasPortEndpoint: CGPoint]
) -> (span: CGFloat, source: CGPoint, target: CGPoint) {
  let source = portAnchors[edge.source] ?? .zero
  let target = portAnchors[edge.target] ?? .zero
  return (abs(target.x - source.x) + abs(target.y - source.y), source, target)
}

private func policyCanvasInteriorRouteSegments(
  _ route: PolicyCanvasEdgeRoute
) -> [PolicyCanvasRouteSegment] {
  let segments = Array(zip(route.points, route.points.dropFirst()))
  guard segments.count > 2 else {
    return []
  }
  return segments.enumerated().compactMap { index, segment in
    guard index > 0, index < segments.count - 1 else {
      return nil
    }
    return PolicyCanvasRouteSegment(start: segment.0, end: segment.1)
  }
}

private func policyCanvasRouteSegments(
  _ route: PolicyCanvasEdgeRoute
) -> [PolicyCanvasRouteSegment] {
  zip(route.points, route.points.dropFirst()).compactMap { start, end in
    guard start != end else {
      return nil
    }
    return PolicyCanvasRouteSegment(start: start, end: end)
  }
}

private func policyCanvasRouteSegmentFrames(
  _ route: PolicyCanvasEdgeRoute
) -> [CGRect] {
  zip(route.points, route.points.dropFirst()).map { start, end in
    policyCanvasRouteSegmentFrame(start: start, end: end, padding: 10)
  }
}

private func policyCanvasRouteSegmentFrame(
  start: CGPoint,
  end: CGPoint,
  padding: CGFloat
) -> CGRect {
  let minX = min(start.x, end.x)
  let minY = min(start.y, end.y)
  let width = max(abs(end.x - start.x), 1)
  let height = max(abs(end.y - start.y), 1)
  return CGRect(x: minX, y: minY, width: width, height: height)
    .insetBy(dx: -padding, dy: -padding)
}

private struct PolicyCanvasRouteSegment {
  let start: CGPoint
  let end: CGPoint

  var isHorizontal: Bool {
    abs(start.y - end.y) < 0.001
  }

  var isVertical: Bool {
    abs(start.x - end.x) < 0.001
  }

  var axisCoordinate: CGFloat {
    isHorizontal ? start.y : start.x
  }

  var length: CGFloat {
    abs(end.x - start.x) + abs(end.y - start.y)
  }

  func sharesCollinearRange(with other: PolicyCanvasRouteSegment) -> Bool {
    if isHorizontal, other.isHorizontal, abs(start.y - other.start.y) < 0.001 {
      return overlap(
        min(start.x, end.x)...max(start.x, end.x),
        min(other.start.x, other.end.x)...max(other.start.x, other.end.x)
      ) > 0.001
    }
    if isVertical, other.isVertical, abs(start.x - other.start.x) < 0.001 {
      return overlap(
        min(start.y, end.y)...max(start.y, end.y),
        min(other.start.y, other.end.y)...max(other.start.y, other.end.y)
      ) > 0.001
    }
    return false
  }

  func isSameAxis(as other: PolicyCanvasRouteSegment) -> Bool {
    (isHorizontal && other.isHorizontal) || (isVertical && other.isVertical)
  }

  func overlap(with other: PolicyCanvasRouteSegment) -> CGFloat {
    if isHorizontal, other.isHorizontal {
      return overlap(
        min(start.x, end.x)...max(start.x, end.x),
        min(other.start.x, other.end.x)...max(other.start.x, other.end.x)
      )
    }
    if isVertical, other.isVertical {
      return overlap(
        min(start.y, end.y)...max(start.y, end.y),
        min(other.start.y, other.end.y)...max(other.start.y, other.end.y)
      )
    }
    return 0
  }

  func axisDistance(to other: PolicyCanvasRouteSegment) -> CGFloat {
    abs(axisCoordinate - other.axisCoordinate)
  }

  func distance(to other: PolicyCanvasRouteSegment) -> CGFloat {
    if intersects(other) {
      return 0
    }
    return [
      distance(from: start, to: other),
      distance(from: end, to: other),
      distance(from: other.start, to: self),
      distance(from: other.end, to: self),
    ].min() ?? .infinity
  }

  func spacingDistance(
    to other: PolicyCanvasRouteSegment,
    minimumSpacing: CGFloat
  ) -> CGFloat? {
    if isCleanRightAngleCrossing(with: other, minimumArmLength: minimumSpacing) {
      return nil
    }
    return distance(to: other)
  }

  private func isCleanRightAngleCrossing(
    with other: PolicyCanvasRouteSegment,
    minimumArmLength: CGFloat
  ) -> Bool {
    guard isSameAxis(as: other) == false else {
      return false
    }
    guard let crossing = rightAngleCrossingPoint(with: other) else {
      return false
    }
    let horizontal = isHorizontal ? self : other
    let vertical = isVertical ? self : other
    let horizontalArm = min(
      crossing.x - horizontal.xRange.lowerBound,
      horizontal.xRange.upperBound - crossing.x
    )
    let verticalArm = min(
      crossing.y - vertical.yRange.lowerBound,
      vertical.yRange.upperBound - crossing.y
    )
    let tolerance: CGFloat = 0.5
    return horizontalArm >= minimumArmLength - tolerance
      && verticalArm >= minimumArmLength - tolerance
  }

  private func rightAngleCrossingPoint(with other: PolicyCanvasRouteSegment) -> CGPoint? {
    if isHorizontal, other.isVertical {
      let point = CGPoint(x: other.start.x, y: start.y)
      return contains(value: point.x, in: xRange) && contains(value: point.y, in: other.yRange)
        ? point
        : nil
    }
    if isVertical, other.isHorizontal {
      let point = CGPoint(x: start.x, y: other.start.y)
      return contains(value: point.x, in: other.xRange) && contains(value: point.y, in: yRange)
        ? point
        : nil
    }
    return nil
  }

  private func intersects(_ other: PolicyCanvasRouteSegment) -> Bool {
    if isHorizontal, other.isVertical {
      return contains(value: other.start.x, in: xRange)
        && contains(value: start.y, in: other.yRange)
    }
    if isVertical, other.isHorizontal {
      return contains(value: start.x, in: other.xRange)
        && contains(value: other.start.y, in: yRange)
    }
    if isHorizontal, other.isHorizontal, abs(start.y - other.start.y) < 0.001 {
      return overlap(xRange, other.xRange) > 0.001
    }
    if isVertical, other.isVertical, abs(start.x - other.start.x) < 0.001 {
      return overlap(yRange, other.yRange) > 0.001
    }
    return false
  }

  private var xRange: ClosedRange<CGFloat> {
    min(start.x, end.x)...max(start.x, end.x)
  }

  private var yRange: ClosedRange<CGFloat> {
    min(start.y, end.y)...max(start.y, end.y)
  }

  private func contains(value: CGFloat, in range: ClosedRange<CGFloat>) -> Bool {
    value >= range.lowerBound - 0.001 && value <= range.upperBound + 0.001
  }

  private func overlap(_ left: ClosedRange<CGFloat>, _ right: ClosedRange<CGFloat>) -> CGFloat {
    max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
  }

  private func distance(
    from point: CGPoint,
    to segment: PolicyCanvasRouteSegment
  ) -> CGFloat {
    let minX = min(segment.start.x, segment.end.x)
    let maxX = max(segment.start.x, segment.end.x)
    let minY = min(segment.start.y, segment.end.y)
    let maxY = max(segment.start.y, segment.end.y)
    let clamped = CGPoint(
      x: min(max(point.x, minX), maxX),
      y: min(max(point.y, minY), maxY)
    )
    return hypot(point.x - clamped.x, point.y - clamped.y)
  }
}
