import OSLog
import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  func precomputedRoutesNormalizingTerminalStubs(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    portMarkerLayout explicitLayout: PolicyCanvasPortMarkerLayout? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let markerLayout =
      explicitLayout
      ?? precomputedRouteTerminalPortMarkerLayout(routes: routes, nodeIndex: nodeIndex)
    let context = PolicyCanvasTerminalRepairContext(
      portMarkerLayout: markerLayout,
      nodeIndex: nodeIndex
    )
    var normalized = routes
    for edge in edges {
      guard var route = normalized[edge.id] else {
        continue
      }
      let currentScore = precomputedRouteTerminalMismatchScore(
        edge: edge,
        route: route,
        portMarkerLayout: markerLayout,
        nodeIndex: nodeIndex
      )
      guard currentScore > 0 else {
        continue
      }
      let currentBodyHits = precomputedBodyHits(
        edge: edge,
        route: route,
        nodeIndex: nodeIndex
      ).count
      var state = PolicyCanvasTerminalSnapState(
        score: currentScore,
        bodyHits: currentBodyHits
      )
      for role in [PolicyCanvasRouteEndpointRole.source, .target] {
        var candidateState = state
        let candidate = routeAcceptingTerminalSnap(
          edge: edge,
          route: route,
          role: role,
          context: context,
          state: &candidateState
        )
        guard candidate != route else {
          continue
        }
        route = candidate
        state = candidateState
        normalized[edge.id] = route
      }
    }
    return normalized
  }

  func routeAcceptingTerminalSnap(
    edge: PolicyCanvasEdge,
    route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    context: PolicyCanvasTerminalRepairContext,
    state: inout PolicyCanvasTerminalSnapState
  ) -> PolicyCanvasEdgeRoute {
    let endpoint = role == .source ? edge.source : edge.target
    guard
      let markerPoint = portMarkerPoint(
        edgeID: edge.id,
        role: role,
        endpoint: endpoint,
        portMarkerLayout: context.portMarkerLayout,
        nodeIndex: context.nodeIndex
      )
    else {
      return route
    }
    let candidate = routeMovingTerminal(
      route,
      role: role,
      side: markerPoint.side,
      point: markerPoint.point
    )
    let score = precomputedRouteTerminalMismatchScore(
      edge: edge,
      route: candidate,
      portMarkerLayout: context.portMarkerLayout,
      nodeIndex: context.nodeIndex
    )
    guard score < state.score else {
      return route
    }
    let hitCount = precomputedBodyHits(
      edge: edge,
      route: candidate,
      nodeIndex: context.nodeIndex
    ).count
    guard hitCount <= state.bodyHits else {
      return route
    }
    state.score = score
    state.bodyHits = hitCount
    return candidate
  }

  func routesRestoringTerminalLeadSides(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    preservingInterior: Bool = false
  ) -> [String: PolicyCanvasEdgeRoute] {
    var repaired = routes
    let markerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex
    )
    for edge in edges {
      guard var route = repaired[edge.id] else {
        continue
      }
      if let sourcePoint = portMarkerPoint(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        portMarkerLayout: markerLayout,
        nodeIndex: nodeIndex
      ) {
        route = routeRestoringTerminalLeadSide(
          route,
          role: .source,
          side: sourcePoint.side,
          point: sourcePoint.point,
          preservingInterior: preservingInterior
        )
      }
      if let targetPoint = portMarkerPoint(
        edgeID: edge.id,
        role: .target,
        endpoint: edge.target,
        portMarkerLayout: markerLayout,
        nodeIndex: nodeIndex
      ) {
        route = routeRestoringTerminalLeadSide(
          route,
          role: .target,
          side: targetPoint.side,
          point: targetPoint.point,
          preservingInterior: preservingInterior
        )
      }
      repaired[edge.id] = route
    }
    return repaired
  }

  func routeRestoringTerminalLeadSide(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    point: CGPoint,
    preservingInterior: Bool
  ) -> PolicyCanvasEdgeRoute {
    if preservingInterior {
      return routeRestoringTerminalStubOnly(route, role: role, side: side, point: point)
    }
    return routeMovingTerminal(route, role: role, side: side, point: point)
  }

  func routeRestoringTerminalStubOnly(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    point: CGPoint
  ) -> PolicyCanvasEdgeRoute {
    guard route.points.count >= 2 else {
      return route
    }
    let currentSide =
      switch role {
      case .source: policyCanvasRouteSourceSide(route)
      case .target: policyCanvasRouteTargetSide(route)
      }
    guard currentSide != side else {
      return route
    }
    let lead = policyCanvasPortLeadPoint(point, side: side)
    var points: [CGPoint] = []
    switch role {
    case .source:
      policyCanvasAppendOrthogonalBridge(point, to: &points)
      policyCanvasAppendOrthogonalBridge(lead, to: &points)
      for oldPoint in route.points.dropFirst() {
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
    case .target:
      for oldPoint in route.points.dropLast() {
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
      while let last = points.last, last == point || last == lead {
        points.removeLast()
      }
      policyCanvasAppendOrthogonalBridgePreservingCurrentLane(lead, to: &points)
      policyCanvasAppendOrthogonalBridge(point, to: &points)
    }
    let compressed = policyCanvasCompressPreservingTerminalStubs(points)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  func policyCanvasAppendOrthogonalBridgePreservingCurrentLane(
    _ point: CGPoint,
    to points: inout [CGPoint]
  ) {
    guard let last = points.last else {
      points.append(point)
      return
    }
    if abs(last.x - point.x) > 0.001, abs(last.y - point.y) > 0.001 {
      points.append(CGPoint(x: last.x, y: point.y))
    }
    if points.last != point {
      points.append(point)
    }
  }

  func precomputedRouteTerminalMismatchScore(
    edge: PolicyCanvasEdge,
    route: PolicyCanvasEdgeRoute,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Int {
    let context = PolicyCanvasTerminalRepairContext(
      portMarkerLayout: portMarkerLayout,
      nodeIndex: nodeIndex
    )
    return precomputedRouteTerminalMismatchScore(
      PolicyCanvasTerminalMismatchInput(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        routePoint: route.points.first,
        leadPoint: route.points.dropFirst().first,
        routeSide: policyCanvasRouteSourceSide(route)
      ),
      context: context
    )
      + precomputedRouteTerminalMismatchScore(
        PolicyCanvasTerminalMismatchInput(
          edgeID: edge.id,
          role: .target,
          endpoint: edge.target,
          routePoint: route.points.last,
          leadPoint: route.points.dropLast().last,
          routeSide: policyCanvasRouteTargetSide(route)
        ),
        context: context
      )
  }

  func precomputedRouteTerminalMismatchScore(
    _ input: PolicyCanvasTerminalMismatchInput,
    context: PolicyCanvasTerminalRepairContext
  ) -> Int {
    guard
      let markerPoint = portMarkerPoint(
        edgeID: input.edgeID,
        role: input.role,
        endpoint: input.endpoint,
        portMarkerLayout: context.portMarkerLayout,
        nodeIndex: context.nodeIndex
      )
    else {
      return 0
    }
    var score = 0
    if input.routeSide != markerPoint.side {
      score += 10_000
    }
    guard let routePoint = input.routePoint else {
      return score + 10_000
    }
    let distance =
      abs(routePoint.x - markerPoint.point.x)
      + abs(routePoint.y - markerPoint.point.y)
    if distance > 0.5 {
      score += Int(ceil(distance * 10))
    }
    let expectedLead = policyCanvasPortLeadPoint(markerPoint.point, side: markerPoint.side)
    if let leadPoint = input.leadPoint {
      let leadDistance = abs(leadPoint.x - expectedLead.x) + abs(leadPoint.y - expectedLead.y)
      if leadDistance > 0.5 {
        score += Int(ceil(leadDistance * 10))
      }
    } else {
      score += 10_000
    }
    return score
  }
}
