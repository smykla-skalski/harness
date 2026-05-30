import SwiftUI

func policyCanvasDominantInternalBus(
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

func policyCanvasDominantHorizontalLane(
  _ route: PolicyCanvasEdgeRoute
) -> (y: CGFloat, length: CGFloat)? {
  guard route.points.count >= 3 else {
    return nil
  }
  var best: (y: CGFloat, length: CGFloat)?
  // Iterate ALL segments. The longest-horizontal selection naturally favors
  // the bus over short port-stub segments at the endpoints, so the previous
  // 1..<(count-2) range was over-restrictive: a 4-point route whose bus
  // landed at segment 0 or last (after compressCollinear) wrongly returned
  // nil.
  for index in 0..<(route.points.count - 1) {
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

func policyCanvasDominantVerticalLaneCoordinate(
  _ route: PolicyCanvasEdgeRoute
) -> CGFloat? {
  policyCanvasDominantVerticalLane(route)?.x
}

func policyCanvasDominantVerticalLane(
  _ route: PolicyCanvasEdgeRoute
) -> (x: CGFloat, length: CGFloat)? {
  guard route.points.count >= 3 else {
    return nil
  }
  var best: (x: CGFloat, length: CGFloat)?
  // Iterate ALL segments (see horizontal lane note above).
  for index in 0..<(route.points.count - 1) {
    let start = route.points[index]
    let end = route.points[index + 1]
    guard abs(start.x - end.x) < 0.001 else {
      continue
    }
    let length = abs(end.y - start.y)
    if best.map({ length > $0.length }) ?? true {
      best = (start.x, length)
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
