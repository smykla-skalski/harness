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
    let sourceFanoutLanes = policyCanvasSourceFanoutLaneAssignments(
      edges: edges,
      familyPreferences: familyPreferences,
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
          familyPreference: familyPreferences[edge.id, default: .none]
        ),
        shared: PolicyCanvasDisplayedRouteSharedContext(
          portMarkerLayout: portMarkerLayout,
          nodeIndex: nodeIndex,
          obstacles: obstacles,
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
          route: route,
          minimumSpacing: policyCanvasRouteMinimumSpacing(request: request, route: route)
        )
      )
    }
    return routes
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
    let familyPreferredSourceSide = policyCanvasPreferredFamilySourceSide(
    edge: edge,
    familyPreference: edgeContext.familyPreference,
    source: edgeContext.source,
    target: edgeContext.target
    )
    let fixedSourceSide = edge.source.side ?? familyPreferredSourceSide
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
      targetSpacingBySide: portSpacingBySide(for: edge.target, nodeIndex: nodeIndex)
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

  private func edgeLaneSortKey(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    let sourceAnchor = portAnchor(for: edge.source, nodeIndex: nodeIndex) ?? .zero
    let targetAnchor = portAnchor(for: edge.target, nodeIndex: nodeIndex) ?? .zero
    return [
      edgeRouteBucket(edge, nodeIndex: nodeIndex),
      String(Int(sourceAnchor.y.rounded())),
      String(Int(targetAnchor.y.rounded())),
      String(Int(targetAnchor.x.rounded())),
      edge.source.portID,
      edge.target.nodeID,
      edge.target.portID,
    ].joined(separator: "|")
  }

  private func edgeRouteBucket(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    let sourceSide = policyCanvasResolvedPortSide(for: edge.source).rawValue
    let targetSide = policyCanvasResolvedPortSide(for: edge.target).rawValue
    let targetScope = nodeIndex[edge.target.nodeID]?.groupID ?? edge.target.nodeID
    return "\(edge.source.nodeID)|\(sourceSide)->\(targetScope)|\(targetSide)"
  }

  private func edgeRouteSortKey(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    edgeLaneSortKey(edge, nodeIndex: nodeIndex)
  }

  private func edgeSourceFanoutBucket(_ edge: PolicyCanvasEdge) -> String {
    let side = policyCanvasResolvedPortSide(for: edge.source).rawValue
    return "\(edge.source.nodeID)|\(side)"
  }

  private func edgeTargetFanoutBucket(_ edge: PolicyCanvasEdge) -> String {
    let side = policyCanvasResolvedPortSide(for: edge.target).rawValue
    return "\(edge.target.nodeID)|\(side)"
  }

  private func edgeSourceFanoutSortKey(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    fanoutSortKey(
      bucket: edgeSourceFanoutBucket(edge),
      anchor: portAnchor(for: edge.target, nodeIndex: nodeIndex) ?? .zero,
      nodeID: edge.target.nodeID,
      portID: edge.target.portID
    )
  }

  private func edgeTargetFanoutSortKey(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    fanoutSortKey(
      bucket: edgeTargetFanoutBucket(edge),
      anchor: portAnchor(for: edge.source, nodeIndex: nodeIndex) ?? .zero,
      nodeID: edge.source.nodeID,
      portID: edge.source.portID
    )
  }

  private func fanoutSortKey(
    bucket: String,
    anchor: CGPoint,
    nodeID: String,
    portID: String
  ) -> String {
    [bucket, String(Int(anchor.y.rounded())), String(Int(anchor.x.rounded())), nodeID, portID]
      .joined(separator: "|")
  }

  private func edgeLineSpacing(
    for edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGFloat {
    max(
      portSpacing(for: edge.source, nodeIndex: nodeIndex),
      portSpacing(for: edge.target, nodeIndex: nodeIndex)
    )
  }

  private func portSpacingBySide(
    for endpoint: PolicyCanvasPortEndpoint,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasPortSide: CGFloat] {
    Dictionary(
      uniqueKeysWithValues: PolicyCanvasPortSide.allSides.map { side in
        (side, portSpacing(for: endpoint, side: side, nodeIndex: nodeIndex))
      })
  }

  func portSpacing(
    for endpoint: PolicyCanvasPortEndpoint,
    side overrideSide: PolicyCanvasPortSide? = nil,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGFloat {
    guard let node = nodeIndex[endpoint.nodeID] else {
      return PolicyCanvasLayout.defaultEdgeLineSpacing
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard ports.count > 1 else {
      return PolicyCanvasLayout.defaultEdgeLineSpacing
    }
    let side = overrideSide ?? policyCanvasResolvedPortSide(for: endpoint)
    switch side {
    case .leading, .trailing:
      return abs(
        PolicyCanvasLayout.portY(index: 1, count: ports.count)
          - PolicyCanvasLayout.portY(index: 0, count: ports.count)
      )
    case .top, .bottom:
      return abs(
        PolicyCanvasLayout.portX(index: 1, count: ports.count)
          - PolicyCanvasLayout.portX(index: 0, count: ports.count)
      )
    }
  }
}
