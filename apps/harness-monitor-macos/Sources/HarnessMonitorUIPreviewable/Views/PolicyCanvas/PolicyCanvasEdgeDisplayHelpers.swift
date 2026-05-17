import SwiftUI

private struct PolicyCanvasDisplayedEdgeRouteRequest {
  let router: any PolicyCanvasEdgeRouter
  let viewModel: PolicyCanvasViewModel
  let edge: PolicyCanvasEdge
  let source: CGPoint
  let target: CGPoint
  let routeLane: Int
  let sourceFanoutLane: Int
  let targetFanoutLane: Int
  let lineSpacing: CGFloat
  let obstacles: [CGRect]
}

@MainActor
func policyCanvasDisplayedRoutes(
  viewModel: PolicyCanvasViewModel,
  edges: [PolicyCanvasEdge],
  portAnchors: [PolicyCanvasPortEndpoint: CGPoint],
  router: any PolicyCanvasEdgeRouter
) -> [String: PolicyCanvasEdgeRoute] {
  let edgeLanes = viewModel.edgeRouteLanes
  let sourceFanoutLanes = viewModel.edgeSourceFanoutLanes
  let targetFanoutLanes = viewModel.edgeTargetFanoutLanes
  return edges.reduce(into: [String: PolicyCanvasEdgeRoute]()) { routes, edge in
    guard let source = portAnchors[edge.source], let target = portAnchors[edge.target] else {
      return
    }
    routes[edge.id] = policyCanvasDisplayedRoute(
      PolicyCanvasDisplayedEdgeRouteRequest(
        router: router,
        viewModel: viewModel,
        edge: edge,
        source: source,
        target: target,
        routeLane: edgeLanes[edge.id, default: 0],
        sourceFanoutLane: sourceFanoutLanes[edge.id, default: 0],
        targetFanoutLane: targetFanoutLanes[edge.id, default: 0],
        lineSpacing: viewModel.edgeLineSpacing(for: edge),
        obstacles: viewModel.routingObstacles(source: source, target: target)
      )
    )
  }
}

@MainActor
func policyCanvasResolvedLabelPositions(
  viewModel: PolicyCanvasViewModel,
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute],
  fontScale: CGFloat
) -> [String: CGPoint] {
  let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
  return policyCanvasResolvedLabelPositions(
    routes: edges.compactMap { edge in
      guard !edge.label.isEmpty, let route = routes[edge.id] else {
        return nil
      }
      return (id: edge.id, route: route)
    },
    nodeFrames: viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    },
    labelSize: CGSize(width: PolicyCanvasLayout.edgeLabelMaxWidth, height: metrics.height)
  )
}

@MainActor
private func policyCanvasDisplayedRoute(
  _ request: PolicyCanvasDisplayedEdgeRouteRequest
) -> PolicyCanvasEdgeRoute {
  let sourceGroupID = request.viewModel.node(request.edge.source.nodeID)?.groupID
  let targetGroupID = request.viewModel.node(request.edge.target.nodeID)?.groupID
  let context = PolicyCanvasRouteContext(
    lane: request.routeLane,
    groups: request.viewModel.groups,
    sourceGroupID: sourceGroupID,
    targetGroupID: targetGroupID,
    obstacles: request.obstacles,
    sourceActual: request.source,
    targetActual: request.target,
    lineSpacing: request.lineSpacing
  )
  if request.edge.effectivePinnedPortSide {
    return policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: request.router,
        source: (point: request.source, side: resolvedPortSide(for: request.edge.source)),
        sourceFanoutLane: request.sourceFanoutLane,
        target: (point: request.target, side: resolvedPortSide(for: request.edge.target)),
        targetFanoutLane: request.targetFanoutLane,
        context: context
      )
    )
  }
  return policyCanvasDisplayedRoute(
    PolicyCanvasFlexibleDisplayedRouteRequest(
      router: request.router,
      sourceCandidates: routeAnchorCandidates(for: request.edge.source, in: request.viewModel),
      sourceFanoutLane: request.sourceFanoutLane,
      targetCandidates: routeAnchorCandidates(for: request.edge.target, in: request.viewModel),
      targetFanoutLane: request.targetFanoutLane,
      context: context
    )
  )
}

private func resolvedPortSide(for endpoint: PolicyCanvasPortEndpoint) -> PolicyCanvasPortSide {
  endpoint.side ?? (endpoint.kind == .input ? .leading : .trailing)
}

@MainActor
private func routeAnchorCandidates(
  for endpoint: PolicyCanvasPortEndpoint,
  in viewModel: PolicyCanvasViewModel
) -> [PolicyCanvasRouteAnchorCandidate] {
  let points = viewModel.portAnchorCandidates(for: endpoint)
  return zip(PolicyCanvasPortSide.allSides, points).map { side, point in
    (point: point, side: side)
  }
}

func policyCanvasResolvedLabelPositions(
  routes: [(id: String, route: PolicyCanvasEdgeRoute)],
  nodeFrames: [CGRect],
  labelSize: CGSize
) -> [String: CGPoint] {
  var occupiedFrames: [CGRect] = []
  var positions: [String: CGPoint] = [:]
  let sortedRoutes = routes.sorted { left, right in
    if left.route.labelPosition.y != right.route.labelPosition.y {
      return left.route.labelPosition.y < right.route.labelPosition.y
    }
    if left.route.labelPosition.x != right.route.labelPosition.x {
      return left.route.labelPosition.x < right.route.labelPosition.x
    }
    return left.id < right.id
  }
  for entry in sortedRoutes {
    let base = entry.route.labelPosition
    let position = policyCanvasResolvedLabelPosition(
      base: base,
      occupiedFrames: occupiedFrames,
      nodeFrames: nodeFrames,
      labelSize: labelSize
    )
    positions[entry.id] = position
    occupiedFrames.append(policyCanvasLabelFrame(center: position, size: labelSize))
  }
  return positions
}

private func policyCanvasResolvedLabelPosition(
  base: CGPoint,
  occupiedFrames: [CGRect],
  nodeFrames: [CGRect],
  labelSize: CGSize
) -> CGPoint {
  for candidate in policyCanvasLabelCandidates(base: base, labelSize: labelSize) {
    let frame = policyCanvasLabelFrame(center: candidate, size: labelSize)
    if !occupiedFrames.contains(where: { $0.intersects(frame) })
      && !nodeFrames.contains(where: { $0.intersects(frame) })
    {
      return candidate
    }
  }
  return base
}

private func policyCanvasLabelCandidates(
  base: CGPoint,
  labelSize: CGSize
) -> [CGPoint] {
  let verticalStep = labelSize.height + 6
  let horizontalStep = max(labelSize.width + 24, 160)
  var candidates: [CGPoint] = [base]

  for index in 1..<6 {
    candidates.append(
      CGPoint(
        x: base.x,
        y: base.y + policyCanvasSignedLaneOffset(index: index, spacing: verticalStep)
      )
    )
  }

  for index in 1..<5 {
    candidates.append(
      CGPoint(
        x: base.x + policyCanvasSignedLaneOffset(index: index, spacing: horizontalStep),
        y: base.y
      )
    )
  }

  for verticalIndex in 1..<4 {
    let yOffset = policyCanvasSignedLaneOffset(index: verticalIndex, spacing: verticalStep)
    for horizontalIndex in 1..<4 {
      let xOffset = policyCanvasSignedLaneOffset(index: horizontalIndex, spacing: horizontalStep)
      candidates.append(CGPoint(x: base.x + xOffset, y: base.y + yOffset))
    }
  }

  var seen: Set<CGPoint> = []
  return candidates.filter { candidate in
    seen.insert(candidate).inserted
  }
}

private func policyCanvasLabelFrame(center: CGPoint, size: CGSize) -> CGRect {
  CGRect(
    x: center.x - (size.width / 2),
    y: center.y - (size.height / 2),
    width: size.width,
    height: size.height
  )
}

struct PolicyCanvasEdgeLabelMetrics {
  let horizontalPadding: CGFloat
  let minWidth: CGFloat
  let height: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(SessionWindowFontScale.metricsScale(for: fontScale), 1.45)
    horizontalPadding = (12 * scale).rounded(.up)
    minWidth = (88 * scale).rounded(.up)
    height = max(
      PolicyCanvasLayout.edgeLabelHeight,
      (PolicyCanvasLayout.edgeLabelHeight * scale).rounded(.up)
    )
  }
}
