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
  target: PolicyCanvasEscapeCandidate,
  context: PolicyCanvasRouteContext
) -> CGFloat {
  guard route.points.count >= 2 else {
    // Degenerate routes (empty or single-point) must lose every flex-anchor
    // ranking. Returning 0 would tie them with a perfect score and they would
    // displace any real candidate; return the largest finite magnitude so they
    // are unconditionally worse than any computed-length route.
    return .greatestFiniteMagnitude
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
    + policyCanvasDisplayedRouteCorridorPenalty(route, context: context)
}

func policyCanvasDisplayedRouteCorridorPenalty(
  _ route: PolicyCanvasEdgeRoute,
  context: PolicyCanvasRouteContext
) -> CGFloat {
  guard let corridorHint = context.corridorHint else {
    return
      policyCanvasHorizontalBandPenalty(route)
      + policyCanvasVerticalBandPenalty(route, context: context)
      + policyCanvasTargetGroupBandPenalty(route, context: context)
  }
  // Mostly-vertical routes (target-local corridor, fan-in to the same column)
  // do not have a meaningful horizontal corridor: the route turns right then
  // travels vertically to the target, so the dominant horizontal segment is
  // a short port-stub at the source. Penalising that stub against the hint's
  // horizontal lane lets a worse-looking down-the-source-column candidate
  // beat the corridor-aligned route on score alone, even when the corridor
  // candidate is the right shape per the layout engine.
  let aspect = policyCanvasRouteAxisAspect(route)
  let horizontalPenaltyScale = aspect.shouldHorizontalPenaltyApply ? CGFloat(1) : CGFloat(0.05)
  var penalty: CGFloat = 0
  if let dominantLane = policyCanvasDominantHorizontalLane(route) {
    penalty +=
      abs(
        dominantLane.y - policyCanvasPreferredHorizontalCorridorY(route, context: context)
      ) * 1_000 * horizontalPenaltyScale
  } else {
    penalty += 250_000
  }
  if let verticalLaneX = corridorHint.verticalLaneX {
    if let dominantVerticalLane = policyCanvasDominantVerticalLane(route) {
      // 100_000 multiplier (was 1_000) ensures off-corridor routes lose to
      // corridor-aligned candidates even when collision-aware retry loops
      // produce alternative shapes with otherwise lower length/bend cost.
      // Without the bump, a corridor route that legitimately uses the hint X
      // but picks up 4M+ in bundle/spacing penalties against non-sibling
      // previous routes loses to a shorter source-local detour that has 0
      // bundle conflict - the fan-out collapses back to a source-column
      // shortcut and the corridor is wasted.
      penalty += abs(dominantVerticalLane.x - verticalLaneX) * 100_000
    } else {
      penalty += 25_000_000
    }
  }
  penalty += policyCanvasVerticalBandPenalty(route, context: context)
  penalty += policyCanvasPreferredHorizontalCorridorBonus(route, context: context)
  penalty += policyCanvasPreferredVerticalCorridorBonus(route, context: context)
  return penalty
}

struct PolicyCanvasRouteAxisAspect {
  let horizontalSpan: CGFloat
  let verticalSpan: CGFloat
  var shouldHorizontalPenaltyApply: Bool { horizontalSpan >= verticalSpan }
}

func policyCanvasRouteAxisAspect(_ route: PolicyCanvasEdgeRoute) -> PolicyCanvasRouteAxisAspect {
  guard let first = route.points.first, let last = route.points.last else {
    return PolicyCanvasRouteAxisAspect(horizontalSpan: 0, verticalSpan: 0)
  }
  return PolicyCanvasRouteAxisAspect(
    horizontalSpan: abs(last.x - first.x),
    verticalSpan: abs(last.y - first.y)
  )
}

func policyCanvasRouteUsesPreferredCorridor(
  _ route: PolicyCanvasEdgeRoute,
  context: PolicyCanvasRouteContext
) -> Bool {
  guard let corridorHint = context.corridorHint else {
    return policyCanvasHorizontalBandPenalty(route) == 0
  }
  guard let dominantLane = policyCanvasDominantHorizontalLane(route) else {
    return false
  }
  let tolerance = max(context.lineSpacing * 1.5, PolicyCanvasLayout.gridSize)
  let horizontalMatch =
    abs(dominantLane.y - policyCanvasPreferredHorizontalCorridorY(route, context: context))
    <= tolerance
  guard let verticalLaneX = corridorHint.verticalLaneX else {
    return horizontalMatch
  }
  guard let dominantVerticalLane = policyCanvasDominantVerticalLane(route) else {
    return false
  }
  return
    horizontalMatch
    && abs(dominantVerticalLane.x - verticalLaneX) <= tolerance
}

enum PolicyCanvasSegmentAxis {
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

private func policyCanvasVerticalBandPenalty(
  _ route: PolicyCanvasEdgeRoute,
  context: PolicyCanvasRouteContext
) -> CGFloat {
  guard
    let source = route.points.first,
    let target = route.points.last,
    let dominantLane = policyCanvasDominantVerticalLane(route)
  else {
    return 0
  }
  let horizontalSpan = abs(target.x - source.x)
  let verticalSpan = abs(target.y - source.y)
  guard verticalSpan > horizontalSpan else {
    return 0
  }
  let margin = max(context.lineSpacing * 2, PolicyCanvasLayout.gridSize * 2)
  let minX = min(source.x, target.x) - margin
  let maxX = max(source.x, target.x) + margin
  if dominantLane.x < minX {
    return (minX - dominantLane.x) * 120
  }
  if dominantLane.x > maxX {
    return (dominantLane.x - maxX) * 120
  }
  return 0
}

private func policyCanvasTargetGroupBandPenalty(
  _ route: PolicyCanvasEdgeRoute,
  context: PolicyCanvasRouteContext
) -> CGFloat {
  guard
    let targetGroupID = context.targetGroupID,
    let targetGroup = context.groups.first(where: { $0.id == targetGroupID }),
    let dominantLane = policyCanvasDominantHorizontalLane(route)
  else {
    return 0
  }

  if dominantLane.y < targetGroup.frame.minY {
    return (targetGroup.frame.minY - dominantLane.y) * 300
  }
  if dominantLane.y > targetGroup.frame.maxY {
    return (dominantLane.y - targetGroup.frame.maxY) * 300
  }
  return 0
}

private func policyCanvasPreferredVerticalCorridorBonus(
  _ route: PolicyCanvasEdgeRoute,
  context: PolicyCanvasRouteContext
) -> CGFloat {
  guard
    let corridorHint = context.corridorHint,
    let verticalLaneX = corridorHint.verticalLaneX,
    let dominantVerticalLane = policyCanvasDominantVerticalLane(route),
    let source = route.points.first,
    let target = route.points.last
  else {
    return 0
  }
  let verticalSpan = abs(target.y - source.y)
  let horizontalSpan = abs(target.x - source.x)
  let tolerance = max(context.lineSpacing * 1.5, PolicyCanvasLayout.gridSize)
  guard
    verticalSpan >= horizontalSpan * 2,
    abs(dominantVerticalLane.x - verticalLaneX) <= tolerance
  else {
    return 0
  }
  return -80_000
}

private func policyCanvasPreferredHorizontalCorridorBonus(
  _ route: PolicyCanvasEdgeRoute,
  context: PolicyCanvasRouteContext
) -> CGFloat {
  guard
    let dominantHorizontalLane = policyCanvasDominantHorizontalLane(route),
    let source = route.points.first,
    let target = route.points.last
  else {
    return 0
  }
  let horizontalSpan = abs(target.x - source.x)
  let verticalSpan = abs(target.y - source.y)
  let tolerance = max(context.lineSpacing * 1.5, PolicyCanvasLayout.gridSize)
  guard
    horizontalSpan >= verticalSpan,
    abs(
      dominantHorizontalLane.y - policyCanvasPreferredHorizontalCorridorY(route, context: context)
    ) <= tolerance
  else {
    return 0
  }
  return -80_000
}

private func policyCanvasPreferredHorizontalCorridorY(
  _ route: PolicyCanvasEdgeRoute,
  context: PolicyCanvasRouteContext
) -> CGFloat {
  guard let corridorHint = context.corridorHint else {
    return 0
  }
  // Anchor the preferred Y on the route's actual endpoint, not on
  // `context.targetActual`. `context.targetActual` is set up-front from
  // `viewModel.portAnchors`, which uses the endpoint's default side (leading
  // for inputs). When the route resolves to a different side - e.g. the
  // top-port arrival picked by the visibility router - the leading anchor
  // sits at the target's vertical mid (target.y + nodeHeight/2), pushing
  // `preferredY` past the target's top edge. A geometrically valid corridor
  // route then mis-scores against the wrong reference and gets rejected.
  guard let endpoint = route.points.last else {
    return corridorHint.horizontalLaneY
  }
  let offset = max(context.lineSpacing * 1.5, PolicyCanvasLayout.gridSize * 2)
  switch policyCanvasRouteTargetSide(route) {
  case .top:
    return min(corridorHint.horizontalLaneY, endpoint.y - offset)
  case .bottom:
    return max(corridorHint.horizontalLaneY, endpoint.y + offset)
  case .leading, .trailing, .none:
    return corridorHint.horizontalLaneY
  }
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
