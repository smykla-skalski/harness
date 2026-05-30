import SwiftUI

func policyCanvasClosestRoutePoint(
  to point: CGPoint,
  route: PolicyCanvasEdgeRoute
) -> CGPoint {
  let segments = zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
  return segments.min { left, right in
    left.distanceSquared(to: point) < right.distanceSquared(to: point)
  }?.closestPoint(to: point) ?? route.points.first ?? point
}

func policyCanvasLabelFrame(center: CGPoint, size: CGSize) -> CGRect {
  CGRect(
    x: center.x - (size.width / 2),
    y: center.y - (size.height / 2),
    width: size.width,
    height: size.height
  )
}

struct PolicyCanvasLabelRouteSegment {
  let start: CGPoint
  let end: CGPoint
  let lengthSquared: CGFloat

  init?(start: CGPoint, end: CGPoint) {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = (dx * dx) + (dy * dy)
    guard lengthSquared > 0.001 else {
      return nil
    }
    self.start = start
    self.end = end
    self.lengthSquared = lengthSquared
  }

  var length: CGFloat {
    sqrt(lengthSquared)
  }

  // Strict axis-alignment. Diagonals report false from both isHorizontal and
  // isVertical so callers that branch on either flag (e.g. label-placement
  // axis preference) don't treat a 45° segment as a horizontal bus.
  var isHorizontal: Bool {
    abs(end.y - start.y) < 0.001 && abs(end.x - start.x) > 0.001
  }

  var isVertical: Bool {
    abs(end.x - start.x) < 0.001 && abs(end.y - start.y) > 0.001
  }

  var axis: PolicyCanvasSegmentAxis {
    if isHorizontal { return .horizontal }
    if isVertical { return .vertical }
    // Diagonal fallback: approximate to the longer-extent axis so the
    // downstream label code still sees one of the two cases. This is wrong
    // for true diagonals but routes are expected orthogonal; only rare
    // fallback shapes reach here.
    return abs(end.x - start.x) >= abs(end.y - start.y) ? .horizontal : .vertical
  }

  var xRange: ClosedRange<CGFloat> {
    min(start.x, end.x)...max(start.x, end.x)
  }

  var yRange: ClosedRange<CGFloat> {
    min(start.y, end.y)...max(start.y, end.y)
  }

  func safeRange(for labelAxisLength: CGFloat) -> ClosedRange<CGFloat> {
    guard length > labelAxisLength else {
      return 0.5...0.5
    }
    let inset = (labelAxisLength / 2) / length
    return inset...(1 - inset)
  }

  func cornerClearRange(for labelAxisLength: CGFloat) -> ClosedRange<CGFloat>? {
    let endpointClearance = (labelAxisLength / 2) + PolicyCanvasLayout.gridSize
    guard length > endpointClearance * 2 else {
      return nil
    }
    let inset = endpointClearance / length
    return inset...(1 - inset)
  }

  func containsProjection(of point: CGPoint) -> Bool {
    let parameter = parameter(for: point)
    return parameter >= 0 && parameter <= 1
  }

  func parameter(for point: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    return (((point.x - start.x) * dx) + ((point.y - start.y) * dy)) / lengthSquared
  }

  func point(at parameter: CGFloat) -> CGPoint {
    CGPoint(
      x: start.x + ((end.x - start.x) * parameter),
      y: start.y + ((end.y - start.y) * parameter)
    )
  }

  func closestPoint(to point: CGPoint) -> CGPoint {
    self.point(at: min(max(parameter(for: point), 0), 1))
  }

  func distanceSquared(to point: CGPoint) -> CGFloat {
    let closest = closestPoint(to: point)
    let dx = closest.x - point.x
    let dy = closest.y - point.y
    return (dx * dx) + (dy * dy)
  }

  fileprivate func matches(_ segment: PolicyCanvasSharedLabelSegment) -> Bool {
    guard axis == segment.axis else {
      return false
    }
    switch axis {
    case .horizontal:
      return abs(start.y - segment.coordinate) < 0.5
        && policyCanvasSharedLabelOverlap(xRange, segment.range)
          >= policyCanvasMinimumSharedLabelOverlap
    case .vertical:
      return abs(start.x - segment.coordinate) < 0.5
        && policyCanvasSharedLabelOverlap(yRange, segment.range)
          >= policyCanvasMinimumSharedLabelOverlap
    }
  }

  fileprivate func matchesAny(_ segments: [PolicyCanvasSharedLabelSegment]) -> Bool {
    segments.contains { matches($0) }
  }
}
