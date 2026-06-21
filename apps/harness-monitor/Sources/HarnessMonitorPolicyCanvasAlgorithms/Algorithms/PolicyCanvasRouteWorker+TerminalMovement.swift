import OSLog
import SwiftUI

struct PolicyCanvasTerminalRepairContext {
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
  let nodeIndex: [String: PolicyCanvasRouteNode]
}

struct PolicyCanvasTerminalSnapState {
  var score: Int
  var bodyHits: Int
}

struct PolicyCanvasTerminalMismatchInput {
  let edgeID: String
  let role: PolicyCanvasRouteEndpointRole
  let endpoint: PolicyCanvasPortEndpoint
  let routePoint: CGPoint?
  let leadPoint: CGPoint?
  let routeSide: PolicyCanvasPortSide?
}

extension PolicyCanvasPreparedRouteInput {
  func routeMovingTerminal(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    point: CGPoint
  ) -> PolicyCanvasEdgeRoute {
    guard route.points.count >= 2 else {
      return route
    }
    let lead = policyCanvasPortLeadPoint(point, side: side)
    var points: [CGPoint] = []
    switch role {
    case .source:
      let oldLead = route.points[1]
      var tracksSourceRun = true
      policyCanvasAppendOrthogonalBridge(point, to: &points)
      policyCanvasAppendOrthogonalBridge(lead, to: &points)
      for index in 2..<route.points.count {
        var oldPoint = route.points[index]
        if tracksSourceRun, index < route.points.count - 2,
          terminalRunPoint(oldPoint, sharesAxisWith: oldLead, side: side)
        {
          oldPoint = pointReplacingTerminalAxis(oldPoint, with: lead, side: side)
        } else if index < route.points.count - 2 {
          tracksSourceRun = false
        }
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
    case .target:
      let oldLead = route.points[route.points.count - 2]
      let adjustedPoints = pointsAdjustingTargetTerminalRun(
        route.points,
        oldLead: oldLead,
        newLead: lead,
        side: side
      )
      for oldPoint in adjustedPoints.dropLast(2) {
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
      policyCanvasAppendOrthogonalBridge(lead, to: &points)
      policyCanvasAppendOrthogonalBridge(point, to: &points)
    }
    let compressed = policyCanvasCompressPreservingTerminalStubs(points)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  func pointsAdjustingTargetTerminalRun(
    _ points: [CGPoint],
    oldLead: CGPoint,
    newLead: CGPoint,
    side: PolicyCanvasPortSide
  ) -> [CGPoint] {
    guard points.count > 4 else {
      return points
    }
    var adjusted = points
    var index = points.count - 3
    while index >= 2,
      terminalRunPoint(adjusted[index], sharesAxisWith: oldLead, side: side)
    {
      adjusted[index] = pointReplacingTerminalAxis(adjusted[index], with: newLead, side: side)
      index -= 1
    }
    return adjusted
  }

  func terminalRunPoint(
    _ point: CGPoint,
    sharesAxisWith lead: CGPoint,
    side: PolicyCanvasPortSide
  ) -> Bool {
    switch side {
    case .leading, .trailing:
      return abs(point.y - lead.y) <= 0.001
    case .top, .bottom:
      return abs(point.x - lead.x) <= 0.001
    }
  }

  func pointReplacingTerminalAxis(
    _ point: CGPoint,
    with lead: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGPoint {
    switch side {
    case .leading, .trailing:
      return CGPoint(x: point.x, y: lead.y)
    case .top, .bottom:
      return CGPoint(x: lead.x, y: point.y)
    }
  }

  func terminalChannelCoordinate(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide
  ) -> CGFloat? {
    guard
      let indexes = terminalChannelSegmentIndexes(route.points, role: role, side: side)
    else {
      return nil
    }
    return terminalChannelCoordinate(route.points[indexes.lower], side: side)
  }

  func terminalChannelSegmentIndexes(
    _ points: [CGPoint],
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide
  ) -> (lower: Int, upper: Int)? {
    guard points.count >= 3 else {
      return nil
    }
    switch role {
    case .source:
      for index in 2..<points.count
      where terminalChannelSegment(points[index - 1], points[index], side: side) {
        return (index - 1, index)
      }
    case .target:
      var index = points.count - 2
      while index >= 1 {
        if terminalChannelSegment(points[index - 1], points[index], side: side) {
          return (index - 1, index)
        }
        index -= 1
      }
    }
    return nil
  }

  func terminalChannelSegment(
    _ start: CGPoint,
    _ end: CGPoint,
    side: PolicyCanvasPortSide
  ) -> Bool {
    switch side {
    case .leading, .trailing:
      return abs(start.x - end.x) <= 0.5 && abs(start.y - end.y) > 0.5
    case .top, .bottom:
      return abs(start.y - end.y) <= 0.5 && abs(start.x - end.x) > 0.5
    }
  }

  func terminalChannelCoordinate(
    _ point: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .trailing:
      return point.x
    case .top, .bottom:
      return point.y
    }
  }

  func terminalChannelOutwardRank(
    _ coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .top:
      return -coordinate
    case .trailing, .bottom:
      return coordinate
    }
  }

  func terminalFanChannelCoordinate(
    base: CGFloat,
    index: Int,
    count: Int,
    side: PolicyCanvasPortSide,
    role: PolicyCanvasRouteEndpointRole
  ) -> CGFloat {
    let ordinal: CGFloat =
      switch role {
      case .source:
        CGFloat(index)
      case .target:
        CGFloat(max(0, count - index - 1))
      }
    return base
      + (terminalFanOutwardDirection(side) * ordinal * PolicyCanvasLayout.routeChannelStep)
  }

  func terminalFanOutwardDirection(_ side: PolicyCanvasPortSide) -> CGFloat {
    switch side {
    case .leading, .top:
      -1
    case .trailing, .bottom:
      1
    }
  }

  func terminalFanTerminalPoint(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole
  ) -> CGPoint? {
    switch role {
    case .source:
      route.points.first
    case .target:
      route.points.last
    }
  }

  func terminalFanFarAxis(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    let point: CGPoint?
    switch role {
    case .source:
      point = route.points.last
    case .target:
      point = route.points.first
    }
    return point.map { crossedPortAxis($0, side: side) } ?? 0
  }

  /// Extend each route terminal inward to its rendered port dot so the wire
  /// visibly reaches the node edge. A precomputed route can terminate one routing
  /// channel outward from the node - on the semantic side and at the port's
  /// along-side coordinate, but offset on the perpendicular axis (x for a trailing
  /// port). The canvas draws the dot at the node edge, so the wire ends short of
  /// it. The marker axis offset only captures the along-side delta, so it cannot
  /// close this gap; this pass prepends/appends the node-edge anchor - a pure
  /// outward stub at the port's along-side coordinate - applied only when it adds
  /// no node-body crossing. The full terminal move (`routeMovingTerminal`) rewrites
  /// the interior run and trips the body-hit guard; the minimal stub does not.
  func routesReachingRenderedPorts(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    affectedEdgeIDs: Set<String>? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let markerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex,
      usesDeclarationOrderAnchor: true
    )
    var reached = routes
    for edge in edges where policyCanvasEdgeInRepairScope(edge.id, affectedEdgeIDs) {
      guard let original = reached[edge.id] else {
        continue
      }
      var route = original
      for role in [PolicyCanvasRouteEndpointRole.source, .target] {
        guard
          let dot = renderedPortDot(
            edgeID: edge.id,
            role: role,
            endpoint: role == .source ? edge.source : edge.target,
            markerLayout: markerLayout,
            nodeIndex: nodeIndex
          ),
          let candidate = routeReachingTerminal(route, role: role, dot: dot),
          precomputedBodyHits(edge: edge, route: candidate, nodeIndex: nodeIndex).count
            <= precomputedBodyHits(edge: edge, route: route, nodeIndex: nodeIndex).count
        else {
          continue
        }
        route = candidate
      }
      if route != original {
        reached[edge.id] = route
      }
    }
    return reached
  }

  private func renderedPortDot(
    edgeID: String,
    role: PolicyCanvasRouteEndpointRole,
    endpoint: PolicyCanvasPortEndpoint,
    markerLayout: PolicyCanvasPortMarkerLayout,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> (point: CGPoint, side: PolicyCanvasPortSide)? {
    guard
      let terminal = markerLayout.terminal(edgeID: edgeID, role: role),
      let base = declarationPortAnchor(for: endpoint, side: terminal.side, nodeIndex: nodeIndex)
    else {
      return nil
    }
    return (
      policyCanvasShiftedRouteAnchor(base, side: terminal.side, terminal: terminal),
      terminal.side
    )
  }

  private func routeReachingTerminal(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    dot: (point: CGPoint, side: PolicyCanvasPortSide)
  ) -> PolicyCanvasEdgeRoute? {
    guard
      route.points.count >= 2,
      let terminalPoint = role == .source ? route.points.first : route.points.last
    else {
      return nil
    }
    let routeSide =
      role == .source
      ? policyCanvasRouteSourceSide(route) : policyCanvasRouteTargetSide(route)
    // Reach only when the wire already exits on the rendered side at the port's
    // along-side coordinate; a different side or a different row is a routing
    // mismatch other passes own, not a stub the marker offset describes.
    guard routeSide == dot.side else {
      return nil
    }
    let alongMatches: Bool
    let perpendicularGap: CGFloat
    switch dot.side {
    case .leading, .trailing:
      alongMatches = abs(terminalPoint.y - dot.point.y) <= 0.5
      perpendicularGap = abs(terminalPoint.x - dot.point.x)
    case .top, .bottom:
      alongMatches = abs(terminalPoint.x - dot.point.x) <= 0.5
      perpendicularGap = abs(terminalPoint.y - dot.point.y)
    }
    guard alongMatches, perpendicularGap > 0.5 else {
      return nil
    }
    var points = route.points
    switch role {
    case .source:
      points.insert(dot.point, at: 0)
    case .target:
      points.append(dot.point)
    }
    let compressed = policyCanvasCompressPreservingTerminalStubs(points)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }
}
