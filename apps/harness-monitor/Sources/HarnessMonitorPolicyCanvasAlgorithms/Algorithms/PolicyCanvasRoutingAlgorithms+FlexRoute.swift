// Flex-route, alternate-route, and side-candidate helpers extracted from
// PolicyCanvasFirstFeasibleRouteSelection to satisfy the file-length limit.
import CoreGraphics
import Foundation

extension PolicyCanvasFirstFeasibleRouteSelection {
  struct SideCandidate {
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

  struct AlternateRouteCandidate {
    let route: PolicyCanvasEdgeRoute
    let cost: CGFloat
    let sourceSide: PolicyCanvasPortSide
    let targetSide: PolicyCanvasPortSide
  }

  func selectedFlexRoute(_ input: FlexRouteSelectionInput) -> PolicyCanvasEdgeRoute {
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
      return safeAlternateRoute(input, allowsSideChanges: !input.locksTerminalSides) ?? route
    }
    let requestedRoute = pinnedRoute(
      source: input.source,
      target: input.target,
      context: input.baseContext,
      router: input.router
    )
    if routeAvoidsNonEndpointObstacles(
      requestedRoute,
      sourceActual: input.source.actual,
      targetActual: input.target.actual,
      context: input.baseContext
    ) {
      return requestedRoute
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
    return safeAlternateRoute(input, allowsSideChanges: !input.locksTerminalSides) ?? route
  }

  func safeAlternateRoute(
    _ input: FlexRouteSelectionInput,
    allowsSideChanges: Bool = true
  ) -> PolicyCanvasEdgeRoute? {
    let sourceCandidates = orderedSideCandidates(
      sideCandidates(
        for: input.edge.source,
        nodeIndex: input.nodeIndex,
        prepared: input.prepared,
        terminalSlot: input.slots.source,
        terminal: nil
      ).filter { allowsSideChanges || $0.side == input.source.side },
      preferredSide: input.source.side
    )
    let targetCandidates = orderedSideCandidates(
      sideCandidates(
        for: input.edge.target,
        nodeIndex: input.nodeIndex,
        prepared: input.prepared,
        terminalSlot: input.slots.target,
        terminal: nil
      ).filter { allowsSideChanges || $0.side == input.target.side },
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
        guard
          routeAvoidsNonEndpointObstacles(
            route,
            sourceActual: source.actual,
            targetActual: target.actual,
            context: input.baseContext
          )
        else {
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

  func orderedSideCandidates(
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

  func alternateRoute(
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

  func pointKey(_ points: [CGPoint]) -> String {
    points
      .map { "\(Int(($0.x * 1_000).rounded())):\(Int(($0.y * 1_000).rounded()))" }
      .joined(separator: "|")
  }

  func routeAvoidsNonEndpointObstacles(
    _ route: PolicyCanvasEdgeRoute,
    sourceActual: CGPoint,
    targetActual: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> Bool {
    let endpointPoints = [sourceActual, targetActual]
    let routeEnvelope = policyCanvasRouteBounds(route).insetBy(dx: -1, dy: -1)
    let obstacles = context.obstacles.filter { rect in
      guard routeEnvelope.isNull || rect.intersects(routeEnvelope) else {
        return false
      }
      let ownFrame = rect.insetBy(
        dx: -PolicyCanvasVisibilityRouter.endpointDropProbe,
        dy: -PolicyCanvasVisibilityRouter.endpointDropProbe
      )
      return !endpointPoints.contains(where: { ownFrame.contains($0) })
    }
    return !policyCanvasRouteIntersectsObstacles(route, obstacles: obstacles)
  }

  func usesFlexAnchors(
    sourceNode: PolicyCanvasRouteNode?,
    targetNode: PolicyCanvasRouteNode?
  ) -> Bool {
    guard let sourceNode, let targetNode else {
      return false
    }
    return targetNode.frame.midX < sourceNode.frame.midX
  }

  func sideCandidates(
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

  func pinnedRoute(
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

  func flexRoute(
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

  func matchingCandidate(
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

  func distanceSquared(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
    let dx = left.x - right.x
    let dy = left.y - right.y
    return (dx * dx) + (dy * dy)
  }
}
