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
}
