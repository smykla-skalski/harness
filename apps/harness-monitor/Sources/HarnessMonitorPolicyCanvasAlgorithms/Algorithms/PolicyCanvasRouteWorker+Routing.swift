import SwiftUI

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
    let routeState = policyCanvasConvergedRouteState(
      prepared: self,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let routes = algorithms.routePostProcessing.processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: self, routes: routeState.routes)
    )
    let labelPositions = algorithms.labelPlacement.placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: self, routes: routes)
    )
    let visibleBounds = visibleBounds(routes: routes, labelPositions: labelPositions)
    return PolicyCanvasPreparedRouteComputation(
      routes: routes,
      labelPositions: labelPositions,
      portVisibility: portVisibility(routes: routes, nodeIndex: nodeIndex),
      portMarkerLayout: routeState.portMarkerLayout,
      visibleBounds: visibleBounds
    )
  }

  public func displayedRoutes(
    router: any PolicyCanvasEdgeRouter,
    portMarkerLayout: PolicyCanvasPortMarkerLayout? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let nodeIndex = nodeIndex
    let passContext = displayedRoutePassContext(nodeIndex: nodeIndex)
    return displayedRoutes(
      passContext: passContext,
      router: router,
      portMarkerLayout: portMarkerLayout
    )
  }

  public func postProcessedRoutes(
    routes: [String: PolicyCanvasEdgeRoute],
    algorithmSelection: PolicyCanvasAlgorithmSelection
  ) -> [String: PolicyCanvasEdgeRoute] {
    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: algorithmSelection)
    return algorithms.routePostProcessing.processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: self, routes: routes)
    )
  }

  func displayedRoutes(
    passContext: PolicyCanvasDisplayedRoutePassContext,
    router: any PolicyCanvasEdgeRouter,
    portMarkerLayout: PolicyCanvasPortMarkerLayout? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let nodeIndex = passContext.nodeIndex
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    var previousRoutes: [PolicyCanvasDisplayedRouteCachedClearance] = []
    routes.reserveCapacity(edges.count)
    previousRoutes.reserveCapacity(edges.count)
    for edge in passContext.orderedEdges {
      guard
        let source = passContext.portAnchors[edge.source],
        let target = passContext.portAnchors[edge.target]
      else {
        continue
      }
      let edgeTerminalSlots = passContext.terminalSlots[edge.id]
      let familyPreference = passContext.familyPreferences[edge.id, default: .none]
      let request = resolvedDisplayedRouteRequest(
        edge: PolicyCanvasDisplayedRouteEdgeContext(
          edge: edge,
          source: source,
          target: target,
          routeLane: passContext.edgeLanes[edge.id, default: 0],
          sourceFanoutLane: passContext.sourceFanoutLanes[edge.id, default: 0],
          targetFanoutLane: passContext.targetFanoutLanes[edge.id, default: 0],
          sourceTerminalSlot: edgeTerminalSlots?.source ?? .single,
          targetTerminalSlot: edgeTerminalSlots?.target ?? .single,
          familyPreference: familyPreference
        ),
        shared: PolicyCanvasDisplayedRouteSharedContext(
          portMarkerLayout: portMarkerLayout,
          nodeIndex: nodeIndex,
          obstacles: passContext.obstacles,
          routingHints: routingHints,
          router: router
        )
      )
      let route = policyCanvasCollisionAwareDisplayedRoute(
        request,
        previousRoutes: previousRoutes
      )
      routes[edge.id] = route
      previousRoutes.append(
        PolicyCanvasDisplayedRouteCachedClearance(
          PolicyCanvasDisplayedRouteClearance(
            edge: edge,
            // Derive the corridor key from the chosen route's dominant
            // horizontal lane rather than the layout hint. After bundle
            // realignment the route may sit on a different y than the hint
            // proposed; using the hint key would falsely declare two edges
            // on different actual y values as sharing a corridor.
            corridorKey: policyCanvasCorridorKey(
              forRoute: route,
              hint: request.corridorHint,
              lineSpacing: request.lineSpacing
            ),
            route: route,
            minimumSpacing: policyCanvasRouteMinimumSpacing(request: request, route: route)
          ),
        )
      )
    }
    return routes
  }

  public func policyCanvasCorridorKey(
    forRoute route: PolicyCanvasEdgeRoute,
    hint: PolicyCanvasEdgeCorridorHint?,
    lineSpacing: CGFloat
  ) -> PolicyCanvasRouteCorridorKey? {
    Self.policyCanvasCorridorKey(forRoute: route, hint: hint, lineSpacing: lineSpacing)
  }

  public static func policyCanvasCorridorKey(
    forRoute route: PolicyCanvasEdgeRoute,
    hint: PolicyCanvasEdgeCorridorHint?,
    lineSpacing: CGFloat
  ) -> PolicyCanvasRouteCorridorKey? {
    guard let hint else {
      return nil
    }
    guard let dominantY = policyCanvasDominantHorizontalLaneCoordinate(route) else {
      return hint.key
    }
    let laneStep = max(lineSpacing, PolicyCanvasLayout.gridSize)
    let derivedIndex = Int((dominantY / laneStep).rounded())
    return PolicyCanvasRouteCorridorKey(
      sourceScopeID: hint.key.sourceScopeID,
      targetScopeID: hint.key.targetScopeID,
      targetNodeID: hint.key.targetNodeID,
      label: hint.key.label,
      laneIndex: derivedIndex
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

  private func resolvedDisplayedRouteRequest(
    edge edgeContext: PolicyCanvasDisplayedRouteEdgeContext,
    shared: PolicyCanvasDisplayedRouteSharedContext
  ) -> PolicyCanvasResolvedDisplayedRouteRequest {
    let edge = edgeContext.edge
    let nodeIndex = shared.nodeIndex
    let sourceTerminal = shared.portMarkerLayout?.terminal(edgeID: edge.id, role: .source)
    let targetTerminal = shared.portMarkerLayout?.terminal(edgeID: edge.id, role: .target)
    let corridorHint = shared.routingHints?.edgeHint(for: edge.id)
    let fixedSourceSide = edge.source.side
    let fixedTargetSide =
      edge.target.side
      ?? policyCanvasGeometryAwareForcedTargetSide(
        forced: edgeContext.familyPreference.forcedTargetSide,
        sourceFrame: nodeIndex[edge.source.nodeID]?.frame,
        targetFrame: nodeIndex[edge.target.nodeID]?.frame
      )
    let preferredSourceSide = policyCanvasPreferredSourceSide(
      input: PolicyCanvasPreferredSourceSideInput(
        fixedSide: fixedSourceSide,
        forcedFanOutSide: edgeContext.familyPreference.forcedSourceSide,
        terminalSide: sourceTerminal?.side,
        natural: policyCanvasResolvedPortSide(for: edge.source),
        isFanInMember: edgeContext.familyPreference.forcedTargetSide == .top,
        sourceFrame: nodeIndex[edge.source.nodeID]?.frame,
        targetFrame: nodeIndex[edge.target.nodeID]?.frame
      )
    )
    // Drop the marker terminal when its side disagrees with the chosen source side,
    // so the route anchors to the chosen side's port instead of the collision-derived
    // one (a fan-in rail forced back to its source's top must not keep a stale bottom
    // anchor, which would re-seat it on the bottom port and dive through the row).
    let effectiveSourceTerminal = effectiveSourceTerminal(
      sourceTerminal,
      preferredSide: preferredSourceSide
    )
    let targetFrame = nodeIndex[edge.target.nodeID]?.frame
    let naturalTargetSide = policyCanvasResolvedPortSide(for: edge.target)
    let preferredTargetSide =
      fixedTargetSide
      ?? preferredFlexibleTargetSide(
        terminalSide: targetTerminal?.side,
        naturalSide: naturalTargetSide,
        targetFrame: targetFrame,
        corridorHint: corridorHint
      )
      ?? policyCanvasGeometryAwareTargetSide(
        sourceFrame: nodeIndex[edge.source.nodeID]?.frame,
        targetFrame: targetFrame
      )
      ?? targetTerminal?.side
    let effectiveTargetTerminal = effectiveTargetTerminal(
      targetTerminal,
      preferredSide: preferredTargetSide,
      fixedTargetSide: fixedTargetSide
    )
    let targetCandidates = policyCanvasPreferredRouteAnchorCandidates(
      routeAnchorCandidates(
        for: edge.target,
        nodeIndex: nodeIndex,
        terminalSlot: edgeContext.targetTerminalSlot,
        terminal: effectiveTargetTerminal
      ),
      preferredSide: preferredTargetSide
    )
    let resolvedSourceCandidates = policyCanvasPreferredRouteAnchorCandidates(
      routeAnchorCandidates(
        for: edge.source,
        nodeIndex: nodeIndex,
        terminalSlot: edgeContext.sourceTerminalSlot,
        terminal: effectiveSourceTerminal
      ),
      preferredSide: preferredSourceSide
    )
    let targetSide = preferredTargetSide ?? naturalTargetSide
    return PolicyCanvasResolvedDisplayedRouteRequest(
      router: shared.router,
      edge: edge,
      source: edgeContext.source,
      target: edgeContext.target,
      routeLane: edgeContext.routeLane,
      sourceFanoutLane: edgeContext.sourceFanoutLane,
      targetFanoutLane: edgeContext.targetFanoutLane,
      lineSpacing: edgeLineSpacing(for: edge, nodeIndex: nodeIndex),
      obstacles: shared.obstacles,
      groups: groups,
      sourceGroupID: nodeIndex[edge.source.nodeID]?.groupID,
      targetGroupID: nodeIndex[edge.target.nodeID]?.groupID,
      sourceAnchor: routeAnchorCandidate(
        for: edge.source,
        side: preferredSourceSide,
        nodeIndex: nodeIndex,
        terminalSlot: edgeContext.sourceTerminalSlot,
        terminal: effectiveSourceTerminal
      ) ?? (point: edgeContext.source, side: preferredSourceSide),
      targetAnchor: routeAnchorCandidate(
        for: edge.target,
        side: targetSide,
        nodeIndex: nodeIndex,
        terminalSlot: edgeContext.targetTerminalSlot,
        terminal: effectiveTargetTerminal
      ) ?? (point: edgeContext.target, side: targetSide),
      sourceCandidates: resolvedSourceCandidates,
      targetCandidates: targetCandidates,
      sourceSpacingBySide: portSpacingBySide(for: edge.source, nodeIndex: nodeIndex),
      targetSpacingBySide: portSpacingBySide(for: edge.target, nodeIndex: nodeIndex),
      corridorHint: corridorHint
    )
  }

  private func effectiveSourceTerminal(
    _ terminal: PolicyCanvasPortTerminal?,
    preferredSide: PolicyCanvasPortSide
  ) -> PolicyCanvasPortTerminal? {
    guard let terminal, terminal.side == preferredSide else {
      return nil
    }
    return terminal
  }

  private func effectiveTargetTerminal(
    _ terminal: PolicyCanvasPortTerminal?,
    preferredSide: PolicyCanvasPortSide?,
    fixedTargetSide: PolicyCanvasPortSide?
  ) -> PolicyCanvasPortTerminal? {
    guard let terminal else {
      return nil
    }
    guard fixedTargetSide == nil || fixedTargetSide == terminal.side else {
      return nil
    }
    guard preferredSide == nil || preferredSide == terminal.side else {
      return nil
    }
    return terminal
  }

  private func preferredFlexibleTargetSide(
    terminalSide: PolicyCanvasPortSide?,
    naturalSide: PolicyCanvasPortSide,
    targetFrame: CGRect?,
    corridorHint: PolicyCanvasEdgeCorridorHint?
  ) -> PolicyCanvasPortSide? {
    guard
      let terminalSide,
      let targetFrame,
      naturalSide == .leading || naturalSide == .trailing,
      terminalSide == .top || terminalSide == .bottom,
      let corridorHint,
      corridorHint.horizontalLaneY >= targetFrame.minY - 0.5,
      corridorHint.horizontalLaneY <= targetFrame.maxY + 0.5
    else {
      return nil
    }
    return naturalSide
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
    let terminalSlots = policyCanvasRouteEndpointSlots(edges: orderedEdges)
    let familyPreferences = policyCanvasRouteFamilyPreferences(
      edges: edges,
      nodeFramesByID: nodeIndex.mapValues(\.frame)
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

  private func policyCanvasConvergedRouteState(
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let passContext = prepared.displayedRoutePassContext(nodeIndex: nodeIndex)
    let initialRoutes = algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: selectedRouter,
        portMarkerLayout: nil,
        passContext: passContext
      )
    )
    var state = PolicyCanvasRouteComputationState(
      routes: initialRoutes,
      portMarkerLayout: algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: prepared,
          routes: initialRoutes,
          nodeIndex: nodeIndex
        )
      )
    )
    var seenLayouts: [PolicyCanvasPortMarkerLayout] = [state.portMarkerLayout]
    for _ in 0..<3 {
      let nextState = policyCanvasNextRouteState(
        current: state,
        prepared: prepared,
        nodeIndex: nodeIndex,
        passContext: passContext,
        router: selectedRouter,
        algorithms: algorithms
      )
      if nextState.portMarkerLayout == state.portMarkerLayout {
        return nextState
      }
      if seenLayouts.contains(nextState.portMarkerLayout) {
        return policyCanvasReroutedState(
          portMarkerLayout: nextState.portMarkerLayout,
          prepared: prepared,
          passContext: passContext,
          router: selectedRouter,
          algorithms: algorithms
        )
      }
      seenLayouts.append(nextState.portMarkerLayout)
      state = nextState
    }
    return policyCanvasReroutedState(
      portMarkerLayout: state.portMarkerLayout,
      prepared: prepared,
      passContext: passContext,
      router: selectedRouter,
      algorithms: algorithms
    )
  }

  private func policyCanvasNextRouteState(
    current: PolicyCanvasRouteComputationState,
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    passContext: PolicyCanvasDisplayedRoutePassContext,
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let routes = algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: selectedRouter,
        portMarkerLayout: current.portMarkerLayout,
        passContext: passContext
      )
    )
    return PolicyCanvasRouteComputationState(
      routes: routes,
      portMarkerLayout: algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: prepared,
          routes: routes,
          nodeIndex: nodeIndex
        )
      )
    )
  }

  private func policyCanvasReroutedState(
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    prepared: PolicyCanvasPreparedRouteInput,
    passContext: PolicyCanvasDisplayedRoutePassContext,
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    PolicyCanvasRouteComputationState(
      routes: algorithms.routeSelection.selectRoutes(
        input: PolicyCanvasRouteSelectionInput(
          prepared: prepared,
          router: selectedRouter,
          portMarkerLayout: portMarkerLayout,
          passContext: passContext
        )
      ),
      portMarkerLayout: portMarkerLayout
    )
  }

  private func routeAnchorCandidate(
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
      PolicyCanvasLayout.defaultEdgeLineSpacing + PolicyCanvasVisibilityRouter.channelStep
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
