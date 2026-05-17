import SwiftUI

struct PolicyCanvasDisplayedRouteCandidate {
  let route: PolicyCanvasEdgeRoute
}

struct PolicyCanvasRouteRetryOffset: Hashable {
  let routeLaneDelta: Int
  let sourceFanoutDelta: Int
  let targetFanoutDelta: Int

  static let zero = PolicyCanvasRouteRetryOffset()

  init(
    routeLaneDelta: Int = 0,
    sourceFanoutDelta: Int = 0,
    targetFanoutDelta: Int = 0
  ) {
    self.routeLaneDelta = routeLaneDelta
    self.sourceFanoutDelta = sourceFanoutDelta
    self.targetFanoutDelta = targetFanoutDelta
  }

  var penalty: CGFloat {
    let fanout = sourceFanoutDelta + targetFanoutDelta
    return (CGFloat(routeLaneDelta) * 125) + (CGFloat(fanout) * 90)
  }
}

struct PolicyCanvasRouteMetrics {
  let length: CGFloat
  let bends: Int
  let segmentCount: Int
}

func policyCanvasDisplayedRouteCandidates(
  _ request: PolicyCanvasResolvedDisplayedRouteRequest,
  offset: PolicyCanvasRouteRetryOffset
) -> [PolicyCanvasDisplayedRouteCandidate] {
  let context = policyCanvasRetryRouteContext(request, offset: offset)
  let sourceFanoutLane = max(0, request.sourceFanoutLane + offset.sourceFanoutDelta)
  let targetFanoutLane = max(0, request.targetFanoutLane + offset.targetFanoutDelta)

  if request.edge.effectivePinnedPortSide {
    return [
      PolicyCanvasDisplayedRouteCandidate(
        route: policyCanvasDisplayedRoute(
          PolicyCanvasPinnedDisplayedRouteRequest(
            router: request.router,
            source: request.sourceAnchor,
            sourceFanoutLane: sourceFanoutLane,
            target: request.targetAnchor,
            targetFanoutLane: targetFanoutLane,
            context: context
          )
        )
      )
    ]
  }

  let sources = request.sourceCandidates
  let targets = request.targetCandidates
  guard !sources.isEmpty, !targets.isEmpty else {
    return []
  }
  var candidates: [PolicyCanvasDisplayedRouteCandidate] = []
  candidates.reserveCapacity(sources.count * targets.count)
  for source in sources {
    for target in targets {
      let route = policyCanvasDisplayedRoute(
        PolicyCanvasPinnedDisplayedRouteRequest(
          router: request.router,
          source: source,
          sourceFanoutLane: sourceFanoutLane,
          target: target,
          targetFanoutLane: targetFanoutLane,
          context: context
        )
      )
      candidates.append(PolicyCanvasDisplayedRouteCandidate(route: route))
    }
  }
  return candidates
}

func policyCanvasRouteMetrics(_ route: PolicyCanvasEdgeRoute) -> PolicyCanvasRouteMetrics {
  guard route.points.count >= 2 else {
    return PolicyCanvasRouteMetrics(length: 0, bends: 0, segmentCount: 0)
  }
  var length: CGFloat = 0
  var bends = 0
  var segmentCount = 0
  var previousAxis: PolicyCanvasRouteMetricAxis?
  for (start, end) in zip(route.points, route.points.dropFirst()) {
    let dx = end.x - start.x
    let dy = end.y - start.y
    guard abs(dx) > 0.001 || abs(dy) > 0.001 else {
      continue
    }
    length += abs(dx) + abs(dy)
    segmentCount += 1
    guard let axis = policyCanvasRouteMetricAxis(dx: dx, dy: dy) else {
      continue
    }
    if let previousAxis, previousAxis != axis {
      bends += 1
    }
    previousAxis = axis
  }
  return PolicyCanvasRouteMetrics(length: length, bends: bends, segmentCount: segmentCount)
}

private func policyCanvasRetryRouteContext(
  _ request: PolicyCanvasResolvedDisplayedRouteRequest,
  offset: PolicyCanvasRouteRetryOffset
) -> PolicyCanvasRouteContext {
  return PolicyCanvasRouteContext(
    lane: max(0, request.routeLane + offset.routeLaneDelta),
    groups: request.groups,
    sourceGroupID: request.sourceGroupID,
    targetGroupID: request.targetGroupID,
    obstacles: request.obstacles,
    sourceActual: request.source,
    targetActual: request.target,
    lineSpacing: request.lineSpacing
  )
}

private enum PolicyCanvasRouteMetricAxis {
  case horizontal
  case vertical
}

private func policyCanvasRouteMetricAxis(
  dx: CGFloat,
  dy: CGFloat
) -> PolicyCanvasRouteMetricAxis? {
  if abs(dx) > 0.001, abs(dy) > 0.001 {
    return nil
  }
  if abs(dx) > 0.001 {
    return .horizontal
  }
  if abs(dy) > 0.001 {
    return .vertical
  }
  return nil
}
