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
        input: PolicyCanvasRouteTerminalInput(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .source),
          endpoint: edge.source,
          point: route.points.first,
          side: policyCanvasRouteSourceSide(route)
        ),
        prepared: prepared,
        nodeIndex: nodeIndex,
        terminals: &terminals,
        endpoints: &endpoints
      )
      addTerminal(
        input: PolicyCanvasRouteTerminalInput(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .target),
          endpoint: edge.target,
          point: route.points.last,
          side: policyCanvasRouteTargetSide(route)
        ),
        prepared: prepared,
        nodeIndex: nodeIndex,
        terminals: &terminals,
        endpoints: &endpoints
      )
    }
    return PolicyCanvasPortMarkerLayout(terminalsByKey: terminals, endpointsByKey: endpoints)
  }

  private func addTerminal(
    input: PolicyCanvasRouteTerminalInput,
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal],
    endpoints: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint]
  ) {
    guard
      let point = input.point,
      let side = input.side,
      let base = prepared.portAnchor(for: input.endpoint, side: side, nodeIndex: nodeIndex)
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
    terminals[input.key] = PolicyCanvasPortTerminal(side: side, axisOffset: axisOffset)
    endpoints[input.key] = input.endpoint
  }
}

private struct PolicyCanvasRouteTerminalInput {
  let key: PolicyCanvasRouteTerminalKey
  let endpoint: PolicyCanvasPortEndpoint
  let point: CGPoint?
  let side: PolicyCanvasPortSide?
}

struct PolicyCanvasFirstFeasibleRouteSelection: PolicyCanvasRouteSelectionAlgorithm {
  func selectRoutes(input: PolicyCanvasRouteSelectionInput) -> [String: PolicyCanvasEdgeRoute] {
    let prepared = input.prepared
    let nodeIndex = input.passContext?.nodeIndex ?? prepared.nodeIndex
    let terminalSlots =
      input.passContext?.terminalSlots
      ?? prepared.routeEndpointSlots(edges: prepared.edges, nodeIndex: nodeIndex)
    let obstacles =
      input.passContext?.obstacles
      ?? policyCanvasCanonicalObstacles(
        prepared.nodes.map(\.frame) + policyCanvasGroupTitleFrames(prepared.groups)
      )
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    routes.reserveCapacity(prepared.edges.count)
    for edge in prepared.edges {
      let slots = terminalSlots[edge.id] ?? PolicyCanvasRouteEndpointSlots(
        source: .single,
        target: .single
      )
      let sourceTerminal = input.portMarkerLayout?.terminal(edgeID: edge.id, role: .source)
      let targetTerminal = input.portMarkerLayout?.terminal(edgeID: edge.id, role: .target)
      let requestedSourceSide =
        sourceTerminal?.side ?? policyCanvasResolvedPortSide(for: edge.source)
      let requestedTargetSide =
        targetTerminal?.side ?? policyCanvasResolvedPortSide(for: edge.target)
      guard
        let sourceCandidate = prepared.routeAnchorCandidate(
          for: edge.source,
          side: requestedSourceSide,
          nodeIndex: nodeIndex,
          // Output-side fan-out already routes from stable source anchors; the
          // target slot is what prevents multiple inbound edges from landing on
          // one input terminal.
          terminalSlot: .single,
          terminal: sourceTerminal
        ),
        let targetCandidate = prepared.routeAnchorCandidate(
          for: edge.target,
          side: requestedTargetSide,
          nodeIndex: nodeIndex,
          terminalSlot: slots.target,
          terminal: targetTerminal
      )
      else {
        continue
      }
      let source = SideCandidate(anchor: sourceCandidate)
      let target = SideCandidate(anchor: targetCandidate)
      let sourceNode = nodeIndex[edge.source.nodeID]
      let targetNode = nodeIndex[edge.target.nodeID]
      let baseContext = PolicyCanvasRouteContext(
        lane: 0,
        groups: prepared.groups,
        sourceGroupID: sourceNode?.groupID,
        targetGroupID: targetNode?.groupID,
        obstacles: obstacles,
        obstaclesAreCanonical: true,
        corridorHint: prepared.routingHints?.edgeHint(for: edge.id)
      )
      if edge.effectivePinnedPortSide
        || !usesFlexAnchors(sourceNode: sourceNode, targetNode: targetNode)
      {
        routes[edge.id] = pinnedRoute(
          source: source,
          target: target,
          context: baseContext,
          router: input.router
        )
        continue
      }
      let sourceCandidates = sideCandidates(
        for: edge.source,
        nodeIndex: nodeIndex,
        prepared: prepared,
        terminalSlot: .single,
        terminal: sourceTerminal
      )
      let targetCandidates = sideCandidates(
        for: edge.target,
        nodeIndex: nodeIndex,
        prepared: prepared,
        terminalSlot: slots.target,
        terminal: targetTerminal
      )
      guard !sourceCandidates.isEmpty, !targetCandidates.isEmpty else {
        routes[edge.id] = pinnedRoute(
          source: source,
          target: target,
          context: baseContext,
          router: input.router
        )
        continue
      }
      routes[edge.id] = flexRoute(
        sourceCandidates: sourceCandidates,
        targetCandidates: targetCandidates,
        context: PolicyCanvasRouteContext(
          lane: baseContext.lane,
          groups: baseContext.groups,
          sourceGroupID: baseContext.sourceGroupID,
          targetGroupID: baseContext.targetGroupID,
          obstacles: baseContext.obstacles,
          obstaclesAreCanonical: true,
          sourceActual: sourceCandidates[0].actual,
          targetActual: targetCandidates[0].actual,
          lineSpacing: baseContext.lineSpacing,
          corridorHint: baseContext.corridorHint
        ),
        router: input.router
      )
    }
    return routes
  }

  private struct SideCandidate {
    let side: PolicyCanvasPortSide
    let actual: CGPoint
    let lead: CGPoint

    init(
      side: PolicyCanvasPortSide,
      actual: CGPoint,
      lead: CGPoint
    ) {
      self.side = side
      self.actual = actual
      self.lead = lead
    }

    init(anchor: PolicyCanvasRouteAnchorCandidate) {
      side = anchor.side
      actual = anchor.point
      lead = policyCanvasPortLeadPoint(anchor.point, side: anchor.side)
    }
  }

  private func usesFlexAnchors(
    sourceNode: PolicyCanvasRouteNode?,
    targetNode: PolicyCanvasRouteNode?
  ) -> Bool {
    guard let sourceNode, let targetNode else {
      return false
    }
    return targetNode.frame.midX < sourceNode.frame.midX
  }

  private func sideCandidates(
    for endpoint: PolicyCanvasPortEndpoint,
    nodeIndex: [String: PolicyCanvasRouteNode],
    prepared: PolicyCanvasPreparedRouteInput,
    terminalSlot: PolicyCanvasRouteEndpointSlot,
    terminal: PolicyCanvasPortTerminal?
  ) -> [SideCandidate] {
    let sides = terminal.map { [$0.side] } ?? policyCanvasRoutablePortSides(for: endpoint.kind)
    return sides.compactMap { side in
      prepared.routeAnchorCandidate(
        for: endpoint,
        side: side,
        nodeIndex: nodeIndex,
        terminalSlot: terminalSlot,
        terminal: terminal
      )
      .map(SideCandidate.init(anchor:))
    }
  }

  private func pinnedRoute(
    source: SideCandidate,
    target: SideCandidate,
    context: PolicyCanvasRouteContext,
    router: any PolicyCanvasEdgeRouter
  ) -> PolicyCanvasEdgeRoute {
    let pinnedContext = PolicyCanvasRouteContext(
      lane: context.lane,
      groups: context.groups,
      sourceGroupID: context.sourceGroupID,
      targetGroupID: context.targetGroupID,
      obstacles: context.obstacles,
      obstaclesAreCanonical: true,
      sourceActual: source.lead,
      targetActual: target.lead,
      lineSpacing: context.lineSpacing,
      corridorHint: context.corridorHint
    )
    let core = router.route(source: source.lead, target: target.lead, context: pinnedContext)
    return policyCanvasBridgedRoute(
      baseRoute: core,
      source: PolicyCanvasEscapeCandidate(
        side: source.side,
        actual: source.actual,
        exit: source.lead,
        routed: core.points.first ?? source.lead
      ),
      target: PolicyCanvasEscapeCandidate(
        side: target.side,
        actual: target.actual,
        exit: target.lead,
        routed: core.points.last ?? target.lead
      )
    )
  }

  private func flexRoute(
    sourceCandidates: [SideCandidate],
    targetCandidates: [SideCandidate],
    context: PolicyCanvasRouteContext,
    router: any PolicyCanvasEdgeRouter
  ) -> PolicyCanvasEdgeRoute {
    let core = router.route(
      sourceCandidates: sourceCandidates.map(\.lead),
      targetCandidates: targetCandidates.map(\.lead),
      context: context
    )
    let source = matchingCandidate(for: core.points.first, in: sourceCandidates)
    let target = matchingCandidate(for: core.points.last, in: targetCandidates)
    return policyCanvasBridgedRoute(
      baseRoute: core,
      source: PolicyCanvasEscapeCandidate(
        side: source.side,
        actual: source.actual,
        exit: source.lead,
        routed: core.points.first ?? source.lead
      ),
      target: PolicyCanvasEscapeCandidate(
        side: target.side,
        actual: target.actual,
        exit: target.lead,
        routed: core.points.last ?? target.lead
      )
    )
  }

  private func matchingCandidate(
    for point: CGPoint?,
    in candidates: [SideCandidate]
  ) -> SideCandidate {
    guard let point else {
      return candidates[0]
    }
    return candidates.min { left, right in
      distanceSquared(left.lead, point) < distanceSquared(right.lead, point)
    } ?? candidates[0]
  }

  private func distanceSquared(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
    let dx = left.x - right.x
    let dy = left.y - right.y
    return (dx * dx) + (dy * dy)
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
