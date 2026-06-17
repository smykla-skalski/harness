import OSLog
import SwiftUI

private let policyCanvasRouteComputationSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.perf"
)
private let policyCanvasSinglePassSeededRoutingThreshold = 1_000

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
    let nodeIndex = nodeIndex
    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: algorithmSelection)
    let selectedRouter: any PolicyCanvasEdgeRouter =
      algorithmSelection.algorithmID(for: .edgeRouting)
        == PolicyCanvasAlgorithmDefaults.paddedOrthogonalVisibilityAStar
      ? defaultRouter
      : algorithms.edgeRouter
    if let precomputed = precomputedRouteComputation(
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    ) {
      return precomputed
    }
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
    let terminalRoutes = policyCanvasRoutesPreservingRouteTerminals(
      original: routeState.routes,
      processed: processedRoutes
    )
    let repairedRoutes = routesRepairingCrossedPorts(
      routes: terminalRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let terminalState =
      repairedRoutes == terminalRoutes
      ? PolicyCanvasRouteComputationState(
        routes: terminalRoutes,
        portMarkerLayout: routeState.portMarkerLayout
      )
      : routesReroutingBalancedPortMarkers(
        routes: repairedRoutes,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
    let routes = routesClearingCorridorReuse(
      routes: terminalState.routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let portMarkerLayout = terminalState.portMarkerLayout
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
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds
    )
  }

  private func precomputedRouteComputation(
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasPreparedRouteComputation? {
    guard let precomputedRoutes else {
      return nil
    }
    let edgeIDs = Set(edges.map(\.id))
    guard precomputedRoutes.routes.count == edgeIDs.count,
      Set(precomputedRoutes.routes.keys) == edgeIDs
    else {
      return nil
    }
    let bodySafeRoutes = precomputedRoutesRepairingBodyHits(
      routes: precomputedRoutes.routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let repairedRoutes = routesRepairingCrossedPorts(
      routes: bodySafeRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let terminalState = routesBalancingPrecomputedPortMarkers(
      routes: repairedRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let routes = routesClearingCorridorReuse(
      routes: terminalState.routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let portMarkerLayout = terminalState.portMarkerLayout
    let labelPositions = PolicyCanvasPolylineMidpointLabelPlacement().placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: self, routes: routes)
    )
    return PolicyCanvasPreparedRouteComputation(
      routes: routes,
      labelPositions: labelPositions,
      portVisibility: portVisibility(routes: routes, nodeIndex: nodeIndex),
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds(routes: routes, labelPositions: labelPositions)
    )
  }

  private func precomputedRoutesRepairingBodyHits(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    let hitEdgeIDs = precomputedBodyHitEdgeIDs(routes: routes, nodeIndex: nodeIndex)
    guard !hitEdgeIDs.isEmpty else {
      return routes
    }
    let precomputedMarkerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex
    )
    let context = PolicyCanvasRouteStateContext(
      prepared: self,
      nodeIndex: nodeIndex,
      passContext: displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )
    let selectedRoutes = policyCanvasSelectedRoutes(
      phase: "precomputed-repair",
      portMarkerLayout: precomputedMarkerLayout,
      context: context
    )
    var repaired = routes
    for edge in edges where hitEdgeIDs.contains(edge.id) {
      guard let route = selectedRoutes[edge.id],
        precomputedBodyHits(edge: edge, route: route, nodeIndex: nodeIndex).isEmpty
      else {
        continue
      }
      repaired[edge.id] = route
    }
    return repaired
  }

  private func routesClearingCorridorReuse(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    let splitter = PolicyCanvasOrthogonalNudgingRouteProcessing()
    let obstacles = routingObstacles()
    let originalBodyHits = precomputedBodyHits(routes: routes, nodeIndex: nodeIndex).count
    let edgesByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    let acceptsBodySafeSplit:
      (String, PolicyCanvasEdgeRoute, PolicyCanvasEdgeRoute) -> Bool = {
        edgeID, oldRoute, newRoute in
        guard let edge = edgesByID[edgeID] else {
          return true
        }
        let oldHitCount = precomputedBodyHits(
          edge: edge, route: oldRoute, nodeIndex: nodeIndex
        ).count
        let newHitCount = precomputedBodyHits(
          edge: edge, route: newRoute, nodeIndex: nodeIndex
        ).count
        return newHitCount <= oldHitCount
      }
    var current = routes
    var best = routes
    for _ in 0..<3 {
      let split = splitter.routesClearingRemainingCollinearReuse(
        current,
        obstacles: obstacles,
        accepts: acceptsBodySafeSplit
      )
      if precomputedBodyHits(routes: split, nodeIndex: nodeIndex).count <= originalBodyHits {
        best = split
        guard split != current else {
          break
        }
        current = split
        continue
      }
      let repaired = precomputedRoutesRepairingBodyHits(
        routes: split,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
      guard precomputedBodyHits(routes: repaired, nodeIndex: nodeIndex).count <= originalBodyHits,
        repaired != current
      else {
        break
      }
      best = repaired
      current = repaired
    }
    let pairSplit = splitter.routesClearingRemainingParallelPairs(
      best,
      obstacles: obstacles,
      accepts: acceptsBodySafeSplit
    )
    guard precomputedBodyHits(routes: pairSplit, nodeIndex: nodeIndex).count <= originalBodyHits
    else {
      return best
    }
    return pairSplit
  }

  private func routesRepairingCrossedPorts(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    var currentRoutes = routes
    var currentViolations = precomputedCrossedPortViolations(
      routes: currentRoutes,
      nodeIndex: nodeIndex
    )
    for _ in 0..<6 {
      guard !currentViolations.isEmpty else {
        return currentRoutes
      }
      let untangled = routesSwappingCrossedPortPairs(
        routes: currentRoutes,
        violations: currentViolations
      )
      let untangledViolations = precomputedCrossedPortViolations(
        routes: untangled,
        nodeIndex: nodeIndex
      )
      guard precomputedBodyHits(routes: untangled, nodeIndex: nodeIndex).isEmpty,
        untangledViolations.count < currentViolations.count
      else {
        break
      }
      currentRoutes = untangled
      currentViolations = untangledViolations
    }
    for _ in 0..<3 {
      guard !currentViolations.isEmpty else {
        return currentRoutes
      }
      let repaired = routesRepairingCrossedPorts(
        routes: currentRoutes,
        violations: currentViolations,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
      let repairedViolations = precomputedCrossedPortViolations(
        routes: repaired,
        nodeIndex: nodeIndex
      )
      guard repairedViolations.count < currentViolations.count else {
        break
      }
      currentRoutes = repaired
      currentViolations = repairedViolations
    }
    return currentRoutes
  }

  private func routesRepairingCrossedPorts(
    routes: [String: PolicyCanvasEdgeRoute],
    violations originalViolations: [PolicyCanvasCrossedPortsViolation],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    let markerLayout = portMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex,
      ordering: .farAxis
    )
    let context = PolicyCanvasRouteStateContext(
      prepared: self,
      nodeIndex: nodeIndex,
      passContext: displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )
    let selectedRoutes = policyCanvasSelectedRoutes(
      phase: "precomputed-crossed-port-repair",
      portMarkerLayout: markerLayout,
      context: context
    )
    let crossedEdgeIDs = Set(originalViolations.flatMap { [$0.edgeA, $0.edgeB] })
    var repaired = routes
    for edge in edges where crossedEdgeIDs.contains(edge.id) {
      guard let route = selectedRoutes[edge.id] else {
        continue
      }
      repaired[edge.id] = route
    }
    guard precomputedBodyHits(routes: repaired, nodeIndex: nodeIndex).isEmpty else {
      return routes
    }
    return repaired
  }

  private func precomputedBodyHitEdgeIDs(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Set<String> {
    Set(
      precomputedBodyHits(routes: routes, nodeIndex: nodeIndex)
        .map(\.edgeID)
    )
  }

  private func precomputedBodyHits(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasBodyHitViolation] {
    return policyCanvasMeasureBodyHits(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      groupTitleFrames: policyCanvasGroupTitleFramesByID(groups)
    )
  }

  private func precomputedBodyHits(
    edge: PolicyCanvasEdge,
    route: PolicyCanvasEdgeRoute,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasBodyHitViolation] {
    policyCanvasMeasureBodyHits(
      routedEdges: [PolicyCanvasRoutedEdge(edge: edge, route: route)],
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      groupTitleFrames: policyCanvasGroupTitleFramesByID(groups)
    )
  }

  private func precomputedCrossedPortViolations(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasCrossedPortsViolation] {
    policyCanvasMeasureCrossedPorts(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame)
    )
  }

  private func precomputedRoutedEdges(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [PolicyCanvasRoutedEdge] {
    edges.compactMap { edge -> PolicyCanvasRoutedEdge? in
      guard let route = routes[edge.id], route.points.count >= 2 else {
        return nil
      }
      return PolicyCanvasRoutedEdge(edge: edge, route: route)
    }
  }

  private func routesSwappingCrossedPortPairs(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation]
  ) -> [String: PolicyCanvasEdgeRoute] {
    let edgesByID = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var repaired = routes
    for violation in violations {
      guard
        let edgeA = edgesByID[violation.edgeA],
        let edgeB = edgesByID[violation.edgeB],
        let roleA = crossedPortRole(edge: edgeA, nodeID: violation.nodeID),
        let roleB = crossedPortRole(edge: edgeB, nodeID: violation.nodeID),
        let routeA = repaired[violation.edgeA],
        let routeB = repaired[violation.edgeB]
      else {
        continue
      }
      repaired[violation.edgeA] = routeMovingTerminal(
        routeA,
        role: roleA,
        side: violation.side,
        point: violation.pointB
      )
      repaired[violation.edgeB] = routeMovingTerminal(
        routeB,
        role: roleB,
        side: violation.side,
        point: violation.pointA
      )
    }
    return repaired
  }

  private func crossedPortRole(
    edge: PolicyCanvasEdge,
    nodeID: String
  ) -> PolicyCanvasRouteEndpointRole? {
    if edge.source.nodeID == nodeID {
      return .source
    }
    if edge.target.nodeID == nodeID {
      return .target
    }
    return nil
  }

  private func routeMovingTerminal(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    point: CGPoint
  ) -> PolicyCanvasEdgeRoute {
    guard route.points.count >= 2 else {
      return route
    }
    let lead = policyCanvasPortLeadPoint(point, side: side)
    var points: [CGPoint] = []
    switch role {
    case .source:
      policyCanvasAppendOrthogonalBridge(point, to: &points)
      policyCanvasAppendOrthogonalBridge(lead, to: &points)
      for oldPoint in route.points.dropFirst(2) {
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
    case .target:
      for oldPoint in route.points.dropLast(2) {
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
      policyCanvasAppendOrthogonalBridge(lead, to: &points)
      policyCanvasAppendOrthogonalBridge(point, to: &points)
    }
    let compressed = policyCanvasCompressPreservingTerminalStubs(points)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  private func routesReroutingBalancedPortMarkers(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let portMarkerLayout = portMarkerLayout(routes: routes, nodeIndex: nodeIndex)
    let context = PolicyCanvasRouteStateContext(
      prepared: self,
      nodeIndex: nodeIndex,
      passContext: displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )
    return policyCanvasReroutedState(portMarkerLayout: portMarkerLayout, context: context)
  }

  private func routesBalancingPrecomputedPortMarkers(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let precomputedLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex
    )
    guard precomputedRoutesHavePortSpacingViolations(routes: routes, nodeIndex: nodeIndex) else {
      return PolicyCanvasRouteComputationState(routes: routes, portMarkerLayout: precomputedLayout)
    }
    let balancedLayout = portMarkerLayout(routes: routes, nodeIndex: nodeIndex)
    let snappedRoutes = routesSnappingTerminals(
      routes: routes,
      portMarkerLayout: balancedLayout,
      nodeIndex: nodeIndex
    )
    guard precomputedBodyHits(routes: snappedRoutes, nodeIndex: nodeIndex).isEmpty else {
      return routesReroutingBalancedPortMarkers(
        routes: routes,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
    }
    return PolicyCanvasRouteComputationState(
      routes: snappedRoutes, portMarkerLayout: balancedLayout)
  }

  private func precomputedRoutesHavePortSpacingViolations(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Bool {
    !policyCanvasMeasurePortSpacing(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      thresholds: .default
    ).isEmpty
  }

  private func routesSnappingTerminals(
    routes: [String: PolicyCanvasEdgeRoute],
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [String: PolicyCanvasEdgeRoute] {
    var snapped = routes
    for edge in edges {
      guard var route = snapped[edge.id] else {
        continue
      }
      if let sourcePoint = portMarkerPoint(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        portMarkerLayout: portMarkerLayout,
        nodeIndex: nodeIndex
      ) {
        route = routeMovingTerminal(
          route,
          role: .source,
          side: sourcePoint.side,
          point: sourcePoint.point
        )
      }
      if let targetPoint = portMarkerPoint(
        edgeID: edge.id,
        role: .target,
        endpoint: edge.target,
        portMarkerLayout: portMarkerLayout,
        nodeIndex: nodeIndex
      ) {
        route = routeMovingTerminal(
          route,
          role: .target,
          side: targetPoint.side,
          point: targetPoint.point
        )
      }
      snapped[edge.id] = route
    }
    return snapped
  }

  private func portMarkerPoint(
    edgeID: String,
    role: PolicyCanvasRouteEndpointRole,
    endpoint: PolicyCanvasPortEndpoint,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> (point: CGPoint, side: PolicyCanvasPortSide)? {
    guard
      let terminal = portMarkerLayout.terminal(edgeID: edgeID, role: role),
      let base = portAnchor(for: endpoint, side: terminal.side, nodeIndex: nodeIndex)
    else {
      return nil
    }
    return (
      policyCanvasShiftedRouteAnchor(base, side: terminal.side, terminal: terminal),
      terminal.side
    )
  }

  private func precomputedRouteTerminalPortMarkerLayout(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortMarkerLayout {
    var terminals: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal] = [:]
    var endpoints: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint] = [:]
    terminals.reserveCapacity(routes.count * 2)
    endpoints.reserveCapacity(routes.count * 2)
    for edge in edges {
      guard let route = routes[edge.id] else {
        continue
      }
      precomputedRouteTerminal(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        point: route.points.first,
        side: policyCanvasRouteSourceSide(route),
        nodeIndex: nodeIndex,
        terminals: &terminals,
        endpoints: &endpoints
      )
      precomputedRouteTerminal(
        edgeID: edge.id,
        role: .target,
        endpoint: edge.target,
        point: route.points.last,
        side: policyCanvasRouteTargetSide(route),
        nodeIndex: nodeIndex,
        terminals: &terminals,
        endpoints: &endpoints
      )
    }
    return PolicyCanvasPortMarkerLayout(terminalsByKey: terminals, endpointsByKey: endpoints)
  }

  private func precomputedRouteTerminal(
    edgeID: String,
    role: PolicyCanvasRouteEndpointRole,
    endpoint: PolicyCanvasPortEndpoint,
    point: CGPoint?,
    side: PolicyCanvasPortSide?,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal],
    endpoints: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint]
  ) {
    let side = policyCanvasResolvedRoutablePortSide(for: endpoint, preferredSide: side)
    guard
      let point,
      let base = portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex)
    else {
      return
    }
    let key = PolicyCanvasRouteTerminalKey(edgeID: edgeID, role: role)
    terminals[key] = PolicyCanvasPortTerminal(
      side: side,
      axisOffset: precomputedRouteTerminalAxisOffset(from: base, to: point, side: side)
    )
    endpoints[key] = endpoint
  }

  private func precomputedRouteTerminalAxisOffset(
    from base: CGPoint,
    to point: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .trailing:
      point.y - base.y
    case .top, .bottom:
      point.x - base.x
    }
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
      if prepared.edges.count > policyCanvasSinglePassSeededRoutingThreshold {
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
