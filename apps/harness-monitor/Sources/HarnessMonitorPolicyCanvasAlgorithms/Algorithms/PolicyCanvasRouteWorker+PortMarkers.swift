import OSLog
import SwiftUI

struct PolicyCanvasPrecomputedTerminalRecord {
  let edgeID: String
  let role: PolicyCanvasRouteEndpointRole
  let endpoint: PolicyCanvasPortEndpoint
  let point: CGPoint?
  let side: PolicyCanvasPortSide?
}

extension PolicyCanvasPreparedRouteInput {
  func routesReroutingBalancedPortMarkers(
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

  func routesBalancingPrecomputedPortMarkers(
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

  func precomputedRoutesHavePortSpacingViolations(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Bool {
    !policyCanvasMeasurePortSpacing(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      thresholds: .default
    ).isEmpty
  }

  func routesSnappingTerminals(
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

  func portMarkerPoint(
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

  /// Build the port-marker layout for a set of precomputed routes.
  ///
  /// `usesDeclarationOrderAnchor` selects which port anchor the axis offset is
  /// measured against. Internal route-repair passes keep the default optimized
  /// anchor so the crossing-minimal port order the router fans wires through is
  /// preserved. The single layout that the canvas renders (and the detachment
  /// detector reads) passes `true`: the canvas draws each port dot at its
  /// declaration-order anchor, so the offset must be measured from there or the
  /// dot floats off its wire end.
  func precomputedRouteTerminalPortMarkerLayout(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    usesDeclarationOrderAnchor: Bool = false
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
        PolicyCanvasPrecomputedTerminalRecord(
          edgeID: edge.id,
          role: .source,
          endpoint: edge.source,
          point: route.points.first,
          side: policyCanvasRouteSourceSide(route)
        ),
        nodeIndex: nodeIndex,
        usesDeclarationOrderAnchor: usesDeclarationOrderAnchor,
        terminals: &terminals,
        endpoints: &endpoints
      )
      precomputedRouteTerminal(
        PolicyCanvasPrecomputedTerminalRecord(
          edgeID: edge.id,
          role: .target,
          endpoint: edge.target,
          point: route.points.last,
          side: policyCanvasRouteTargetSide(route)
        ),
        nodeIndex: nodeIndex,
        usesDeclarationOrderAnchor: usesDeclarationOrderAnchor,
        terminals: &terminals,
        endpoints: &endpoints
      )
    }
    return PolicyCanvasPortMarkerLayout(terminalsByKey: terminals, endpointsByKey: endpoints)
  }

  func precomputedRouteTerminal(
    _ record: PolicyCanvasPrecomputedTerminalRecord,
    nodeIndex: [String: PolicyCanvasRouteNode],
    usesDeclarationOrderAnchor: Bool,
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal],
    endpoints: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint]
  ) {
    let side = policyCanvasResolvedRoutablePortSide(
      for: record.endpoint,
      preferredSide: record.side
    )
    let anchor =
      usesDeclarationOrderAnchor
      ? declarationPortAnchor(for: record.endpoint, side: side, nodeIndex: nodeIndex)
      : portAnchor(for: record.endpoint, side: side, nodeIndex: nodeIndex)
    guard
      let point = record.point,
      let base = anchor
    else {
      return
    }
    let key = PolicyCanvasRouteTerminalKey(edgeID: record.edgeID, role: record.role)
    terminals[key] = PolicyCanvasPortTerminal(
      side: side,
      axisOffset: precomputedRouteTerminalAxisOffset(from: base, to: point, side: side)
    )
    endpoints[key] = record.endpoint
  }

  func precomputedRouteTerminalAxisOffset(
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
}
