import SwiftUI

struct PolicyCanvasRouteSortKey {
  let span: CGFloat
  let source: CGPoint
  let target: CGPoint
}

func policyCanvasRouteBuildSortValues(
  edge: PolicyCanvasEdge,
  portAnchors: [PolicyCanvasPortEndpoint: CGPoint]
) -> PolicyCanvasRouteSortKey {
  let source = portAnchors[edge.source] ?? .zero
  let target = portAnchors[edge.target] ?? .zero
  return PolicyCanvasRouteSortKey(
    span: abs(target.x - source.x) + abs(target.y - source.y),
    source: source,
    target: target
  )
}

func policyCanvasRouteSegments(
  _ route: PolicyCanvasEdgeRoute
) -> [PolicyCanvasRouteSegment] {
  zip(route.points, route.points.dropFirst()).compactMap { start, end in
    guard start != end else {
      return nil
    }
    return PolicyCanvasRouteSegment(start: start, end: end)
  }
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

public func policyCanvasRouteBounds(_ points: [CGPoint]) -> CGRect {
  guard let first = points.first else {
    return .null
  }
  return points.dropFirst().reduce(into: CGRect(origin: first, size: .zero)) { bounds, point in
    bounds = bounds.union(CGRect(origin: point, size: .zero))
  }
}

public func policyCanvasRouteBounds(_ route: PolicyCanvasEdgeRoute) -> CGRect {
  policyCanvasRouteBounds(route.points)
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

public func policyCanvasRouteSegmentFrames(
  _ route: PolicyCanvasEdgeRoute
) -> [CGRect] {
  zip(route.points, route.points.dropFirst()).map { start, end in
    policyCanvasRouteSegmentFrame(start: start, end: end, padding: 10)
  }
}

func policyCanvasRouteSegmentFrame(
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

struct PolicyCanvasRouteSegment {
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

  func sharesCollinearRange(with other: Self) -> Bool {
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

  /// True when both segments are axis-aligned along the same axis lane (same
  /// X column for verticals, same Y row for horizontals), even if their
  /// extents do not overlap. Used to detect bundle siblings that occupy the
  /// same corridor column at non-overlapping y ranges - the canonical
  /// fan-out shape where each sibling carves its own sub-segment of the
  /// shared vertical bus.
  func sharesAxisLane(with other: Self) -> Bool {
    if isHorizontal, other.isHorizontal {
      return abs(start.y - other.start.y) < 0.001
    }
    if isVertical, other.isVertical {
      return abs(start.x - other.start.x) < 0.001
    }
    return false
  }

  /// True when same-axis segments overlap along their route span and their
  /// lane coordinates are closer than the route-level minimum spacing.
  func sharesParallelCorridor(
    with other: Self,
    minimumSpacing: CGFloat
  ) -> Bool {
    guard isSameAxis(as: other) else {
      return false
    }
    guard overlap(with: other) > 0.001 else {
      return false
    }
    return axisDistance(to: other) < minimumSpacing - 0.001
  }

  func isSameAxis(as other: Self) -> Bool {
    (isHorizontal && other.isHorizontal) || (isVertical && other.isVertical)
  }

  func overlap(with other: Self) -> CGFloat {
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

  func axisDistance(to other: Self) -> CGFloat {
    abs(axisCoordinate - other.axisCoordinate)
  }

  func distance(to other: Self) -> CGFloat {
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
    to other: Self,
    minimumSpacing: CGFloat
  ) -> CGFloat? {
    if isCleanRightAngleCrossing(with: other, minimumArmLength: minimumSpacing) {
      return nil
    }
    return distance(to: other)
  }

  private func isCleanRightAngleCrossing(
    with other: Self,
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

  private func rightAngleCrossingPoint(with other: Self) -> CGPoint? {
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

  private func intersects(_ other: Self) -> Bool {
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
    to segment: Self
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
