import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  func displayedRoutes(
    router: any PolicyCanvasEdgeRouter,
    portMarkerLayout: PolicyCanvasPortMarkerLayout? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let nodeIndex = nodeIndex
    let obstacles = routingObstacles()
    let portAnchors = portAnchors(nodeIndex: nodeIndex)
    let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
    let terminalSlots = policyCanvasRouteEndpointSlots(edges: orderedEdges)
    let familyPreferences = policyCanvasRouteFamilyPreferences(edges: edges)
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
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    var previousRoutes: [PolicyCanvasDisplayedRouteClearance] = []
    routes.reserveCapacity(edges.count)
    previousRoutes.reserveCapacity(edges.count)
    for edge in orderedEdges {
      guard let source = portAnchors[edge.source], let target = portAnchors[edge.target] else {
        continue
      }
      let edgeTerminalSlots = terminalSlots[edge.id]
      let familyPreference = familyPreferences[edge.id, default: .none]
      let request = resolvedDisplayedRouteRequest(
        edge: PolicyCanvasDisplayedRouteEdgeContext(
          edge: edge,
          source: source,
          target: target,
          routeLane: edgeLanes[edge.id, default: 0],
          sourceFanoutLane: sourceFanoutLanes[edge.id, default: 0],
          targetFanoutLane: targetFanoutLanes[edge.id, default: 0],
          sourceTerminalSlot: edgeTerminalSlots?.source ?? .single,
          targetTerminalSlot: edgeTerminalSlots?.target ?? .single,
          familyPreference: familyPreference
        ),
        shared: PolicyCanvasDisplayedRouteSharedContext(
          portMarkerLayout: portMarkerLayout,
          nodeIndex: nodeIndex,
          obstacles: obstacles,
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
        )
      )
    }
    return routes
  }

  func policyCanvasCorridorKey(
    forRoute route: PolicyCanvasEdgeRoute,
    hint: PolicyCanvasEdgeCorridorHint?,
    lineSpacing: CGFloat
  ) -> PolicyCanvasRouteCorridorKey? {
    Self.policyCanvasCorridorKey(forRoute: route, hint: hint, lineSpacing: lineSpacing)
  }

  static func policyCanvasCorridorKey(
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
    let fixedSourceSide = edge.source.side
    let fixedTargetSide = edge.target.side ?? edgeContext.familyPreference.forcedTargetSide
    let effectiveSourceTerminal: PolicyCanvasPortTerminal? = {
      guard let sourceTerminal else {
        return nil
      }
      guard fixedSourceSide == nil || fixedSourceSide == sourceTerminal.side else {
        return nil
      }
      return sourceTerminal
    }()
    let effectiveTargetTerminal: PolicyCanvasPortTerminal? = {
      guard let targetTerminal else {
        return nil
      }
      guard
        fixedTargetSide == nil || fixedTargetSide == targetTerminal.side
      else {
        return nil
      }
      return targetTerminal
    }()
    let preferredSourceSide = fixedSourceSide ?? sourceTerminal?.side
    let preferredTargetSide = fixedTargetSide ?? targetTerminal?.side
    let resolvedSourceCandidates = policyCanvasPreferredRouteAnchorCandidates(
      routeAnchorCandidates(
        for: edge.source,
        nodeIndex: nodeIndex,
        terminalSlot: edgeContext.sourceTerminalSlot,
        terminal: effectiveSourceTerminal
      ),
      preferredSide: preferredSourceSide
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
    let sourceSide = preferredSourceSide ?? policyCanvasResolvedPortSide(for: edge.source)
    let targetSide = preferredTargetSide ?? policyCanvasResolvedPortSide(for: edge.target)
    let corridorHint = shared.routingHints?.edgeHint(for: edge.id)
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
        side: sourceSide,
        nodeIndex: nodeIndex,
        terminalSlot: edgeContext.sourceTerminalSlot,
        terminal: effectiveSourceTerminal
      ) ?? (point: edgeContext.source, side: sourceSide),
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

  private func routingObstacles() -> [CGRect] {
    nodes.map(\.frame) + policyCanvasGroupTitleFrames(groups)
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
