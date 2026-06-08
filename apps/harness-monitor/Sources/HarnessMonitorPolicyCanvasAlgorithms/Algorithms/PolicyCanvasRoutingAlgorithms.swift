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

/// Reference-form port markers: derive the visible side from each finished route,
/// then assign side-local marker positions with the balanced marker comb. Route
/// convergence feeds these terminals back into selection, so wires still end on
/// visible dots while single-marker sides stay centered and multi-marker sides
/// remain evenly spaced.
struct PolicyCanvasRouteTerminalPortMarkerPlacement: PolicyCanvasPortMarkerPlacementAlgorithm {
  func placeMarkers(input: PolicyCanvasPortMarkerPlacementInput) -> PolicyCanvasPortMarkerLayout {
    input.prepared.portMarkerLayout(routes: input.routes, nodeIndex: input.nodeIndex)
  }
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
      guard
        let route = selectedRoute(
          for: edge,
          context: RouteSelectionContext(
            prepared: prepared,
            nodeIndex: nodeIndex,
            terminalSlots: terminalSlots,
            obstacles: obstacles,
            portMarkerLayout: input.portMarkerLayout,
            passContext: input.passContext,
            router: input.router
          )
        )
      else {
        continue
      }
      routes[edge.id] = route
    }
    return routes
  }

  private struct RouteSelectionContext {
    let prepared: PolicyCanvasPreparedRouteInput
    let nodeIndex: [String: PolicyCanvasRouteNode]
    let terminalSlots: [String: PolicyCanvasRouteEndpointSlots]
    let obstacles: [CGRect]
    let portMarkerLayout: PolicyCanvasPortMarkerLayout?
    let passContext: PolicyCanvasDisplayedRoutePassContext?
    let router: any PolicyCanvasEdgeRouter
  }

  private struct FlexRouteSelectionInput {
    let edge: PolicyCanvasEdge
    let prepared: PolicyCanvasPreparedRouteInput
    let nodeIndex: [String: PolicyCanvasRouteNode]
    let slots: PolicyCanvasRouteEndpointSlots
    let sourceTerminal: PolicyCanvasPortTerminal?
    let targetTerminal: PolicyCanvasPortTerminal?
    let sourceNode: PolicyCanvasRouteNode?
    let targetNode: PolicyCanvasRouteNode?
    let source: SideCandidate
    let target: SideCandidate
    let baseContext: PolicyCanvasRouteContext
    let router: any PolicyCanvasEdgeRouter
  }

  private func selectedRoute(
    for edge: PolicyCanvasEdge,
    context: RouteSelectionContext
  ) -> PolicyCanvasEdgeRoute? {
    let slots =
      context.terminalSlots[edge.id]
      ?? PolicyCanvasRouteEndpointSlots(
        source: .single,
        target: .single
      )
    let sourceTerminal = context.portMarkerLayout?.terminal(edgeID: edge.id, role: .source)
    let targetTerminal = context.portMarkerLayout?.terminal(edgeID: edge.id, role: .target)
    let requestedSourceSide = sourceTerminal?.side ?? policyCanvasResolvedPortSide(for: edge.source)
    let requestedTargetSide = targetTerminal?.side ?? policyCanvasResolvedPortSide(for: edge.target)
    guard
      let sourceCandidate = context.prepared.routeAnchorCandidate(
        for: edge.source,
        side: requestedSourceSide,
        nodeIndex: context.nodeIndex,
        // Output-side fan-out already routes from stable source anchors; the
        // target slot is what prevents multiple inbound edges from landing on
        // one input terminal.
        terminalSlot: .single,
        terminal: sourceTerminal
      ),
      let targetCandidate = context.prepared.routeAnchorCandidate(
        for: edge.target,
        side: requestedTargetSide,
        nodeIndex: context.nodeIndex,
        terminalSlot: slots.target,
        terminal: targetTerminal
      )
    else {
      return nil
    }
    let source = SideCandidate(anchor: sourceCandidate)
    let target = SideCandidate(anchor: targetCandidate)
    let sourceNode = context.nodeIndex[edge.source.nodeID]
    let targetNode = context.nodeIndex[edge.target.nodeID]
    let selectedLane =
      context.passContext.map { selectedRouteLane(for: edge, passContext: $0) } ?? 0
    let baseContext = PolicyCanvasRouteContext(
      lane: selectedLane,
      groups: context.prepared.groups,
      sourceGroupID: sourceNode?.groupID,
      targetGroupID: targetNode?.groupID,
      obstacles: context.obstacles,
      obstaclesAreCanonical: true,
      corridorHint: context.prepared.routingHints?.edgeHint(for: edge.id)
    )
    guard !edge.effectivePinnedPortSide else {
      return pinnedRoute(
        source: source,
        target: target,
        context: baseContext,
        router: context.router
      )
    }
    return selectedFlexRoute(
      FlexRouteSelectionInput(
        edge: edge,
        prepared: context.prepared,
        nodeIndex: context.nodeIndex,
        slots: slots,
        sourceTerminal: sourceTerminal,
        targetTerminal: targetTerminal,
        sourceNode: sourceNode,
        targetNode: targetNode,
        source: source,
        target: target,
        baseContext: baseContext,
        router: context.router
      )
    )
  }

  private func selectedRouteLane(
    for edge: PolicyCanvasEdge,
    passContext: PolicyCanvasDisplayedRoutePassContext
  ) -> Int {
    max(
      passContext.edgeLanes[edge.id, default: 0],
      passContext.sourceFanoutLanes[edge.id, default: 0],
      passContext.targetFanoutLanes[edge.id, default: 0]
    )
  }

  private func selectedFlexRoute(_ input: FlexRouteSelectionInput) -> PolicyCanvasEdgeRoute {
    guard usesFlexAnchors(sourceNode: input.sourceNode, targetNode: input.targetNode) else {
      let route = pinnedRoute(
        source: input.source,
        target: input.target,
        context: input.baseContext,
        router: input.router
      )
      if routeAvoidsNonEndpointObstacles(
        route,
        sourceActual: input.source.actual,
        targetActual: input.target.actual,
        context: input.baseContext
      ) {
        return route
      }
      return safeAlternateRoute(input) ?? route
    }
    let sourceCandidates = sideCandidates(
      for: input.edge.source,
      nodeIndex: input.nodeIndex,
      prepared: input.prepared,
      terminalSlot: .single,
      terminal: input.sourceTerminal
    )
    let targetCandidates = sideCandidates(
      for: input.edge.target,
      nodeIndex: input.nodeIndex,
      prepared: input.prepared,
      terminalSlot: input.slots.target,
      terminal: input.targetTerminal
    )
    guard !sourceCandidates.isEmpty, !targetCandidates.isEmpty else {
      return pinnedRoute(
        source: input.source,
        target: input.target,
        context: input.baseContext,
        router: input.router
      )
    }
    let route = flexRoute(
      sourceCandidates: sourceCandidates,
      targetCandidates: targetCandidates,
      context: PolicyCanvasRouteContext(
        lane: input.baseContext.lane,
        groups: input.baseContext.groups,
        sourceGroupID: input.baseContext.sourceGroupID,
        targetGroupID: input.baseContext.targetGroupID,
        obstacles: input.baseContext.obstacles,
        obstaclesAreCanonical: true,
        sourceActual: sourceCandidates[0].actual,
        targetActual: targetCandidates[0].actual,
        lineSpacing: input.baseContext.lineSpacing,
        corridorHint: input.baseContext.corridorHint
      ),
      router: input.router
    )
    let routedSource = matchingCandidate(for: route.points.first, in: sourceCandidates)
    let routedTarget = matchingCandidate(for: route.points.last, in: targetCandidates)
    if routeAvoidsNonEndpointObstacles(
      route,
      sourceActual: routedSource.actual,
      targetActual: routedTarget.actual,
      context: input.baseContext
    ) {
      return route
    }
    return safeAlternateRoute(input) ?? route
  }

  private struct AlternateRouteCandidate {
    let route: PolicyCanvasEdgeRoute
    let cost: CGFloat
    let sourceSide: PolicyCanvasPortSide
    let targetSide: PolicyCanvasPortSide
  }

  private func safeAlternateRoute(_ input: FlexRouteSelectionInput) -> PolicyCanvasEdgeRoute? {
    let sourceCandidates = orderedSideCandidates(
      sideCandidates(
        for: input.edge.source,
        nodeIndex: input.nodeIndex,
        prepared: input.prepared,
        terminalSlot: input.slots.source,
        terminal: nil
      ),
      preferredSide: input.source.side
    )
    let targetCandidates = orderedSideCandidates(
      sideCandidates(
        for: input.edge.target,
        nodeIndex: input.nodeIndex,
        prepared: input.prepared,
        terminalSlot: input.slots.target,
        terminal: nil
      ),
      preferredSide: input.target.side
    )
    guard !sourceCandidates.isEmpty, !targetCandidates.isEmpty else {
      return nil
    }
    var best: AlternateRouteCandidate?
    for source in sourceCandidates {
      for target in targetCandidates {
        let context = PolicyCanvasRouteContext(
          lane: input.baseContext.lane,
          groups: input.baseContext.groups,
          sourceGroupID: input.baseContext.sourceGroupID,
          targetGroupID: input.baseContext.targetGroupID,
          obstacles: input.baseContext.obstacles,
          obstaclesAreCanonical: true,
          sourceActual: source.actual,
          targetActual: target.actual,
          lineSpacing: input.baseContext.lineSpacing,
          corridorHint: input.baseContext.corridorHint
        )
        let route = pinnedRoute(
          source: source,
          target: target,
          context: context,
          router: input.router
        )
        guard routeAvoidsNonEndpointObstacles(
          route,
          sourceActual: source.actual,
          targetActual: target.actual,
          context: input.baseContext
        ) else {
          continue
        }
        let sidePenalty =
          (source.side == input.source.side ? 0 : PolicyCanvasVisibilityRouter.bendPenalty)
          + (target.side == input.target.side ? 0 : PolicyCanvasVisibilityRouter.bendPenalty)
        let candidate = AlternateRouteCandidate(
          route: route,
          cost: PolicyCanvasVisibilityRouter.routeCost(points: route.points) + sidePenalty,
          sourceSide: source.side,
          targetSide: target.side
        )
        if let current = best {
          if alternateRoute(candidate, isBetterThan: current) {
            best = candidate
          }
        } else {
          best = candidate
        }
      }
    }
    return best?.route
  }

  private func orderedSideCandidates(
    _ candidates: [SideCandidate],
    preferredSide: PolicyCanvasPortSide
  ) -> [SideCandidate] {
    candidates.sorted { left, right in
      let leftPreferred = left.side == preferredSide
      let rightPreferred = right.side == preferredSide
      if leftPreferred != rightPreferred {
        return leftPreferred
      }
      if left.side.rawValue != right.side.rawValue {
        return left.side.rawValue < right.side.rawValue
      }
      if left.actual.x != right.actual.x {
        return left.actual.x < right.actual.x
      }
      return left.actual.y < right.actual.y
    }
  }

  private func alternateRoute(
    _ candidate: AlternateRouteCandidate,
    isBetterThan current: AlternateRouteCandidate
  ) -> Bool {
    if abs(candidate.cost - current.cost) > 0.001 {
      return candidate.cost < current.cost
    }
    if candidate.sourceSide.rawValue != current.sourceSide.rawValue {
      return candidate.sourceSide.rawValue < current.sourceSide.rawValue
    }
    if candidate.targetSide.rawValue != current.targetSide.rawValue {
      return candidate.targetSide.rawValue < current.targetSide.rawValue
    }
    return pointKey(candidate.route.points) < pointKey(current.route.points)
  }

  private func pointKey(_ points: [CGPoint]) -> String {
    points
      .map { "\(Int(($0.x * 1_000).rounded())):\(Int(($0.y * 1_000).rounded()))" }
      .joined(separator: "|")
  }

  private func routeAvoidsNonEndpointObstacles(
    _ route: PolicyCanvasEdgeRoute,
    sourceActual: CGPoint,
    targetActual: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> Bool {
    let endpointPoints = [sourceActual, targetActual]
    let obstacles = context.obstacles.filter { rect in
      let ownFrame = rect.insetBy(
        dx: -PolicyCanvasVisibilityRouter.endpointDropProbe,
        dy: -PolicyCanvasVisibilityRouter.endpointDropProbe
      )
      return !endpointPoints.contains(where: { ownFrame.contains($0) })
    }
    return !policyCanvasRouteIntersectsObstacles(route, obstacles: obstacles)
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
      sourceActual: source.actual,
      targetActual: target.actual,
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
