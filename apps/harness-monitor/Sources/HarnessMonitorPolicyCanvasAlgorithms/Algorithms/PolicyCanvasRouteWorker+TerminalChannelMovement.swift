import OSLog
import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  func routeMovingTerminalChannel(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    coordinate: CGFloat
  ) -> PolicyCanvasEdgeRoute {
    guard
      let indexes = terminalChannelSegmentIndexes(route.points, role: role, side: side)
    else {
      return route
    }
    let points = route.points
    let oldCoordinate = terminalChannelCoordinate(points[indexes.lower], side: side)
    let rebuilt =
      switch role {
      case .source:
        pointsMovingSourceTerminalChannel(
          points,
          indexes: indexes,
          oldCoordinate: oldCoordinate,
          coordinate: coordinate,
          side: side
        )
      case .target:
        pointsMovingTargetTerminalChannel(
          points,
          indexes: indexes,
          oldCoordinate: oldCoordinate,
          coordinate: coordinate,
          side: side
        )
      }
    let compressed = policyCanvasCompressPreservingTerminalStubs(rebuilt)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  func pointsMovingSourceTerminalChannel(
    _ points: [CGPoint],
    indexes: (lower: Int, upper: Int),
    oldCoordinate: CGFloat,
    coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> [CGPoint] {
    var rebuilt: [CGPoint] = []
    var index = indexes.lower
    policyCanvasAppendOrthogonalBridge(points[0], to: &rebuilt)
    policyCanvasAppendOrthogonalBridge(points[1], to: &rebuilt)
    while index < points.count - 1,
      terminalChannelPoint(points[index], coordinate: oldCoordinate, side: side)
    {
      let adjusted = pointReplacingTerminalChannel(points[index], with: coordinate, side: side)
      policyCanvasAppendOrthogonalBridge(adjusted, to: &rebuilt)
      index += 1
    }
    while index < points.count {
      policyCanvasAppendOrthogonalBridge(points[index], to: &rebuilt)
      index += 1
    }
    return rebuilt
  }

  func pointsMovingTargetTerminalChannel(
    _ points: [CGPoint],
    indexes: (lower: Int, upper: Int),
    oldCoordinate: CGFloat,
    coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> [CGPoint] {
    var runStart = indexes.lower
    while runStart > 1,
      terminalChannelPoint(points[runStart - 1], coordinate: oldCoordinate, side: side)
    {
      runStart -= 1
    }
    var runEnd = indexes.upper
    while runEnd < points.count - 3,
      terminalChannelPoint(points[runEnd + 1], coordinate: oldCoordinate, side: side)
    {
      runEnd += 1
    }
    let adjustedEnd = min(runEnd, points.count - 3)
    var rebuilt: [CGPoint] = []
    var index = 0
    while index < runStart {
      policyCanvasAppendOrthogonalBridge(points[index], to: &rebuilt)
      index += 1
    }
    while index <= adjustedEnd {
      let adjusted = pointReplacingTerminalChannel(points[index], with: coordinate, side: side)
      policyCanvasAppendOrthogonalBridge(adjusted, to: &rebuilt)
      index += 1
    }
    var exitsMovedChannel =
      rebuilt.last.map {
        terminalChannelPoint($0, coordinate: coordinate, side: side)
      } ?? false
    while index < points.count {
      if exitsMovedChannel {
        policyCanvasAppendTerminalChannelExitBridge(
          points[index],
          channelCoordinate: coordinate,
          side: side,
          to: &rebuilt
        )
        exitsMovedChannel = false
      } else {
        policyCanvasAppendOrthogonalBridge(points[index], to: &rebuilt)
      }
      index += 1
    }
    return rebuilt
  }

  func terminalChannelPoint(
    _ point: CGPoint,
    coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> Bool {
    abs(terminalChannelCoordinate(point, side: side) - coordinate) <= 0.5
  }

  func pointReplacingTerminalChannel(
    _ point: CGPoint,
    with coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> CGPoint {
    switch side {
    case .leading, .trailing:
      return CGPoint(x: coordinate, y: point.y)
    case .top, .bottom:
      return CGPoint(x: point.x, y: coordinate)
    }
  }

  func routeRebuildingTerminalFan(
    _ route: PolicyCanvasEdgeRoute,
    side: PolicyCanvasPortSide,
    channelCoordinate: CGFloat
  ) -> PolicyCanvasEdgeRoute {
    guard route.points.count >= 4,
      let sourcePoint = route.points.first,
      let targetPoint = route.points.last
    else {
      return route
    }
    let sourceLead = route.points[1]
    let targetLead = route.points[route.points.count - 2]
    var rebuilt: [CGPoint] = []
    policyCanvasAppendOrthogonalBridge(sourcePoint, to: &rebuilt)
    policyCanvasAppendOrthogonalBridge(sourceLead, to: &rebuilt)
    switch side {
    case .leading, .trailing:
      policyCanvasAppendOrthogonalBridge(
        CGPoint(x: channelCoordinate, y: sourceLead.y),
        to: &rebuilt
      )
      policyCanvasAppendOrthogonalBridge(
        CGPoint(x: channelCoordinate, y: targetLead.y),
        to: &rebuilt
      )
    case .top, .bottom:
      policyCanvasAppendOrthogonalBridge(
        CGPoint(x: sourceLead.x, y: channelCoordinate),
        to: &rebuilt
      )
      policyCanvasAppendOrthogonalBridge(
        CGPoint(x: targetLead.x, y: channelCoordinate),
        to: &rebuilt
      )
    }
    policyCanvasAppendOrthogonalBridge(targetLead, to: &rebuilt)
    policyCanvasAppendOrthogonalBridge(targetPoint, to: &rebuilt)
    let compressed = policyCanvasCompressPreservingTerminalStubs(rebuilt)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  func policyCanvasAppendTerminalChannelExitBridge(
    _ point: CGPoint,
    channelCoordinate: CGFloat,
    side: PolicyCanvasPortSide,
    to points: inout [CGPoint]
  ) {
    guard let last = points.last,
      abs(last.x - point.x) > 0.001,
      abs(last.y - point.y) > 0.001
    else {
      policyCanvasAppendOrthogonalBridge(point, to: &points)
      return
    }
    let channelExit: CGPoint =
      switch side {
      case .leading, .trailing:
        CGPoint(x: channelCoordinate, y: point.y)
      case .top, .bottom:
        CGPoint(x: point.x, y: channelCoordinate)
      }
    policyCanvasAppendOrthogonalBridge(channelExit, to: &points)
    policyCanvasAppendOrthogonalBridge(point, to: &points)
  }
}
