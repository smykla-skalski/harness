import CoreGraphics

struct PolicyCanvasEscapeCandidate {
  let side: PolicyCanvasPortSide
  let actual: CGPoint
  let exit: CGPoint
  let routed: CGPoint
}

enum PolicyCanvasSegmentAxis {
  case horizontal
  case vertical
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

func policyCanvasSegmentAxis(dx: CGFloat, dy: CGFloat) -> PolicyCanvasSegmentAxis? {
  if abs(dx) > 0.001 {
    return .horizontal
  }
  if abs(dy) > 0.001 {
    return .vertical
  }
  return nil
}

func policyCanvasRouteSourceSide(_ route: PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide? {
  guard route.points.count >= 2 else {
    return nil
  }
  return policyCanvasRouteSide(from: route.points[0], to: route.points[1])
}

func policyCanvasRouteTargetSide(_ route: PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide? {
  guard route.points.count >= 2,
    let previous = route.points.dropLast().last,
    let target = route.points.last
  else {
    return nil
  }
  return policyCanvasRouteSide(from: target, to: previous)
}

private func policyCanvasRouteSide(from point: CGPoint, to adjacent: CGPoint)
  -> PolicyCanvasPortSide?
{
  if adjacent.x > point.x + 0.001 {
    return .trailing
  }
  if adjacent.x < point.x - 0.001 {
    return .leading
  }
  if adjacent.y > point.y + 0.001 {
    return .bottom
  }
  if adjacent.y < point.y - 0.001 {
    return .top
  }
  return nil
}

private func policyCanvasAppendUniquePoint(_ point: CGPoint, to points: inout [CGPoint]) {
  guard points.last != point else {
    return
  }
  points.append(point)
}
