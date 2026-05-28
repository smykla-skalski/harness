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
  let familyPreference: PolicyCanvasRouteFamilyPreference
  let portMarkerLayout: PolicyCanvasPortMarkerLayout?
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
  let corridorHint: PolicyCanvasEdgeCorridorHint?
}

@MainActor
func policyCanvasDisplayedRoutes(
  viewModel: PolicyCanvasViewModel,
  edges: [PolicyCanvasEdge],
  portAnchors: [PolicyCanvasPortEndpoint: CGPoint],
  router: any PolicyCanvasEdgeRouter
) -> [String: PolicyCanvasEdgeRoute] {
  let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
  let terminalSlots = policyCanvasRouteEndpointSlots(edges: orderedEdges)
  let familyPreferences = policyCanvasRouteFamilyPreferences(edges: edges)
  let initialRoutes = policyCanvasDisplayedRoutes(
    context: PolicyCanvasDisplayedRoutesContext(
      viewModel: viewModel,
      orderedEdges: orderedEdges,
      portAnchors: portAnchors,
      terminalSlots: terminalSlots,
      familyPreferences: familyPreferences,
      portMarkerLayout: nil,
      router: router
    )
  )
  let markerInput = PolicyCanvasRouteWorkerInput(
    graphGeneration: viewModel.routeComputationGeneration,
    nodes: viewModel.nodes,
    groups: viewModel.groups,
    edges: edges,
    fontScale: 1
  )
  let preparedMarkerInput = PolicyCanvasPreparedRouteInput(input: markerInput)
  var portMarkerLayout = preparedMarkerInput.portMarkerLayout(
    routes: initialRoutes,
    nodeIndex: preparedMarkerInput.nodeIndex
  )
  for _ in 0..<3 {
    let routedRoutes = policyCanvasDisplayedRoutes(
      context: PolicyCanvasDisplayedRoutesContext(
        viewModel: viewModel,
        orderedEdges: orderedEdges,
        portAnchors: portAnchors,
        terminalSlots: terminalSlots,
        familyPreferences: familyPreferences,
        portMarkerLayout: portMarkerLayout,
        router: router
      )
    )
    let nextPortMarkerLayout = preparedMarkerInput.portMarkerLayout(
      routes: routedRoutes,
      nodeIndex: preparedMarkerInput.nodeIndex
    )
    if nextPortMarkerLayout == portMarkerLayout {
      return routedRoutes
    }
    portMarkerLayout = nextPortMarkerLayout
  }
  return policyCanvasDisplayedRoutes(
    context: PolicyCanvasDisplayedRoutesContext(
      viewModel: viewModel,
      orderedEdges: orderedEdges,
      portAnchors: portAnchors,
      terminalSlots: terminalSlots,
      familyPreferences: familyPreferences,
      portMarkerLayout: portMarkerLayout,
      router: router
    )
  )
}

private struct PolicyCanvasDisplayedRoutesContext {
  let viewModel: PolicyCanvasViewModel
  let orderedEdges: [PolicyCanvasEdge]
  let portAnchors: [PolicyCanvasPortEndpoint: CGPoint]
  let terminalSlots: [String: PolicyCanvasRouteEndpointSlots]
  let familyPreferences: [String: PolicyCanvasRouteFamilyPreference]
  let portMarkerLayout: PolicyCanvasPortMarkerLayout?
  let router: any PolicyCanvasEdgeRouter
}

@MainActor
private func policyCanvasDisplayedRoutes(
  context: PolicyCanvasDisplayedRoutesContext
) -> [String: PolicyCanvasEdgeRoute] {
  let viewModel = context.viewModel
  let edgeLanes = viewModel.edgeRouteLanes
  let sourceFanoutLanes = viewModel.edgeSourceFanoutLanes
  let targetFanoutLanes = viewModel.edgeTargetFanoutLanes
  var routes: [String: PolicyCanvasEdgeRoute] = [:]
  var previousRoutes: [PolicyCanvasDisplayedRouteClearance] = []
  for edge in context.orderedEdges {
    guard
      let source = context.portAnchors[edge.source],
      let target = context.portAnchors[edge.target]
    else {
      continue
    }
    let edgeTerminalSlots = context.terminalSlots[edge.id]
    let familyPreference = context.familyPreferences[edge.id, default: .none]
    let request = policyCanvasResolvedDisplayedRouteRequest(
      PolicyCanvasDisplayedEdgeRouteRequest(
        router: context.router,
        viewModel: viewModel,
        edge: edge,
        source: source,
        target: target,
        routeLane: edgeLanes[edge.id, default: 0],
        sourceFanoutLane: sourceFanoutLanes[edge.id, default: 0],
        targetFanoutLane: targetFanoutLanes[edge.id, default: 0],
        sourceTerminalSlot: policyCanvasResolvedSourceTerminalSlot(
          edgeTerminalSlots?.source ?? .single,
          familyPreference: familyPreference
        ),
        targetTerminalSlot: edgeTerminalSlots?.target ?? .single,
        familyPreference: familyPreference,
        portMarkerLayout: context.portMarkerLayout,
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
        edge: edge,
        corridorKey: PolicyCanvasPreparedRouteInput.policyCanvasCorridorKey(
          forRoute: route,
          hint: request.corridorHint,
          lineSpacing: request.lineSpacing
        ),
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
  let sourceTerminal = request.portMarkerLayout?.terminal(edgeID: request.edge.id, role: .source)
  let targetTerminal = request.portMarkerLayout?.terminal(edgeID: request.edge.id, role: .target)
  let familyPreferredSourceSide = policyCanvasPreferredFamilySourceSide(
    edge: request.edge,
    familyPreference: request.familyPreference,
    source: request.source,
    target: request.target
  )
  let fixedSourceSide = request.edge.source.side ?? familyPreferredSourceSide
  let fixedTargetSide = request.edge.target.side ?? request.familyPreference.forcedTargetSide
  let effectiveSourceTerminal: PolicyCanvasPortTerminal? = {
    guard let sourceTerminal else {
      return nil
    }
    guard fixedSourceSide == nil || fixedSourceSide == sourceTerminal.side else {
      return nil
    }
    return sourceTerminal
  }()
  let effectiveTargetTerminal: PolicyCanvasPortTerminal? = {
    guard let targetTerminal else {
      return nil
    }
    guard
      fixedTargetSide == nil || fixedTargetSide == targetTerminal.side
    else {
      return nil
    }
    return targetTerminal
  }()
  let preferredSourceSide = fixedSourceSide ?? sourceTerminal?.side
  let preferredTargetSide = fixedTargetSide ?? targetTerminal?.side
  let sourceCandidates = policyCanvasPreferredRouteAnchorCandidates(
    policyCanvasRouteAnchorCandidates(
      for: request.edge.source,
      in: request.viewModel,
      terminalSlot: request.sourceTerminalSlot,
      terminal: effectiveSourceTerminal
    ),
    preferredSide: preferredSourceSide
  )
  let targetCandidates = policyCanvasPreferredRouteAnchorCandidates(
    policyCanvasRouteAnchorCandidates(
      for: request.edge.target,
      in: request.viewModel,
      terminalSlot: request.targetTerminalSlot,
      terminal: effectiveTargetTerminal
    ),
    preferredSide: preferredTargetSide
  )
  let sourceSide = preferredSourceSide ?? policyCanvasResolvedPortSide(for: request.edge.source)
  let targetSide = preferredTargetSide ?? policyCanvasResolvedPortSide(for: request.edge.target)
  let corridorHint = request.viewModel.routingHints?.edgeHint(for: request.edge.id)
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
    ),
    corridorHint: corridorHint
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
  let context = policyCanvasRouteContext(for: request)
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

func policyCanvasRouteContext(
  for request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasRouteContext {
  PolicyCanvasRouteContext(
    lane: request.routeLane,
    groups: request.groups,
    sourceGroupID: request.sourceGroupID,
    targetGroupID: request.targetGroupID,
    obstacles: request.obstacles,
    sourceActual: request.source,
    targetActual: request.target,
    lineSpacing: request.lineSpacing,
    corridorHint: request.corridorHint
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
  let routeFrames = policyCanvasRouteFrames(routes.map { (id: $0.key, route: $0.value) })
  let labelledRoutes: [PolicyCanvasLabelPlacementRoute] = edges.compactMap { edge in
    guard !edge.label.isEmpty, let route = routes[edge.id] else {
      return nil
    }
    return PolicyCanvasLabelPlacementRoute(
      id: edge.id,
      label: edge.label,
      route: route,
      size: metrics.size(for: edge.label)
    )
  }
  return policyCanvasResolvedLabelPositions(
    routes: labelledRoutes,
    nodeFrames: viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    } + policyCanvasGroupTitleFrames(viewModel.groups),
    routeFrames: routeFrames
  )
}

func policyCanvasResolvedPortSide(for endpoint: PolicyCanvasPortEndpoint) -> PolicyCanvasPortSide {
  endpoint.side ?? (endpoint.kind == .input ? .leading : .trailing)
}
