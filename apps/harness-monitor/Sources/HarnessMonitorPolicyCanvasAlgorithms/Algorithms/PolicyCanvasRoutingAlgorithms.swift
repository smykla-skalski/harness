import CoreGraphics
import Foundation

struct PolicyCanvasPortMarkerPlacementInput: Sendable {
  let prepared: PolicyCanvasPreparedRouteInput
  let routes: [String: PolicyCanvasEdgeRoute]
  let nodeIndex: [String: PolicyCanvasRouteNode]
}

struct PolicyCanvasRouteSelectionInput: Sendable {
  let prepared: PolicyCanvasPreparedRouteInput
  let router: any PolicyCanvasEdgeRouter
  let portMarkerLayout: PolicyCanvasPortMarkerLayout?
  let passContext: PolicyCanvasDisplayedRoutePassContext?
}

struct PolicyCanvasRoutePostProcessingInput: Sendable {
  let prepared: PolicyCanvasPreparedRouteInput
  let routes: [String: PolicyCanvasEdgeRoute]
}

struct PolicyCanvasLabelPlacementInput: Sendable {
  let prepared: PolicyCanvasPreparedRouteInput
  let routes: [String: PolicyCanvasEdgeRoute]
}

protocol PolicyCanvasPortMarkerPlacementAlgorithm: Sendable {
  func placeMarkers(input: PolicyCanvasPortMarkerPlacementInput) -> PolicyCanvasPortMarkerLayout
}

protocol PolicyCanvasRouteSelectionAlgorithm: Sendable {
  func selectRoutes(input: PolicyCanvasRouteSelectionInput) -> [String: PolicyCanvasEdgeRoute]
}

protocol PolicyCanvasRoutePostProcessingAlgorithm: Sendable {
  func processRoutes(input: PolicyCanvasRoutePostProcessingInput) -> [String: PolicyCanvasEdgeRoute]
}

protocol PolicyCanvasEdgeLabelPlacementAlgorithm: Sendable {
  func placeLabels(input: PolicyCanvasLabelPlacementInput) -> [String: CGPoint]
}

struct PolicyCanvasCollisionDerivedPortMarkerPlacement: PolicyCanvasPortMarkerPlacementAlgorithm {
  func placeMarkers(input: PolicyCanvasPortMarkerPlacementInput) -> PolicyCanvasPortMarkerLayout {
    input.prepared.portMarkerLayout(routes: input.routes, nodeIndex: input.nodeIndex)
  }
}

struct PolicyCanvasNoOpPortMarkerPlacement: PolicyCanvasPortMarkerPlacementAlgorithm {
  func placeMarkers(input: PolicyCanvasPortMarkerPlacementInput) -> PolicyCanvasPortMarkerLayout {
    .empty
  }
}

/// Reference-form port markers: draw one dot wherever an edge's finished route
/// actually attaches to a node. The first-feasible selector routes from the raw
/// port anchors and never consults a marker comb, so the only way every wire ends
/// on a visible dot is to read each route's terminal point and place a marker
/// there, on the side the route truly departs or arrives - which differs from the
/// port's natural side whenever the router turns vertically right at the node.
/// Unlike the collision-derived comb this never moves a dot away from its wire, so
/// the terminal-on-dot contract holds by construction.
struct PolicyCanvasRouteTerminalPortMarkerPlacement: PolicyCanvasPortMarkerPlacementAlgorithm {
  func placeMarkers(input: PolicyCanvasPortMarkerPlacementInput) -> PolicyCanvasPortMarkerLayout {
    let prepared = input.prepared
    let nodeIndex = input.nodeIndex
    var terminals: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal] = [:]
    var endpoints: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint] = [:]
    for edge in prepared.edges {
      guard let route = input.routes[edge.id] else {
        continue
      }
      addTerminal(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        point: route.points.first,
        side: policyCanvasRouteSourceSide(route),
        prepared: prepared,
        nodeIndex: nodeIndex,
        terminals: &terminals,
        endpoints: &endpoints
      )
      addTerminal(
        edgeID: edge.id,
        role: .target,
        endpoint: edge.target,
        point: route.points.last,
        side: policyCanvasRouteTargetSide(route),
        prepared: prepared,
        nodeIndex: nodeIndex,
        terminals: &terminals,
        endpoints: &endpoints
      )
    }
    return PolicyCanvasPortMarkerLayout(terminalsByKey: terminals, endpointsByKey: endpoints)
  }

  private func addTerminal(
    edgeID: String,
    role: PolicyCanvasRouteEndpointRole,
    endpoint: PolicyCanvasPortEndpoint,
    point: CGPoint?,
    side: PolicyCanvasPortSide?,
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal],
    endpoints: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint]
  ) {
    guard
      let point,
      let side,
      let base = prepared.portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex)
    else {
      return
    }
    // The marker offset is the route terminal's distance from the port's anchor
    // along the side axis - y for leading/trailing, x for top/bottom - the exact
    // inverse of `policyCanvasShiftedRouteAnchor`, so the rendered dot sits back
    // on the terminal.
    let axisOffset: CGFloat
    switch side {
    case .leading, .trailing:
      axisOffset = point.y - base.y
    case .top, .bottom:
      axisOffset = point.x - base.x
    }
    let key = PolicyCanvasRouteTerminalKey(edgeID: edgeID, role: role)
    terminals[key] = PolicyCanvasPortTerminal(side: side, axisOffset: axisOffset)
    endpoints[key] = endpoint
  }
}

struct PolicyCanvasClearanceScoredRouteSelection: PolicyCanvasRouteSelectionAlgorithm {
  func selectRoutes(input: PolicyCanvasRouteSelectionInput) -> [String: PolicyCanvasEdgeRoute] {
    if let passContext = input.passContext {
      input.prepared.displayedRoutes(
        passContext: passContext,
        router: input.router,
        portMarkerLayout: input.portMarkerLayout
      )
    } else {
      input.prepared.displayedRoutes(
        router: input.router,
        portMarkerLayout: input.portMarkerLayout
      )
    }
  }
}

struct PolicyCanvasFirstFeasibleRouteSelection: PolicyCanvasRouteSelectionAlgorithm {
  func selectRoutes(input: PolicyCanvasRouteSelectionInput) -> [String: PolicyCanvasEdgeRoute] {
    let prepared = input.prepared
    let nodeIndex = input.passContext?.nodeIndex ?? prepared.nodeIndex
    let portAnchors = input.passContext?.portAnchors ?? prepared.portAnchors(nodeIndex: nodeIndex)
    let obstacles =
      input.passContext?.obstacles
      ?? policyCanvasCanonicalObstacles(
        prepared.nodes.map(\.frame) + policyCanvasGroupTitleFrames(prepared.groups)
      )
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    routes.reserveCapacity(prepared.edges.count)
    for edge in prepared.edges {
      guard let source = portAnchors[edge.source], let target = portAnchors[edge.target] else {
        continue
      }
      let sourceNode = nodeIndex[edge.source.nodeID]
      let targetNode = nodeIndex[edge.target.nodeID]
      let context = PolicyCanvasRouteContext(
        lane: 0,
        groups: prepared.groups,
        sourceGroupID: sourceNode?.groupID,
        targetGroupID: targetNode?.groupID,
        obstacles: obstacles,
        obstaclesAreCanonical: true,
        sourceActual: source,
        targetActual: target
      )
      routes[edge.id] = input.router.route(source: source, target: target, context: context)
    }
    return routes
  }
}

struct PolicyCanvasVerticalDeclutterFanInNesting:
  PolicyCanvasRoutePostProcessingAlgorithm
{
  func processRoutes(
    input: PolicyCanvasRoutePostProcessingInput
  ) -> [String: PolicyCanvasEdgeRoute] {
    let prepared = input.prepared
    let nodeIndex = prepared.nodeIndex
    let orderedEdges = policyCanvasRouteBuildOrder(
      edges: prepared.edges,
      portAnchors: prepared.portAnchors(nodeIndex: nodeIndex)
    )
    let decluttered = policyCanvasVerticalDescentDeclutteredRoutes(
      input.routes,
      edges: orderedEdges,
      nodeFrames: prepared.nodes.map(\.frame)
    )
    return policyCanvasNestedFanInRoutes(decluttered, edges: orderedEdges, prepared: prepared)
  }
}

struct PolicyCanvasCollinearRouteCompression: PolicyCanvasRoutePostProcessingAlgorithm {
  func processRoutes(
    input: PolicyCanvasRoutePostProcessingInput
  ) -> [String: PolicyCanvasEdgeRoute] {
    input.routes.mapValues { route in
      let points = PolicyCanvasVisibilityRouter.compressCollinear(route.points)
      return PolicyCanvasEdgeRoute(
        points: points,
        labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
      )
    }
  }
}

struct PolicyCanvasObstacleAwareGreedyLabelPlacement: PolicyCanvasEdgeLabelPlacementAlgorithm {
  func placeLabels(input: PolicyCanvasLabelPlacementInput) -> [String: CGPoint] {
    let prepared = input.prepared
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: prepared.fontScale)
    let routeFrames = policyCanvasRouteFrames(
      input.routes.map { (id: $0.key, route: $0.value) }
    )
    let labelledRoutes: [PolicyCanvasLabelPlacementRoute] = prepared.edges.compactMap { edge in
      guard !edge.label.isEmpty, let route = input.routes[edge.id] else {
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
      nodeFrames: prepared.nodes.map(\.frame) + policyCanvasGroupTitleFrames(prepared.groups),
      routeFrames: routeFrames
    )
  }
}

struct PolicyCanvasPolylineMidpointLabelPlacement: PolicyCanvasEdgeLabelPlacementAlgorithm {
  func placeLabels(input: PolicyCanvasLabelPlacementInput) -> [String: CGPoint] {
    input.prepared.edges.reduce(into: [:]) { positions, edge in
      guard !edge.label.isEmpty, let route = input.routes[edge.id] else {
        return
      }
      positions[edge.id] = route.arcLengthMidpoint
    }
  }
}

struct PolicyCanvasOrthogonalVisibilityGraphAStarRouter: PolicyCanvasEdgeRouter {
  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    let obstacles = preparedObstacles(source: source, target: target, raw: context.obstacles)
    let axes = gridAxes(source: source, target: target, obstacles: obstacles)
    guard
      let sx = axes.xs.firstIndex(of: PolicyCanvasVisibilityRouter.quantizedCoordinate(source.x)),
      let sy = axes.ys.firstIndex(of: PolicyCanvasVisibilityRouter.quantizedCoordinate(source.y)),
      let tx = axes.xs.firstIndex(of: PolicyCanvasVisibilityRouter.quantizedCoordinate(target.x)),
      let ty = axes.ys.firstIndex(of: PolicyCanvasVisibilityRouter.quantizedCoordinate(target.y)),
      let result = PolicyCanvasVisibilityAStar.run(
        gridXs: axes.xs,
        gridYs: axes.ys,
        sourceIndex: PolicyCanvasGridIndex(x: sx, y: sy),
        targetIndex: PolicyCanvasGridIndex(x: tx, y: ty),
        obstacles: obstacles
      )
    else {
      return PolicyCanvasHandCodedOrthogonalRouter().route(
        source: source,
        target: target,
        context: context
      )
    }
    let points = PolicyCanvasVisibilityRouter.compressCollinear(result.points)
    return PolicyCanvasEdgeRoute(
      points: points,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
    )
  }

  private func preparedObstacles(
    source: CGPoint,
    target: CGPoint,
    raw: [CGRect]
  ) -> [CGRect] {
    raw.filter { obstacle in
      let endpointProbe = obstacle.insetBy(
        dx: -PolicyCanvasVisibilityRouter.endpointDropProbe,
        dy: -PolicyCanvasVisibilityRouter.endpointDropProbe
      )
      return !endpointProbe.contains(source) && !endpointProbe.contains(target)
    }
  }

  private func gridAxes(
    source: CGPoint,
    target: CGPoint,
    obstacles: [CGRect]
  ) -> (xs: [CGFloat], ys: [CGFloat]) {
    let clearance = PolicyCanvasLayout.edgePortTurnMinimumLead
    var xs = [source.x, target.x, (source.x + target.x) / 2]
    var ys = [source.y, target.y, (source.y + target.y) / 2]
    for obstacle in obstacles {
      xs.append(contentsOf: [
        obstacle.minX - clearance,
        obstacle.minX,
        obstacle.maxX,
        obstacle.maxX + clearance,
      ])
      ys.append(contentsOf: [
        obstacle.minY - clearance,
        obstacle.minY,
        obstacle.maxY,
        obstacle.maxY + clearance,
      ])
    }
    return (sortedUnique(xs), sortedUnique(ys))
  }

  private func sortedUnique(_ values: [CGFloat]) -> [CGFloat] {
    Array(Set(values.map(PolicyCanvasVisibilityRouter.quantizedCoordinate))).sorted()
  }
}
