import SwiftUI

struct PolicyCanvasEscapeCandidate {
  let side: PolicyCanvasPortSide
  let actual: CGPoint
  let exit: CGPoint
  let routed: CGPoint
}

func policyCanvasBridgedRoute(
  baseRoute: PolicyCanvasEdgeRoute,
  source: PolicyCanvasEscapeCandidate,
  target: PolicyCanvasEscapeCandidate
) -> PolicyCanvasEdgeRoute {
  var points: [CGPoint] = []
  policyCanvasAppendUniquePoint(source.actual, to: &points)
  policyCanvasAppendUniquePoint(source.exit, to: &points)
  policyCanvasAppendUniquePoint(source.routed, to: &points)
  for point in baseRoute.points.dropFirst() {
    policyCanvasAppendUniquePoint(point, to: &points)
  }
  policyCanvasAppendUniquePoint(target.exit, to: &points)
  policyCanvasAppendUniquePoint(target.actual, to: &points)
  let compressed = PolicyCanvasVisibilityRouter.compressCollinear(points)
  return PolicyCanvasEdgeRoute(
    points: compressed,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
  )
}

func policyCanvasDisplayedRouteScore(
  _ route: PolicyCanvasEdgeRoute,
  source: PolicyCanvasEscapeCandidate,
  target: PolicyCanvasEscapeCandidate
) -> CGFloat {
  guard route.points.count >= 2 else {
    return 0
  }
  var length: CGFloat = 0
  var bends = 0
  var previousAxis: PolicyCanvasSegmentAxis?
  for index in 0..<(route.points.count - 1) {
    let start = route.points[index]
    let end = route.points[index + 1]
    let dx = end.x - start.x
    let dy = end.y - start.y
    length += abs(dx) + abs(dy)
    let axis = policyCanvasSegmentAxis(dx: dx, dy: dy)
    if let axis {
      if let previousAxis, previousAxis != axis {
        bends += 1
      }
      previousAxis = axis
    }
  }
  return
    length
    + (CGFloat(bends) * PolicyCanvasVisibilityRouter.bendPenalty)
    + policyCanvasPortAlignmentPenalty(route: route, endpoint: source)
    + policyCanvasPortAlignmentPenalty(route: route, endpoint: target)
    + policyCanvasHorizontalBandPenalty(route)
}

private enum PolicyCanvasSegmentAxis {
  case horizontal
  case vertical
}

private func policyCanvasAppendUniquePoint(_ point: CGPoint, to points: inout [CGPoint]) {
  guard points.last != point else {
    return
  }
  points.append(point)
}

private func policyCanvasSegmentAxis(dx: CGFloat, dy: CGFloat) -> PolicyCanvasSegmentAxis? {
  if abs(dx) > 0.001 {
    return .horizontal
  }
  if abs(dy) > 0.001 {
    return .vertical
  }
  return nil
}

private func policyCanvasPortAlignmentPenalty(
  route: PolicyCanvasEdgeRoute,
  endpoint: PolicyCanvasEscapeCandidate
) -> CGFloat {
  guard
    let dominantBus = policyCanvasDominantInternalBus(route),
    let preferredSide = policyCanvasPreferredPortSide(
      for: endpoint.actual,
      dominantBus: dominantBus
    ),
    preferredSide != endpoint.side
  else {
    return 0
  }
  return PolicyCanvasVisibilityRouter.bendPenalty * 0.75
}

func policyCanvasHorizontalBandPenalty(_ route: PolicyCanvasEdgeRoute) -> CGFloat {
  guard
    let source = route.points.first,
    let target = route.points.last
  else {
    return 0
  }
  let horizontalSpan = abs(target.x - source.x)
  let verticalSpan = abs(target.y - source.y)
  guard horizontalSpan > verticalSpan,
    let dominantLane = policyCanvasDominantHorizontalLane(route)
  else {
    return 0
  }

  let margin = PolicyCanvasLayout.defaultEdgeLineSpacing * 1.5
  let minY = min(source.y, target.y) - margin
  let maxY = max(source.y, target.y) + margin
  if dominantLane.y < minY {
    return (minY - dominantLane.y) * 80
  }
  if dominantLane.y > maxY {
    return (dominantLane.y - maxY) * 80
  }
  return 0
}

private func policyCanvasPreferredPortSide(
  for point: CGPoint,
  dominantBus: (axis: PolicyCanvasSegmentAxis, coordinate: CGFloat)
) -> PolicyCanvasPortSide? {
  switch dominantBus.axis {
  case .horizontal:
    if dominantBus.coordinate < point.y - 0.001 {
      return .top
    }
    if dominantBus.coordinate > point.y + 0.001 {
      return .bottom
    }
  case .vertical:
    if dominantBus.coordinate < point.x - 0.001 {
      return .leading
    }
    if dominantBus.coordinate > point.x + 0.001 {
      return .trailing
    }
  }
  return nil
}

private func policyCanvasDominantInternalBus(
  _ route: PolicyCanvasEdgeRoute
) -> (axis: PolicyCanvasSegmentAxis, coordinate: CGFloat)? {
  guard route.points.count >= 4 else {
    return nil
  }
  var best: PolicyCanvasInternalBusCandidate?
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    let length: CGFloat
    let axis: PolicyCanvasSegmentAxis
    let coordinate: CGFloat
    if abs(start.y - end.y) < 0.001 {
      length = abs(end.x - start.x)
      axis = .horizontal
      coordinate = start.y
    } else if abs(start.x - end.x) < 0.001 {
      length = abs(end.y - start.y)
      axis = .vertical
      coordinate = start.x
    } else {
      continue
    }
    if let best, length <= best.length { continue }
    best = PolicyCanvasInternalBusCandidate(length: length, axis: axis, coordinate: coordinate)
  }
  return best.map { ($0.axis, $0.coordinate) }
}

private func policyCanvasDominantHorizontalLane(
  _ route: PolicyCanvasEdgeRoute
) -> (y: CGFloat, length: CGFloat)? {
  guard route.points.count >= 4 else {
    return nil
  }
  var best: (y: CGFloat, length: CGFloat)?
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    guard abs(start.y - end.y) < 0.001 else {
      continue
    }
    let length = abs(end.x - start.x)
    if best.map({ length > $0.length }) ?? true {
      best = (start.y, length)
    }
  }
  return best
}

func policyCanvasDominantHorizontalLaneCoordinate(
  _ route: PolicyCanvasEdgeRoute
) -> CGFloat? {
  policyCanvasDominantHorizontalLane(route)?.y
}

private struct PolicyCanvasInternalBusCandidate {
  let length: CGFloat
  let axis: PolicyCanvasSegmentAxis
  let coordinate: CGFloat
}
