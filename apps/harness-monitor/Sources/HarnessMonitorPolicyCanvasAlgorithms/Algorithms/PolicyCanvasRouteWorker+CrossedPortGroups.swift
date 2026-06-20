import OSLog
import SwiftUI

struct PolicyCanvasCrossedPortGroupKey: Hashable {
  let nodeID: String
  let side: PolicyCanvasPortSide
}

struct PolicyCanvasCrossedPortRepairCandidate {
  let routes: [String: PolicyCanvasEdgeRoute]
  let violations: [PolicyCanvasCrossedPortsViolation]
}

struct PolicyCanvasCrossedPortRepairContext {
  let nodeIndex: [String: PolicyCanvasRouteNode]
  let maximumBodyHits: Int
  let maximumTerminalSideMismatches: Int
  let router: any PolicyCanvasEdgeRouter
  let algorithms: PolicyCanvasRoutingAlgorithmSet
  /// Built once per repair pass and reused by every candidate's body-hit
  /// re-route. It derives only from the node index (obstacles, port anchors,
  /// terminal slots, lane assignments), which is constant across the pass, so
  /// rebuilding it per candidate was pure waste.
  let passContext: PolicyCanvasDisplayedRoutePassContext
}

struct PolicyCanvasCrossedPortTerminalFanGroup {
  let edgeIDs: [String]
  let terminalPoints: [String: CGPoint]
  let role: PolicyCanvasRouteEndpointRole
}

extension PolicyCanvasPreparedRouteInput {
  func precomputedBodyHitEdgeIDs(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Set<String> {
    Set(
      precomputedBodyHits(routes: routes, nodeIndex: nodeIndex)
        .map(\.edgeID)
    )
  }

  func precomputedBodyHits(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasBodyHitViolation] {
    policyCanvasMeasureBodyHits(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      groupTitleFrames: policyCanvasGroupTitleFramesByID(groups)
    )
  }

  func precomputedBodyHits(
    edge: PolicyCanvasEdge,
    route: PolicyCanvasEdgeRoute,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasBodyHitViolation] {
    policyCanvasMeasureBodyHits(
      routedEdges: [PolicyCanvasRoutedEdge(edge: edge, route: route)],
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      groupTitleFrames: policyCanvasGroupTitleFramesByID(groups)
    )
  }

  func precomputedTerminalSideMismatchCount(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> Int {
    var count = 0
    for edge in edges {
      guard let route = routes[edge.id] else {
        continue
      }
      if policyCanvasRouteSourceSide(route) != policyCanvasResolvedPortSide(for: edge.source) {
        count += 1
      }
      if policyCanvasRouteTargetSide(route) != policyCanvasResolvedPortSide(for: edge.target) {
        count += 1
      }
    }
    return count
  }

  func precomputedCrossedPortViolations(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasCrossedPortsViolation] {
    policyCanvasMeasureCrossedPorts(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame)
    )
  }

  func precomputedRoutedEdges(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [PolicyCanvasRoutedEdge] {
    edges.compactMap { edge -> PolicyCanvasRoutedEdge? in
      guard let route = routes[edge.id], route.points.count >= 2 else {
        return nil
      }
      return PolicyCanvasRoutedEdge(edge: edge, route: route)
    }
  }

  func routesSwappingCrossedPortPairs(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation]
  ) -> [String: PolicyCanvasEdgeRoute] {
    let edgesByID = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var repaired = routes
    let groupedViolations = Dictionary(grouping: violations) {
      PolicyCanvasCrossedPortGroupKey(nodeID: $0.nodeID, side: $0.side)
    }
    for (key, group) in groupedViolations.sorted(by: crossedPortGroupOrder) {
      repaired = routesSortingCrossedPortTerminalChannels(
        routes: repaired,
        violations: group,
        nodeID: key.nodeID,
        side: key.side,
        edgesByID: edgesByID
      )
    }
    return repaired
  }

  func routesSortingCrossedPortTerminalChannels(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    var terminalPoints: [String: CGPoint] = [:]
    for violation in violations {
      terminalPoints[violation.edgeA] = violation.pointA
      terminalPoints[violation.edgeB] = violation.pointB
    }
    let edgeIDs = terminalPoints.keys.sorted { left, right in
      let leftPoint = terminalPoints[left] ?? .zero
      let rightPoint = terminalPoints[right] ?? .zero
      let leftAxis = crossedPortAxis(leftPoint, side: side)
      let rightAxis = crossedPortAxis(rightPoint, side: side)
      return abs(leftAxis - rightAxis) > 0.001 ? leftAxis < rightAxis : left < right
    }
    var channelCoordinates: [String: CGFloat] = [:]
    var roles: [String: PolicyCanvasRouteEndpointRole] = [:]
    for edgeID in edgeIDs {
      guard
        let edge = edgesByID[edgeID],
        let role = crossedPortRole(edge: edge, nodeID: nodeID),
        let route = routes[edgeID],
        let coordinate = terminalChannelCoordinate(route, role: role, side: side)
      else {
        return routes
      }
      roles[edgeID] = role
      channelCoordinates[edgeID] = coordinate
    }
    guard let groupRole = edgeIDs.first.flatMap({ roles[$0] }),
      edgeIDs.allSatisfy({ roles[$0] == groupRole })
    else {
      return routes
    }
    let sortedCoordinates =
      edgeIDs
      .compactMap { channelCoordinates[$0] }
      .sorted { left, right in
        let leftRank = terminalChannelOutwardRank(left, side: side)
        let rightRank = terminalChannelOutwardRank(right, side: side)
        return leftRank > rightRank
      }
    guard sortedCoordinates.count == edgeIDs.count else {
      return routes
    }
    let assignedCoordinates = terminalChannelCoordinatesResolvingCrowding(
      sortedCoordinates,
      side: side,
      role: groupRole
    )
    var repaired = routes
    for (edgeID, coordinate) in zip(edgeIDs, assignedCoordinates) {
      guard
        let edge = edgesByID[edgeID],
        let role = crossedPortRole(edge: edge, nodeID: nodeID),
        let route = repaired[edgeID]
      else {
        continue
      }
      repaired[edgeID] = routeMovingTerminalChannel(
        route,
        role: role,
        side: side,
        coordinate: coordinate
      )
    }
    return repaired
  }

  func terminalChannelCoordinatesResolvingCrowding(
    _ coordinates: [CGFloat],
    side: PolicyCanvasPortSide,
    role: PolicyCanvasRouteEndpointRole
  ) -> [CGFloat] {
    guard coordinates.count > 1 else {
      return coordinates
    }
    let minimumSpacing = PolicyCanvasLayout.routeChannelStep
    let hasCrowding = zip(coordinates, coordinates.dropFirst()).contains { left, right in
      abs(right - left) < minimumSpacing - 0.001
    }
    guard hasCrowding else {
      return coordinates
    }
    let base: CGFloat
    switch side {
    case .leading, .top:
      base = coordinates.max() ?? 0
    case .trailing, .bottom:
      base = coordinates.min() ?? 0
    }
    return coordinates.indices.map { index in
      terminalFanChannelCoordinate(
        base: base,
        index: index,
        count: coordinates.count,
        side: side,
        role: role
      )
    }
  }
}
