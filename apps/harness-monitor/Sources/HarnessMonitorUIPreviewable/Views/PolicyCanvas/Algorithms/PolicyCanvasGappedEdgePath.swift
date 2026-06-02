import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

func policyCanvasGappedEdgePath(
  route: PolicyCanvasEdgeRoute,
  gapFrames: [CGRect],
  cornerRadius: CGFloat
) -> Path {
  var path = Path()
  for points in policyCanvasVisibleEdgeSubroutes(points: route.points, gapFrames: gapFrames) {
    guard points.count >= 2 else {
      continue
    }
    path.addPath(
      PolicyCanvasEdgeShape(
        route: PolicyCanvasEdgeRoute(points: points, labelPosition: route.labelPosition),
        cornerRadius: cornerRadius
      )
      .path(in: .zero)
    )
  }
  return path
}

private func policyCanvasVisibleEdgeSubroutes(
  points: [CGPoint],
  gapFrames: [CGRect]
) -> [[CGPoint]] {
  var subroutes: [[CGPoint]] = []
  var current: [CGPoint] = []
  for (start, end) in zip(points, points.dropFirst()) {
    for range in policyCanvasVisibleSegmentRanges(start: start, end: end, gapFrames: gapFrames) {
      let visibleStart = policyCanvasInterpolate(
        start: start, end: end, parameter: range.lowerBound)
      let visibleEnd = policyCanvasInterpolate(start: start, end: end, parameter: range.upperBound)
      guard policyCanvasDistance(visibleStart, visibleEnd) > 0.5 else {
        continue
      }
      if current.last.map({ policyCanvasNearlyEqual($0, visibleStart) }) == true {
        policyCanvasAppendDistinct(visibleEnd, to: &current)
      } else {
        policyCanvasFinishSubroute(&current, into: &subroutes)
        current = [visibleStart, visibleEnd]
      }
    }
  }
  policyCanvasFinishSubroute(&current, into: &subroutes)
  return subroutes
}

private func policyCanvasVisibleSegmentRanges(
  start: CGPoint,
  end: CGPoint,
  gapFrames: [CGRect]
) -> [ClosedRange<CGFloat>] {
  let blocked = gapFrames.compactMap { frame in
    policyCanvasBlockedSegmentRange(start: start, end: end, frame: frame)
  }
  return policyCanvasSubtractRanges(blocked.sorted { $0.lowerBound < $1.lowerBound })
}

private func policyCanvasBlockedSegmentRange(
  start: CGPoint,
  end: CGPoint,
  frame: CGRect
) -> ClosedRange<CGFloat>? {
  if abs(start.y - end.y) < 0.001 {
    return policyCanvasBlockedHorizontalRange(start: start, end: end, frame: frame)
  }
  if abs(start.x - end.x) < 0.001 {
    return policyCanvasBlockedVerticalRange(start: start, end: end, frame: frame)
  }
  return nil
}

private func policyCanvasBlockedHorizontalRange(
  start: CGPoint,
  end: CGPoint,
  frame: CGRect
) -> ClosedRange<CGFloat>? {
  guard frame.minY <= start.y, start.y <= frame.maxY else {
    return nil
  }
  return policyCanvasSegmentRange(
    first: frame.minX,
    second: frame.maxX,
    startAxis: start.x,
    endAxis: end.x
  )
}

private func policyCanvasBlockedVerticalRange(
  start: CGPoint,
  end: CGPoint,
  frame: CGRect
) -> ClosedRange<CGFloat>? {
  guard frame.minX <= start.x, start.x <= frame.maxX else {
    return nil
  }
  return policyCanvasSegmentRange(
    first: frame.minY,
    second: frame.maxY,
    startAxis: start.y,
    endAxis: end.y
  )
}

private func policyCanvasSegmentRange(
  first: CGFloat,
  second: CGFloat,
  startAxis: CGFloat,
  endAxis: CGFloat
) -> ClosedRange<CGFloat>? {
  let delta = endAxis - startAxis
  guard abs(delta) > 0.001 else {
    return nil
  }
  let firstT = (first - startAxis) / delta
  let secondT = (second - startAxis) / delta
  let lower = max(0, min(firstT, secondT))
  let upper = min(1, max(firstT, secondT))
  guard upper > 0, lower < 1, upper - lower > 0.001 else {
    return nil
  }
  return lower...upper
}

private func policyCanvasSubtractRanges(
  _ blockedRanges: [ClosedRange<CGFloat>]
) -> [ClosedRange<CGFloat>] {
  var visible: [ClosedRange<CGFloat>] = []
  var cursor: CGFloat = 0
  for blocked in blockedRanges {
    let lower = max(0, blocked.lowerBound)
    let upper = min(1, blocked.upperBound)
    if lower > cursor + 0.001 {
      visible.append(cursor...lower)
    }
    cursor = max(cursor, upper)
  }
  if cursor < 0.999 {
    visible.append(cursor...1)
  }
  return visible
}

private func policyCanvasInterpolate(
  start: CGPoint,
  end: CGPoint,
  parameter: CGFloat
) -> CGPoint {
  CGPoint(
    x: start.x + ((end.x - start.x) * parameter),
    y: start.y + ((end.y - start.y) * parameter)
  )
}

private func policyCanvasAppendDistinct(_ point: CGPoint, to points: inout [CGPoint]) {
  if points.last.map({ policyCanvasNearlyEqual($0, point) }) != true {
    points.append(point)
  }
}

private func policyCanvasFinishSubroute(
  _ current: inout [CGPoint],
  into subroutes: inout [[CGPoint]]
) {
  if current.count >= 2 {
    subroutes.append(current)
  }
  current.removeAll(keepingCapacity: true)
}

private func policyCanvasNearlyEqual(_ left: CGPoint, _ right: CGPoint) -> Bool {
  abs(left.x - right.x) < 0.001 && abs(left.y - right.y) < 0.001
}

private func policyCanvasDistance(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
  hypot(left.x - right.x, left.y - right.y)
}
