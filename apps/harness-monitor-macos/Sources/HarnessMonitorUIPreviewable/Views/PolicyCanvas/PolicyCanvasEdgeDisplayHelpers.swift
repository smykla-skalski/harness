import SwiftUI

struct PolicyCanvasDisplayedEdgeRouteRequest {
  let router: any PolicyCanvasEdgeRouter
  let viewModel: PolicyCanvasViewModel
  let edge: PolicyCanvasEdge
  let source: CGPoint
  let target: CGPoint
  let routeLane: Int
  let sourceFanoutLane: Int
  let targetFanoutLane: Int
  let sourceTerminalSlot: PolicyCanvasRouteEndpointSlot
  let targetTerminalSlot: PolicyCanvasRouteEndpointSlot
  let lineSpacing: CGFloat
  let obstacles: [CGRect]
}

struct PolicyCanvasResolvedDisplayedRouteRequest {
  let router: any PolicyCanvasEdgeRouter
  let edge: PolicyCanvasEdge
  let source: CGPoint
  let target: CGPoint
  let routeLane: Int
  let sourceFanoutLane: Int
  let targetFanoutLane: Int
  let lineSpacing: CGFloat
  let obstacles: [CGRect]
  let groups: [PolicyCanvasGroup]
  let sourceGroupID: String?
  let targetGroupID: String?
  let sourceAnchor: PolicyCanvasRouteAnchorCandidate
  let targetAnchor: PolicyCanvasRouteAnchorCandidate
  let sourceCandidates: [PolicyCanvasRouteAnchorCandidate]
  let targetCandidates: [PolicyCanvasRouteAnchorCandidate]
  let sourceSpacingBySide: [PolicyCanvasPortSide: CGFloat]
  let targetSpacingBySide: [PolicyCanvasPortSide: CGFloat]
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
  let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
  let terminalSlots = policyCanvasRouteEndpointSlots(edges: orderedEdges)
  var routes: [String: PolicyCanvasEdgeRoute] = [:]
  var previousRoutes: [PolicyCanvasDisplayedRouteClearance] = []
  for edge in orderedEdges {
    guard let source = portAnchors[edge.source], let target = portAnchors[edge.target] else {
      continue
    }
    let edgeTerminalSlots = terminalSlots[edge.id]
    let request = policyCanvasResolvedDisplayedRouteRequest(
      PolicyCanvasDisplayedEdgeRouteRequest(
        router: router,
        viewModel: viewModel,
        edge: edge,
        source: source,
        target: target,
        routeLane: edgeLanes[edge.id, default: 0],
        sourceFanoutLane: sourceFanoutLanes[edge.id, default: 0],
        targetFanoutLane: targetFanoutLanes[edge.id, default: 0],
        sourceTerminalSlot: edgeTerminalSlots?.source ?? .single,
        targetTerminalSlot: edgeTerminalSlots?.target ?? .single,
        lineSpacing: viewModel.edgeLineSpacing(for: edge),
        obstacles: viewModel.routingObstacles(source: source, target: target)
      )
    )
    let route = policyCanvasCollisionAwareDisplayedRoute(
      request,
      previousRoutes: previousRoutes
    )
    routes[edge.id] = route
    previousRoutes.append(
      PolicyCanvasDisplayedRouteClearance(
        route: route,
        minimumSpacing: policyCanvasRouteMinimumSpacing(request: request, route: route)
      )
    )
  }
  return routes
}

@MainActor
func policyCanvasResolvedDisplayedRouteRequest(
  _ request: PolicyCanvasDisplayedEdgeRouteRequest
) -> PolicyCanvasResolvedDisplayedRouteRequest {
  let sourceGroupID = request.viewModel.node(request.edge.source.nodeID)?.groupID
  let targetGroupID = request.viewModel.node(request.edge.target.nodeID)?.groupID
  let sourceSide = policyCanvasResolvedPortSide(for: request.edge.source)
  let targetSide = policyCanvasResolvedPortSide(for: request.edge.target)
  let sourceCandidates = policyCanvasRouteAnchorCandidates(
    for: request.edge.source,
    in: request.viewModel,
    terminalSlot: request.sourceTerminalSlot
  )
  let targetCandidates = policyCanvasRouteAnchorCandidates(
    for: request.edge.target,
    in: request.viewModel,
    terminalSlot: request.targetTerminalSlot
  )
  return PolicyCanvasResolvedDisplayedRouteRequest(
    router: request.router,
    edge: request.edge,
    source: request.source,
    target: request.target,
    routeLane: request.routeLane,
    sourceFanoutLane: request.sourceFanoutLane,
    targetFanoutLane: request.targetFanoutLane,
    lineSpacing: request.lineSpacing,
    obstacles: request.obstacles,
    groups: request.viewModel.groups,
    sourceGroupID: sourceGroupID,
    targetGroupID: targetGroupID,
    sourceAnchor: sourceCandidates.first(where: { $0.side == sourceSide })
      ?? (point: request.source, side: sourceSide),
    targetAnchor: targetCandidates.first(where: { $0.side == targetSide })
      ?? (point: request.target, side: targetSide),
    sourceCandidates: sourceCandidates,
    targetCandidates: targetCandidates,
    sourceSpacingBySide: policyCanvasPortSpacingBySide(
      viewModel: request.viewModel,
      endpoint: request.edge.source
    ),
    targetSpacingBySide: policyCanvasPortSpacingBySide(
      viewModel: request.viewModel,
      endpoint: request.edge.target
    )
  )
}

@MainActor
private func policyCanvasPortSpacingBySide(
  viewModel: PolicyCanvasViewModel,
  endpoint: PolicyCanvasPortEndpoint
) -> [PolicyCanvasPortSide: CGFloat] {
  Dictionary(
    uniqueKeysWithValues: PolicyCanvasPortSide.allSides.map { side in
      (side, viewModel.portSpacing(for: endpoint, side: side))
    }
  )
}

@MainActor
func policyCanvasDisplayedRoute(
  _ request: PolicyCanvasDisplayedEdgeRouteRequest
) -> PolicyCanvasEdgeRoute {
  policyCanvasDisplayedRoute(policyCanvasResolvedDisplayedRouteRequest(request))
}

func policyCanvasDisplayedRoute(
  _ request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  let context = PolicyCanvasRouteContext(
    lane: request.routeLane,
    groups: request.groups,
    sourceGroupID: request.sourceGroupID,
    targetGroupID: request.targetGroupID,
    obstacles: request.obstacles,
    sourceActual: request.source,
    targetActual: request.target,
    lineSpacing: request.lineSpacing
  )
  if request.edge.effectivePinnedPortSide {
    return policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: request.router,
        source: request.sourceAnchor,
        sourceFanoutLane: request.sourceFanoutLane,
        target: request.targetAnchor,
        targetFanoutLane: request.targetFanoutLane,
        context: context
      )
    )
  }
  return policyCanvasDisplayedRoute(
    PolicyCanvasFlexibleDisplayedRouteRequest(
      router: request.router,
      sourceCandidates: request.sourceCandidates,
      sourceFanoutLane: request.sourceFanoutLane,
      targetCandidates: request.targetCandidates,
      targetFanoutLane: request.targetFanoutLane,
      context: context
    )
  )
}

@MainActor
func policyCanvasResolvedLabelPositions(
  viewModel: PolicyCanvasViewModel,
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute],
  fontScale: CGFloat
) -> [String: CGPoint] {
  let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
  let labelledRoutes: [(id: String, route: PolicyCanvasEdgeRoute)] = edges.compactMap { edge in
    guard !edge.label.isEmpty, let route = routes[edge.id] else {
      return nil
    }
    return (id: edge.id, route: route)
  }
  return policyCanvasResolvedLabelPositions(
    routes: labelledRoutes,
    nodeFrames: viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    } + policyCanvasGroupTitleFrames(viewModel.groups),
    routeFrames: policyCanvasRouteFrames(labelledRoutes),
    labelSize: CGSize(width: PolicyCanvasLayout.edgeLabelMaxWidth, height: metrics.height)
  )
}

func policyCanvasResolvedPortSide(for endpoint: PolicyCanvasPortEndpoint) -> PolicyCanvasPortSide {
  endpoint.side ?? (endpoint.kind == .input ? .leading : .trailing)
}

func policyCanvasResolvedLabelPositions(
  routes: [(id: String, route: PolicyCanvasEdgeRoute)],
  nodeFrames: [CGRect],
  labelSize: CGSize
) -> [String: CGPoint] {
  policyCanvasResolvedLabelPositions(
    routes: routes,
    nodeFrames: nodeFrames,
    routeFrames: [:],
    labelSize: labelSize
  )
}

func policyCanvasResolvedLabelPositions(
  routes: [(id: String, route: PolicyCanvasEdgeRoute)],
  nodeFrames: [CGRect],
  routeFrames: [String: [CGRect]],
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
    let blockingRouteFrames = routeFrames.reduce(into: [CGRect]()) { result, element in
      guard element.key != entry.id else {
        return
      }
      result.append(contentsOf: element.value)
    }
    let position = policyCanvasResolvedLabelPosition(
      base: base,
      occupiedFrames: occupiedFrames,
      nodeFrames: nodeFrames,
      routeFrames: blockingRouteFrames,
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
  routeFrames: [CGRect],
  labelSize: CGSize
) -> CGPoint {
  for candidate in policyCanvasLabelCandidates(base: base, labelSize: labelSize) {
    let frame = policyCanvasLabelFrame(center: candidate, size: labelSize)
    if !occupiedFrames.contains(where: { $0.intersects(frame) })
      && !nodeFrames.contains(where: { $0.intersects(frame) })
      && !routeFrames.contains(where: { $0.intersects(frame) })
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
