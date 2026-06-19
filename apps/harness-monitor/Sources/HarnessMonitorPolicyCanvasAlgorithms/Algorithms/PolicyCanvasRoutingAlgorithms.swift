import CoreGraphics
import Foundation

struct PolicyCanvasPortMarkerPlacementInput: Sendable {
  let prepared: PolicyCanvasPreparedRouteInput
  let routes: [String: PolicyCanvasEdgeRoute]
  let nodeIndex: [String: PolicyCanvasRouteNode]
}

struct PolicyCanvasPortMarkerSeedInput: Sendable {
  let prepared: PolicyCanvasPreparedRouteInput
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
  func seedMarkers(input: PolicyCanvasPortMarkerSeedInput) -> PolicyCanvasPortMarkerLayout?
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
  func seedMarkers(input: PolicyCanvasPortMarkerSeedInput) -> PolicyCanvasPortMarkerLayout? {
    .empty
  }

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
  func seedMarkers(input: PolicyCanvasPortMarkerSeedInput) -> PolicyCanvasPortMarkerLayout? {
    input.prepared.seededPortMarkerLayout(nodeIndex: input.nodeIndex)
  }

  func placeMarkers(input: PolicyCanvasPortMarkerPlacementInput) -> PolicyCanvasPortMarkerLayout {
    input.prepared.portMarkerLayout(routes: input.routes, nodeIndex: input.nodeIndex)
  }
}

struct PolicyCanvasFirstFeasibleRouteSelection: PolicyCanvasRouteSelectionAlgorithm {
  private let parallelEdgeThreshold = 24
  private let lockedTerminalSideThreshold = 1_000

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
    let context = RouteSelectionContext(
      prepared: prepared,
      nodeIndex: nodeIndex,
      terminalSlots: terminalSlots,
      obstacles: obstacles,
      portMarkerLayout: input.portMarkerLayout,
      locksTerminalSides: input.portMarkerLayout != nil
        && prepared.edges.count > lockedTerminalSideThreshold,
      passContext: input.passContext,
      router: input.router
    )
    if prepared.edges.count >= parallelEdgeThreshold,
      ProcessInfo.processInfo.activeProcessorCount > 1
    {
      return parallelRoutes(edges: prepared.edges, context: context)
    }
    return serialRoutes(edges: prepared.edges, context: context)
  }

  private func serialRoutes(
    edges: [PolicyCanvasEdge],
    context: RouteSelectionContext
  ) -> [String: PolicyCanvasEdgeRoute] {
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    routes.reserveCapacity(edges.count)
    for edge in edges {
      guard
        let route = selectedRoute(
          for: edge,
          context: context
        )
      else {
        continue
      }
      routes[edge.id] = route
    }
    return routes
  }

  struct RouteSelectionContext {
    let prepared: PolicyCanvasPreparedRouteInput
    let nodeIndex: [String: PolicyCanvasRouteNode]
    let terminalSlots: [String: PolicyCanvasRouteEndpointSlots]
    let obstacles: [CGRect]
    let portMarkerLayout: PolicyCanvasPortMarkerLayout?
    let locksTerminalSides: Bool
    let passContext: PolicyCanvasDisplayedRoutePassContext?
    let router: any PolicyCanvasEdgeRouter
  }

  struct FlexRouteSelectionInput {
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
    let locksTerminalSides: Bool
    let router: any PolicyCanvasEdgeRouter
  }

  func selectedRoute(
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
    let flexInput = FlexRouteSelectionInput(
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
      locksTerminalSides: context.locksTerminalSides,
      router: context.router
    )
    if edge.effectivePinnedPortSide {
      let route = pinnedRoute(
        source: source,
        target: target,
        context: baseContext,
        router: context.router
      )
      if routeAvoidsNonEndpointObstacles(
        route,
        sourceActual: source.actual,
        targetActual: target.actual,
        context: baseContext
      ) {
        return route
      }
      return safeAlternateRoute(
        flexInput,
        allowsSideChanges: !context.locksTerminalSides && edge.kind != .error
      ) ?? route
    }
    return selectedFlexRoute(flexInput)
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
