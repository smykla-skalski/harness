import OSLog
import SwiftUI

private let policyCanvasRouteComputationSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.perf"
)

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
    let convergenceSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let convergenceInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.converge",
      id: convergenceSignpostID,
      "nodes=\(nodes.count, privacy: .public) edges=\(edges.count, privacy: .public)"
    )
    let routeState = policyCanvasConvergedRouteState(
      prepared: self,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.converge",
      convergenceInterval,
      "routes=\(routeState.routes.count, privacy: .public)"
    )

    let postProcessSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let postProcessInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.post_process",
      id: postProcessSignpostID,
      "routes=\(routeState.routes.count, privacy: .public)"
    )
    let processedRoutes = algorithms.routePostProcessing.processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: self, routes: routeState.routes)
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.post_process",
      postProcessInterval,
      "routes=\(processedRoutes.count, privacy: .public)"
    )

    let terminalsSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let terminalsInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.terminals",
      id: terminalsSignpostID,
      "routes=\(processedRoutes.count, privacy: .public)"
    )
    let routes = policyCanvasRoutesPreservingRouteTerminals(
      original: routeState.routes,
      processed: processedRoutes
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.terminals",
      terminalsInterval,
      "routes=\(routes.count, privacy: .public)"
    )

    let labelSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let labelInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.labels",
      id: labelSignpostID,
      "routes=\(routes.count, privacy: .public)"
    )
    let labelPositions = algorithms.labelPlacement.placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: self, routes: routes)
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.labels",
      labelInterval,
      "labels=\(labelPositions.count, privacy: .public)"
    )

    let boundsSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let boundsInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.bounds",
      id: boundsSignpostID,
      "routes=\(routes.count, privacy: .public) labels=\(labelPositions.count, privacy: .public)"
    )
    let visibleBounds = visibleBounds(routes: routes, labelPositions: labelPositions)
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.bounds",
      boundsInterval,
      "width=\(visibleBounds.width, privacy: .public) height=\(visibleBounds.height, privacy: .public)"
    )
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
    if let seedLayout = algorithms.portMarkerPlacement.seedMarkers(
      input: PolicyCanvasPortMarkerSeedInput(prepared: prepared, nodeIndex: nodeIndex)
    ) {
      let state = policyCanvasNextRouteState(
        current: PolicyCanvasRouteComputationState(routes: [:], portMarkerLayout: seedLayout),
        context: context
      )
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

  private func policyCanvasConvergedRouteState(
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

  private func policyCanvasInitialRouteState(
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

  private func policyCanvasNextRouteState(
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

  private func policyCanvasReroutedState(
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

  private func policyCanvasSelectedRoutes(
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
