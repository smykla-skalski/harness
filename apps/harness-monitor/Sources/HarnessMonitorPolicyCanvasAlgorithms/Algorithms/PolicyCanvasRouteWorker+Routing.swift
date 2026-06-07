import SwiftUI

struct PolicyCanvasDisplayedRoutePassContext: Sendable {
  let nodeIndex: [String: PolicyCanvasRouteNode]
  let obstacles: [CGRect]
  let portAnchors: [PolicyCanvasPortEndpoint: CGPoint]
  let orderedEdges: [PolicyCanvasEdge]
  let terminalSlots: [String: PolicyCanvasRouteEndpointSlots]
  let familyPreferences: [String: PolicyCanvasRouteFamilyPreference]
  let edgeLanes: [String: Int]
  let sourceFanoutLanes: [String: Int]
  let targetFanoutLanes: [String: Int]
}

public struct PolicyCanvasPreparedRouteComputation: Equatable, Sendable {
  public let routes: [String: PolicyCanvasEdgeRoute]
  public let labelPositions: [String: CGPoint]
  public let portVisibility: PolicyCanvasPortVisibilityMap
  public let portMarkerLayout: PolicyCanvasPortMarkerLayout
  public let visibleBounds: CGRect

  public init(
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint],
    portVisibility: PolicyCanvasPortVisibilityMap,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    visibleBounds: CGRect
  ) {
    self.routes = routes
    self.labelPositions = labelPositions
    self.portVisibility = portVisibility
    self.portMarkerLayout = portMarkerLayout
    self.visibleBounds = visibleBounds
  }
}

extension PolicyCanvasPreparedRouteInput {
  public func routeComputation(
    router defaultRouter: any PolicyCanvasEdgeRouter,
    algorithmSelection: PolicyCanvasAlgorithmSelection
  ) -> PolicyCanvasPreparedRouteComputation {
    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: algorithmSelection)
    let selectedRouter: any PolicyCanvasEdgeRouter =
      algorithmSelection.algorithmID(for: .edgeRouting)
        == PolicyCanvasAlgorithmDefaults.paddedOrthogonalVisibilityAStar
      ? defaultRouter
      : algorithms.edgeRouter
    let nodeIndex = nodeIndex
    let routeState = policyCanvasConvergedRouteState(
      prepared: self,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let processedRoutes = algorithms.routePostProcessing.processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: self, routes: routeState.routes)
    )
    let routes = policyCanvasRoutesPreservingRouteTerminals(
      original: routeState.routes,
      processed: processedRoutes
    )
    let labelPositions = algorithms.labelPlacement.placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: self, routes: routes)
    )
    let visibleBounds = visibleBounds(routes: routes, labelPositions: labelPositions)
    return PolicyCanvasPreparedRouteComputation(
      routes: routes,
      labelPositions: labelPositions,
      portVisibility: portVisibility(routes: routes, nodeIndex: nodeIndex),
      portMarkerLayout: routeState.portMarkerLayout,
      visibleBounds: visibleBounds
    )
  }

  func portVisibility(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortVisibilityMap {
    policyCanvasPortVisibility(edges: edges, routes: routes) { endpoint in
      routeAnchorCandidates(for: endpoint, nodeIndex: nodeIndex)
    }
  }

  private func routingObstacles() -> [CGRect] {
    policyCanvasCanonicalObstacles(nodes.map(\.frame) + policyCanvasGroupTitleFrames(groups))
  }

  func displayedRoutePassContext(
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasDisplayedRoutePassContext {
    let obstacles = routingObstacles()
    let portAnchors = portAnchors(nodeIndex: nodeIndex)
    let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
    let terminalSlots = routeEndpointSlots(edges: orderedEdges, nodeIndex: nodeIndex)
    let familyPreferences = policyCanvasRouteFamilyPreferences(
      edges: edges,
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      nodeGroupIDsByID: nodeIndex.mapValues(\.groupID)
    )
    let edgeLanes = policyCanvasSharedTargetRouteLaneAssignments(
      edges: edges,
      bucket: { edgeRouteBucket($0, nodeIndex: nodeIndex) },
      sortKey: { edgeRouteSortKey($0, nodeIndex: nodeIndex) }
    )
    let sourceFanoutLanes = policyCanvasLaneAssignments(
      edges: edges,
      bucket: edgeSourceFanoutBucket,
      sortKey: { edgeSourceFanoutSortKey($0, nodeIndex: nodeIndex) }
    )
    let targetFanoutLanes = policyCanvasTargetFanoutLaneAssignments(
      edges: edges,
      familyPreferences: familyPreferences,
      bucket: edgeTargetFanoutBucket,
      sortKey: { edgeTargetFanoutSortKey($0, nodeIndex: nodeIndex) }
    )
    return PolicyCanvasDisplayedRoutePassContext(
      nodeIndex: nodeIndex,
      obstacles: obstacles,
      portAnchors: portAnchors,
      orderedEdges: orderedEdges,
      terminalSlots: terminalSlots,
      familyPreferences: familyPreferences,
      edgeLanes: edgeLanes,
      sourceFanoutLanes: sourceFanoutLanes,
      targetFanoutLanes: targetFanoutLanes
    )
  }

  func portAnchors(
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasPortEndpoint: CGPoint] {
    var anchors: [PolicyCanvasPortEndpoint: CGPoint] = [:]
    anchors.reserveCapacity(edges.count * 2)
    for edge in edges {
      if let point = portAnchor(for: edge.source, nodeIndex: nodeIndex) {
        anchors[edge.source] = point
      }
      if let point = portAnchor(for: edge.target, nodeIndex: nodeIndex) {
        anchors[edge.target] = point
      }
    }
    return anchors
  }

  private func routeAnchorCandidates(
    for endpoint: PolicyCanvasPortEndpoint,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminalSlot: PolicyCanvasRouteEndpointSlot = .single,
    terminal: PolicyCanvasPortTerminal? = nil
  ) -> [PolicyCanvasRouteAnchorCandidate] {
    let sides = terminal.map { [$0.side] } ?? policyCanvasRoutablePortSides(for: endpoint.kind)
    return sides.compactMap { side in
      routeAnchorCandidate(
        for: endpoint,
        side: side,
        nodeIndex: nodeIndex,
        terminalSlot: terminalSlot,
        terminal: terminal
      )
    }
  }

  private struct PolicyCanvasRouteComputationState {
    let routes: [String: PolicyCanvasEdgeRoute]
    let portMarkerLayout: PolicyCanvasPortMarkerLayout
  }

  private struct PolicyCanvasRouteStateContext {
    let prepared: PolicyCanvasPreparedRouteInput
    let nodeIndex: [String: PolicyCanvasRouteNode]
    let passContext: PolicyCanvasDisplayedRoutePassContext
    let router: any PolicyCanvasEdgeRouter
    let algorithms: PolicyCanvasRoutingAlgorithmSet
  }

  private func policyCanvasConvergedRouteState(
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let context = PolicyCanvasRouteStateContext(
      prepared: prepared,
      nodeIndex: nodeIndex,
      passContext: prepared.displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )
    let initialRoutes = algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: selectedRouter,
        portMarkerLayout: nil,
        passContext: context.passContext
      )
    )
    var state = PolicyCanvasRouteComputationState(
      routes: initialRoutes,
      portMarkerLayout: algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: prepared,
          routes: initialRoutes,
          nodeIndex: nodeIndex
        )
      )
    )
    var seenLayouts: [PolicyCanvasPortMarkerLayout] = [state.portMarkerLayout]
    for _ in 0..<3 {
      let nextState = policyCanvasNextRouteState(
        current: state,
        context: context
      )
      if nextState.portMarkerLayout == state.portMarkerLayout {
        return nextState
      }
      if seenLayouts.contains(nextState.portMarkerLayout) {
        return policyCanvasReroutedState(
          portMarkerLayout: nextState.portMarkerLayout,
          context: context
        )
      }
      seenLayouts.append(nextState.portMarkerLayout)
      state = nextState
    }
    return policyCanvasReroutedState(
      portMarkerLayout: state.portMarkerLayout,
      context: context
    )
  }

  private func policyCanvasNextRouteState(
    current: PolicyCanvasRouteComputationState,
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    let routes = context.algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: context.prepared,
        router: context.router,
        portMarkerLayout: current.portMarkerLayout,
        passContext: context.passContext
      )
    )
    return PolicyCanvasRouteComputationState(
      routes: routes,
      portMarkerLayout: context.algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: context.prepared,
          routes: routes,
          nodeIndex: context.nodeIndex
        )
      )
    )
  }

  private func policyCanvasReroutedState(
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    PolicyCanvasRouteComputationState(
      routes: context.algorithms.routeSelection.selectRoutes(
        input: PolicyCanvasRouteSelectionInput(
          prepared: context.prepared,
          router: context.router,
          portMarkerLayout: portMarkerLayout,
          passContext: context.passContext
        )
      ),
      portMarkerLayout: portMarkerLayout
    )
  }

  func routeAnchorCandidate(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminalSlot: PolicyCanvasRouteEndpointSlot,
    terminal: PolicyCanvasPortTerminal? = nil
  ) -> PolicyCanvasRouteAnchorCandidate? {
    guard
      let point = portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex),
      let node = nodeIndex[endpoint.nodeID]
    else {
      return nil
    }
    if let terminal {
      return (
        point: policyCanvasShiftedRouteAnchor(point, side: side, terminal: terminal), side: side
      )
    }
    let spacing = max(
      portSpacing(for: endpoint, side: side, nodeIndex: nodeIndex),
      policyCanvasMinimumPortMarkerSpacing()
    )
    return (
      point: policyCanvasShiftedRouteAnchor(
        point,
        side: side,
        frame: node.frame,
        spacing: spacing,
        terminalSlot: terminalSlot
      ),
      side: side
    )
  }

  func portAnchor(
    for endpoint: PolicyCanvasPortEndpoint,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGPoint? {
    portAnchor(
      for: endpoint,
      side: policyCanvasResolvedPortSide(for: endpoint),
      nodeIndex: nodeIndex
    )
  }

  func portAnchor(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGPoint? {
    guard let node = nodeIndex[endpoint.nodeID] else {
      return nil
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard let index = ports.firstIndex(where: { $0.id == endpoint.portID }) else {
      return nil
    }
    return portAnchor(for: node, side: side, index: index, count: ports.count)
  }

  func portAnchor(
    for node: PolicyCanvasRouteNode,
    side: PolicyCanvasPortSide,
    index: Int,
    count: Int
  ) -> CGPoint {
    switch side {
    case .leading:
      CGPoint(
        x: node.position.x,
        y: node.position.y + PolicyCanvasLayout.portY(index: index, count: count))
    case .trailing:
      CGPoint(
        x: node.position.x + PolicyCanvasLayout.nodeSize.width,
        y: node.position.y + PolicyCanvasLayout.portY(index: index, count: count)
      )
    case .top:
      CGPoint(
        x: node.position.x + PolicyCanvasLayout.portX(index: index, count: count),
        y: node.position.y)
    case .bottom:
      CGPoint(
        x: node.position.x + PolicyCanvasLayout.portX(index: index, count: count),
        y: node.position.y + PolicyCanvasLayout.nodeSize.height
      )
    }
  }
}

func policyCanvasRoutesPreservingRouteTerminals(
  original: [String: PolicyCanvasEdgeRoute],
  processed: [String: PolicyCanvasEdgeRoute]
) -> [String: PolicyCanvasEdgeRoute] {
  processed.reduce(into: [:]) { routes, entry in
    guard let originalRoute = original[entry.key] else {
      routes[entry.key] = entry.value
      return
    }
    routes[entry.key] = policyCanvasRoutePreservingTerminalStubs(
      original: originalRoute,
      processed: entry.value
    )
  }
}

func policyCanvasRoutePreservingTerminalStubs(
  original: PolicyCanvasEdgeRoute,
  processed: PolicyCanvasEdgeRoute
) -> PolicyCanvasEdgeRoute {
  guard original.points.count >= 2, processed.points.count >= 2 else {
    return processed
  }
  var points: [CGPoint] = []
  policyCanvasAppendOrthogonalBridge(original.points[0], to: &points)
  policyCanvasAppendOrthogonalBridge(original.points[1], to: &points)
  for point in processed.points.dropFirst().dropLast() {
    policyCanvasAppendOrthogonalBridge(point, to: &points)
  }
  policyCanvasAppendOrthogonalBridge(original.points[original.points.count - 2], to: &points)
  policyCanvasAppendOrthogonalBridge(original.points[original.points.count - 1], to: &points)
  let compressed = policyCanvasCompressPreservingTerminalStubs(points)
  return PolicyCanvasEdgeRoute(
    points: compressed,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
  )
}

private func policyCanvasAppendOrthogonalBridge(_ point: CGPoint, to points: inout [CGPoint]) {
  guard let last = points.last else {
    points.append(point)
    return
  }
  if abs(last.x - point.x) > 0.001, abs(last.y - point.y) > 0.001 {
    points.append(CGPoint(x: point.x, y: last.y))
  }
  if points.last != point {
    points.append(point)
  }
}
