import OSLog
import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  func routesRebuildingCrossedPortTerminalFan(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    guard
      let group = crossedPortTerminalFanGroup(
        routes: routes,
        violations: violations,
        nodeID: nodeID,
        side: side,
        edgesByID: edgesByID
      )
    else {
      return routes
    }
    var repaired = routes
    for (index, edgeID) in group.edgeIDs.enumerated() {
      guard
        let point = group.terminalPoints[edgeID],
        let route = routes[edgeID]
      else {
        continue
      }
      let lead = policyCanvasPortLeadPoint(point, side: side)
      let coordinate = terminalFanChannelCoordinate(
        base: terminalChannelCoordinate(lead, side: side),
        index: index,
        count: group.edgeIDs.count,
        side: side,
        role: group.role
      )
      repaired[edgeID] = routeRebuildingTerminalFan(
        route,
        side: side,
        channelCoordinate: coordinate
      )
    }
    return repaired
  }

  func routesOrderingCrossedPortTerminalFanByFarAxis(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    guard
      let group = crossedPortTerminalFanGroup(
        routes: routes,
        violations: violations,
        nodeID: nodeID,
        side: side,
        edgesByID: edgesByID
      )
    else {
      return routes
    }
    let slotPoints = group.edgeIDs.compactMap { group.terminalPoints[$0] }
    guard slotPoints.count == group.edgeIDs.count else {
      return routes
    }
    let edgeIDsByFarAxis = group.edgeIDs.sorted { left, right in
      guard let leftRoute = routes[left], let rightRoute = routes[right] else {
        return left < right
      }
      let leftAxis = terminalFanFarAxis(leftRoute, role: group.role, side: side)
      let rightAxis = terminalFanFarAxis(rightRoute, role: group.role, side: side)
      if abs(leftAxis - rightAxis) > 0.001 {
        return leftAxis < rightAxis
      }
      let leftPoint = group.terminalPoints[left] ?? .zero
      let rightPoint = group.terminalPoints[right] ?? .zero
      let leftTerminalAxis = crossedPortAxis(leftPoint, side: side)
      let rightTerminalAxis = crossedPortAxis(rightPoint, side: side)
      return abs(leftTerminalAxis - rightTerminalAxis) > 0.001
        ? leftTerminalAxis < rightTerminalAxis : left < right
    }
    var repaired = routes
    for (index, edgeID) in edgeIDsByFarAxis.enumerated() {
      guard let route = repaired[edgeID] else {
        continue
      }
      let point = slotPoints[index]
      let moved = routeMovingTerminal(
        route,
        role: group.role,
        side: side,
        point: point
      )
      let lead = policyCanvasPortLeadPoint(point, side: side)
      let coordinate = terminalFanChannelCoordinate(
        base: terminalChannelCoordinate(lead, side: side),
        index: index,
        count: edgeIDsByFarAxis.count,
        side: side,
        role: group.role
      )
      repaired[edgeID] = routeRebuildingTerminalFan(
        moved,
        side: side,
        channelCoordinate: coordinate
      )
    }
    return repaired
  }

  func crossedPortTerminalFanGroup(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> PolicyCanvasCrossedPortTerminalFanGroup? {
    let violationEdgeIDs = Set(violations.flatMap { [$0.edgeA, $0.edgeB] })
    var terminalPoints: [String: CGPoint] = [:]
    var roles: [String: PolicyCanvasRouteEndpointRole] = [:]
    for edgeID in violationEdgeIDs {
      guard
        let edge = edgesByID[edgeID],
        let role = crossedPortRole(edge: edge, nodeID: nodeID),
        let route = routes[edgeID],
        let point = terminalFanTerminalPoint(route, role: role)
      else {
        return nil
      }
      roles[edgeID] = role
      terminalPoints[edgeID] = point
    }
    let edgeIDs = violationEdgeIDs.sorted { left, right in
      let leftPoint = terminalPoints[left] ?? .zero
      let rightPoint = terminalPoints[right] ?? .zero
      let leftAxis = crossedPortAxis(leftPoint, side: side)
      let rightAxis = crossedPortAxis(rightPoint, side: side)
      return abs(leftAxis - rightAxis) > 0.001 ? leftAxis < rightAxis : left < right
    }
    guard let groupRole = edgeIDs.first.flatMap({ roles[$0] }),
      edgeIDs.allSatisfy({ roles[$0] == groupRole })
    else {
      return nil
    }
    return PolicyCanvasCrossedPortTerminalFanGroup(
      edgeIDs: edgeIDs,
      terminalPoints: terminalPoints,
      role: groupRole
    )
  }

  func routesSwappingCrossedPortPairTerminalChannels(
    routes: [String: PolicyCanvasEdgeRoute],
    violation: PolicyCanvasCrossedPortsViolation,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    guard
      let edgeA = edgesByID[violation.edgeA],
      let edgeB = edgesByID[violation.edgeB],
      let roleA = crossedPortRole(edge: edgeA, nodeID: violation.nodeID),
      let roleB = crossedPortRole(edge: edgeB, nodeID: violation.nodeID),
      roleA == roleB,
      let routeA = routes[violation.edgeA],
      let routeB = routes[violation.edgeB],
      let channelA = terminalChannelCoordinate(
        routeA,
        role: roleA,
        side: violation.side
      ),
      let channelB = terminalChannelCoordinate(
        routeB,
        role: roleB,
        side: violation.side
      ),
      abs(channelA - channelB) > 0.5
    else {
      return routes
    }
    var repaired = routes
    repaired[violation.edgeA] = routeMovingTerminalChannel(
      routeA,
      role: roleA,
      side: violation.side,
      coordinate: channelB
    )
    repaired[violation.edgeB] = routeMovingTerminalChannel(
      routeB,
      role: roleB,
      side: violation.side,
      coordinate: channelA
    )
    return repaired
  }

  func routesSortingCrossedPortGroup(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    var terminalPoints: [String: CGPoint] = [:]
    var successors: [String: Set<String>] = [:]
    var predecessors: [String: Set<String>] = [:]
    for violation in violations {
      terminalPoints[violation.edgeA] = violation.pointA
      terminalPoints[violation.edgeB] = violation.pointB
      successors[violation.edgeB, default: []].insert(violation.edgeA)
      predecessors[violation.edgeA, default: []].insert(violation.edgeB)
    }
    let edgeIDs = terminalPoints.keys.sorted { left, right in
      let leftPoint = terminalPoints[left] ?? .zero
      let rightPoint = terminalPoints[right] ?? .zero
      let leftAxis = crossedPortAxis(leftPoint, side: side)
      let rightAxis = crossedPortAxis(rightPoint, side: side)
      return abs(leftAxis - rightAxis) > 0.001 ? leftAxis < rightAxis : left < right
    }
    let sortedEdgeIDs =
      topologicallySortedCrossedPortEdges(
        edgeIDs: edgeIDs,
        successors: successors,
        predecessors: predecessors
      )
      ?? fallbackSortedCrossedPortEdges(
        edgeIDs: edgeIDs,
        successors: successors,
        predecessors: predecessors
      )
    let sortedPoints = edgeIDs.compactMap { terminalPoints[$0] }
    guard sortedEdgeIDs.count == sortedPoints.count else {
      return routes
    }
    var repaired = routes
    for (edgeID, point) in zip(sortedEdgeIDs, sortedPoints) {
      guard
        let edge = edgesByID[edgeID],
        let role = crossedPortRole(edge: edge, nodeID: nodeID),
        let route = repaired[edgeID]
      else {
        continue
      }
      repaired[edgeID] = routeMovingTerminal(
        route,
        role: role,
        side: side,
        point: point
      )
    }
    return repaired
  }

  func topologicallySortedCrossedPortEdges(
    edgeIDs: [String],
    successors: [String: Set<String>],
    predecessors: [String: Set<String>]
  ) -> [String]? {
    let originalOrder = Dictionary(uniqueKeysWithValues: edgeIDs.enumerated().map { ($1, $0) })
    var incoming = Dictionary(
      uniqueKeysWithValues: edgeIDs.map { ($0, predecessors[$0, default: []].count) }
    )
    var ready = edgeIDs.filter { incoming[$0, default: 0] == 0 }
    var sorted: [String] = []
    while !ready.isEmpty {
      ready.sort { originalOrder[$0, default: 0] < originalOrder[$1, default: 0] }
      let edgeID = ready.removeFirst()
      sorted.append(edgeID)
      for next in successors[edgeID, default: []]
        .sorted(by: { originalOrder[$0, default: 0] < originalOrder[$1, default: 0] })
      {
        incoming[next, default: 0] -= 1
        if incoming[next, default: 0] == 0 {
          ready.append(next)
        }
      }
    }
    return sorted.count == edgeIDs.count ? sorted : nil
  }

  func fallbackSortedCrossedPortEdges(
    edgeIDs: [String],
    successors: [String: Set<String>],
    predecessors: [String: Set<String>]
  ) -> [String] {
    let originalOrder = Dictionary(uniqueKeysWithValues: edgeIDs.enumerated().map { ($1, $0) })
    return edgeIDs.sorted { left, right in
      let leftScore = predecessors[left, default: []].count - successors[left, default: []].count
      let rightScore =
        predecessors[right, default: []].count - successors[right, default: []].count
      return leftScore == rightScore
        ? originalOrder[left, default: 0] < originalOrder[right, default: 0]
        : leftScore < rightScore
    }
  }

  func crossedPortAxis(
    _ point: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .trailing:
      point.y
    case .top, .bottom:
      point.x
    }
  }

  func crossedPortGroupOrder(
    lhs: (
      key: PolicyCanvasCrossedPortGroupKey,
      value: [PolicyCanvasCrossedPortsViolation]
    ),
    rhs: (
      key: PolicyCanvasCrossedPortGroupKey,
      value: [PolicyCanvasCrossedPortsViolation]
    )
  ) -> Bool {
    if lhs.key.nodeID != rhs.key.nodeID {
      return lhs.key.nodeID < rhs.key.nodeID
    }
    return lhs.key.side.rawValue < rhs.key.side.rawValue
  }

  func crossedPortRole(
    edge: PolicyCanvasEdge,
    nodeID: String
  ) -> PolicyCanvasRouteEndpointRole? {
    if edge.source.nodeID == nodeID {
      return .source
    }
    if edge.target.nodeID == nodeID {
      return .target
    }
    return nil
  }
}
