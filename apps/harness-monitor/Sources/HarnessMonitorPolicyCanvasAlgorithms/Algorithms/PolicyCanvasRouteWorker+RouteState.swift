import OSLog
import SwiftUI

struct PolicyCanvasRouteComputationState {
  let routes: [String: PolicyCanvasEdgeRoute]
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
}

struct PolicyCanvasRouteStateContext {
  let prepared: PolicyCanvasPreparedRouteInput
  let nodeIndex: [String: PolicyCanvasRouteNode]
  let passContext: PolicyCanvasDisplayedRoutePassContext
  let router: any PolicyCanvasEdgeRouter
  let algorithms: PolicyCanvasRoutingAlgorithmSet
}

extension PolicyCanvasPreparedRouteInput {
  func portVisibility(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortVisibilityMap {
    policyCanvasPortVisibility(edges: edges, routes: routes) { endpoint in
      routeAnchorCandidates(for: endpoint, nodeIndex: nodeIndex)
    }
  }

  func routingObstacles() -> [CGRect] {
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

  func routeAnchorCandidates(
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

  func policyCanvasConvergedRouteState(
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
    if let seedLayout = algorithms.portMarkerPlacement.seedMarkers(
      input: PolicyCanvasPortMarkerSeedInput(prepared: prepared, nodeIndex: nodeIndex)
    ) {
      let state = policyCanvasNextRouteState(
        current: PolicyCanvasRouteComputationState(routes: [:], portMarkerLayout: seedLayout),
        context: context
      )
      if prepared.edges.count > policyCanvasSinglePassRoutingThreshold {
        return PolicyCanvasRouteComputationState(
          routes: state.routes,
          portMarkerLayout: seedLayout
        )
      }
      if state.portMarkerLayout == seedLayout {
        return state
      }
      let seenLayouts = [seedLayout, state.portMarkerLayout]
      return policyCanvasConvergedRouteState(
        state: state,
        seenLayouts: seenLayouts,
        context: context
      )
    }
    let state = policyCanvasInitialRouteState(context: context)
    return policyCanvasConvergedRouteState(
      state: state,
      seenLayouts: [state.portMarkerLayout],
      context: context
    )
  }

  func policyCanvasConvergedRouteState(
    state initialState: PolicyCanvasRouteComputationState,
    seenLayouts initialSeenLayouts: [PolicyCanvasPortMarkerLayout],
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    var state = initialState
    var seenLayouts = initialSeenLayouts
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

  func policyCanvasInitialRouteState(
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    let initialRoutes = policyCanvasSelectedRoutes(
      phase: "initial",
      portMarkerLayout: nil,
      context: context
    )
    return PolicyCanvasRouteComputationState(
      routes: initialRoutes,
      portMarkerLayout: context.algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: context.prepared,
          routes: initialRoutes,
          nodeIndex: context.nodeIndex
        )
      )
    )
  }

  func policyCanvasNextRouteState(
    current: PolicyCanvasRouteComputationState,
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    let routes = policyCanvasSelectedRoutes(
      phase: "next",
      portMarkerLayout: current.portMarkerLayout,
      context: context
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

  func policyCanvasReroutedState(
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    PolicyCanvasRouteComputationState(
      routes: policyCanvasSelectedRoutes(
        phase: "reroute",
        portMarkerLayout: portMarkerLayout,
        context: context
      ),
      portMarkerLayout: portMarkerLayout
    )
  }

  func policyCanvasSelectedRoutes(
    phase: String,
    portMarkerLayout: PolicyCanvasPortMarkerLayout?,
    context: PolicyCanvasRouteStateContext
  ) -> [String: PolicyCanvasEdgeRoute] {
    let signpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let markerState = portMarkerLayout == nil ? "none" : "layout"
    let interval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.route_selection",
      id: signpostID,
      "phase=\(phase, privacy: .public) markers=\(markerState, privacy: .public)"
    )
    let routes = context.algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: context.prepared,
        router: context.router,
        portMarkerLayout: portMarkerLayout,
        passContext: context.passContext
      )
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.route_selection",
      interval,
      "phase=\(phase, privacy: .public) routes=\(routes.count, privacy: .public)"
    )
    return routes
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
        y: node.position.y
          + PolicyCanvasLayout.portY(
            index: index,
            count: count,
            nodeHeight: node.size.height
          )
      )
    case .trailing:
      CGPoint(
        x: node.position.x + node.size.width,
        y: node.position.y
          + PolicyCanvasLayout.portY(
            index: index,
            count: count,
            nodeHeight: node.size.height
          )
      )
    case .top:
      CGPoint(
        x: node.position.x
          + PolicyCanvasLayout.portX(
            index: index,
            count: count,
            nodeWidth: node.size.width
          ),
        y: node.position.y)
    case .bottom:
      CGPoint(
        x: node.position.x
          + PolicyCanvasLayout.portX(
            index: index,
            count: count,
            nodeWidth: node.size.width
          ),
        y: node.position.y + node.size.height
      )
    }
  }

  /// The port anchor at the endpoint's declaration-order index rather than the
  /// routing pass's optimized index. The canvas and the detachment detector both
  /// draw the port dot at this position, so terminal marker offsets must be
  /// measured from here for the wire end to land on the dot. Falls back to the
  /// optimized anchor if the endpoint has no recorded declaration index.
  func declarationPortAnchor(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGPoint? {
    guard let node = nodeIndex[endpoint.nodeID] else {
      return nil
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    let key = PolicyCanvasPortEndpoint(
      nodeID: endpoint.nodeID,
      portID: endpoint.portID,
      kind: endpoint.kind
    )
    guard let index = declarationPortIndices[key] else {
      return portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex)
    }
    return portAnchor(for: node, side: side, index: index, count: ports.count)
  }
}
