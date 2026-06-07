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
  let compressed = policyCanvasCompressPreservingTerminalStubs(points)
  return PolicyCanvasEdgeRoute(
    points: compressed,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
  )
}

func policyCanvasCompressPreservingTerminalStubs(_ points: [CGPoint]) -> [CGPoint] {
  guard points.count >= 4 else {
    return PolicyCanvasVisibilityRouter.compressCollinear(points)
  }
  let sourceActual = points[0]
  let sourceLead = points[1]
  let targetLead = points[points.count - 2]
  let targetActual = points[points.count - 1]
  let compressedInterior = PolicyCanvasVisibilityRouter.compressCollinear(
    Array(points.dropFirst().dropLast())
  )
  var result: [CGPoint] = []
  policyCanvasAppendUniquePoint(sourceActual, to: &result)
  policyCanvasAppendUniquePoint(sourceLead, to: &result)
  for point in compressedInterior.dropFirst().dropLast() {
    policyCanvasAppendUniquePoint(point, to: &result)
  }
  policyCanvasAppendUniquePoint(targetLead, to: &result)
  policyCanvasAppendUniquePoint(targetActual, to: &result)
  return result
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

// A port's outward lead point: step `lead` perpendicular to the port's side,
// away from the node. Routing source/target through these leads forces every
// wire to leave and enter its port perpendicular, so the route's geometric side
// always matches the physical port side (an output never reads as exiting its
// leading edge just because the target sits behind it).
func policyCanvasPortLeadPoint(
  _ anchor: CGPoint,
  side: PolicyCanvasPortSide,
  lead: CGFloat = PolicyCanvasLayout.edgePortTurnMinimumLead
) -> CGPoint {
  switch side {
  case .leading:
    CGPoint(x: anchor.x - lead, y: anchor.y)
  case .trailing:
    CGPoint(x: anchor.x + lead, y: anchor.y)
  case .top:
    CGPoint(x: anchor.x, y: anchor.y - lead)
  case .bottom:
    CGPoint(x: anchor.x, y: anchor.y + lead)
  }
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
