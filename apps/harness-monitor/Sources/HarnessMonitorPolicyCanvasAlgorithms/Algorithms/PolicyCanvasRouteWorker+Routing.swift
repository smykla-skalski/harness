import OSLog
import SwiftUI

let policyCanvasRouteComputationSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.perf"
)
let policyCanvasSinglePassRoutingThreshold = 1_000

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

    // after the convergence interval ends
    return routeComputationTerminalPhases(
      routeState: routeState,
      nodeIndex: nodeIndex,
      selectedRouter: selectedRouter,
      algorithms: algorithms
    )
  }

  func routeComputationTerminalPhases(
    routeState: PolicyCanvasRouteComputationState,
    nodeIndex: [String: PolicyCanvasRouteNode],
    selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasPreparedRouteComputation {
    let (finalRoutes, portMarkerLayout) = routeComputationRepairedTerminals(
      routeState: routeState,
      nodeIndex: nodeIndex,
      selectedRouter: selectedRouter,
      algorithms: algorithms
    )

    let labelSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let labelInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.labels",
      id: labelSignpostID,
      "routes=\(finalRoutes.count, privacy: .public)"
    )
    let labelPositions = algorithms.labelPlacement.placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: self, routes: finalRoutes)
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
      "routes=\(finalRoutes.count, privacy: .public) labels=\(labelPositions.count, privacy: .public)"
    )
    let visibleBounds = visibleBounds(routes: finalRoutes, labelPositions: labelPositions)
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.bounds",
      boundsInterval,
      "width=\(visibleBounds.width, privacy: .public) height=\(visibleBounds.height, privacy: .public)"
    )
    return PolicyCanvasPreparedRouteComputation(
      routes: finalRoutes,
      labelPositions: labelPositions,
      portVisibility: portVisibility(routes: finalRoutes, nodeIndex: nodeIndex),
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds
    )
  }

  private func routeComputationRepairedTerminals(
    routeState: PolicyCanvasRouteComputationState,
    nodeIndex: [String: PolicyCanvasRouteNode],
    selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> ([String: PolicyCanvasEdgeRoute], PolicyCanvasPortMarkerLayout) {
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
    let terminalOrderedRoutes = routesRepairingFinalTerminalOrder(
      routes: routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let finalRoutes = routesClearingCorridorsAndRestoringTerminalLeads(
      routes: terminalOrderedRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let portMarkerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: finalRoutes,
      nodeIndex: nodeIndex,
      usesDeclarationOrderAnchor: true
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.terminals",
      terminalsInterval,
      "routes=\(finalRoutes.count, privacy: .public)"
    )
    return (finalRoutes, portMarkerLayout)
  }

  func precomputedRouteComputation(
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
    let terminalSafeRoutes = precomputedRoutesNormalizingTerminalStubs(
      routes: bodySafeRoutes,
      nodeIndex: nodeIndex
    )
    let repairedRoutes = routesRepairingCrossedPorts(
      routes: terminalSafeRoutes,
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
    let crossedPortRoutes = routesRepairingFinalTerminalOrder(
      routes: routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms,
      portMarkerLayout: portMarkerLayout
    )
    let finalRoutes = routesClearingCorridorsAndRestoringTerminalLeads(
      routes: crossedPortRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let finalPortMarkerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: finalRoutes,
      nodeIndex: nodeIndex,
      usesDeclarationOrderAnchor: true
    )
    let labelPositions = PolicyCanvasPolylineMidpointLabelPlacement().placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: self, routes: finalRoutes)
    )
    return PolicyCanvasPreparedRouteComputation(
      routes: finalRoutes,
      labelPositions: labelPositions,
      portVisibility: portVisibility(routes: finalRoutes, nodeIndex: nodeIndex),
      portMarkerLayout: finalPortMarkerLayout,
      visibleBounds: visibleBounds(routes: finalRoutes, labelPositions: labelPositions)
    )
  }

  func routesRepairingFinalTerminalOrder(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet,
    portMarkerLayout: PolicyCanvasPortMarkerLayout? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let terminalSafeRoutes = precomputedRoutesNormalizingTerminalStubs(
      routes: routes,
      nodeIndex: nodeIndex,
      portMarkerLayout: portMarkerLayout
    )
    return routesRepairingCrossedPortOrder(
      routes: terminalSafeRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
  }

  func precomputedRoutesRepairingBodyHits(
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

func policyCanvasAppendOrthogonalBridge(_ point: CGPoint, to points: inout [CGPoint]) {
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
