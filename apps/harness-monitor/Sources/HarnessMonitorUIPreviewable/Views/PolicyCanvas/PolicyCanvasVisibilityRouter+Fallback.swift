import CoreGraphics
import Foundation

extension PolicyCanvasVisibilityRouter {
  static func routeCost(points: [CGPoint]) -> CGFloat {
    guard points.count >= 2 else {
      return .infinity
    }
    var cost: CGFloat = 0
    var lastDirection: PolicyCanvasAStarDirection = .start
    for (start, end) in zip(points, points.dropFirst()) {
      let dx = abs(end.x - start.x)
      let dy = abs(end.y - start.y)
      let direction: PolicyCanvasAStarDirection = dx >= dy ? .horizontal : .vertical
      cost += dx + dy
      if lastDirection != .start, lastDirection != direction {
        cost += Self.bendPenalty
      }
      lastDirection = direction
    }
    return cost
  }

  static let retryLaneOffsets: [Int] = [0]

  func policyCanvasRouteIntersectsObstacles(
    _ points: [CGPoint],
    obstacles: [CGRect]
  ) -> Bool {
    guard points.count >= 2 else {
      return false
    }
    for (start, end) in zip(points, points.dropFirst())
    where PolicyCanvasVisibilityAStar.segmentBlocked(from: start, to: end, obstacles: obstacles) {
      return true
    }
    return false
  }

  func fallbackDetourPoints(
    source: CGPoint,
    target: CGPoint,
    obstacles: [CGRect],
    lineSpacing: CGFloat
  ) -> [CGPoint]? {
    guard !obstacles.isEmpty else {
      return nil
    }
    let clearance = max(PolicyCanvasLayout.edgePortTurnMinimumLead, lineSpacing * 2)
    let minX = obstacles.map(\.minX).min() ?? min(source.x, target.x)
    let maxX = obstacles.map(\.maxX).max() ?? max(source.x, target.x)
    let minY = obstacles.map(\.minY).min() ?? min(source.y, target.y)
    let maxY = obstacles.map(\.maxY).max() ?? max(source.y, target.y)
    let candidateYs = [minY - clearance, maxY + clearance]
    let candidateXs = [minX - clearance, maxX + clearance]
    var candidates: [[CGPoint]] = []
    for y in candidateYs {
      candidates.append([
        source,
        CGPoint(x: source.x, y: y),
        CGPoint(x: target.x, y: y),
        target,
      ])
    }
    for x in candidateXs {
      candidates.append([
        source,
        CGPoint(x: x, y: source.y),
        CGPoint(x: x, y: target.y),
        target,
      ])
    }
    var best: (points: [CGPoint], cost: CGFloat)?
    for candidate in candidates {
      let points = Self.snapToChannels(
        Self.compressCollinear(candidate),
        source: source,
        target: target
      )
      guard !policyCanvasRouteIntersectsObstacles(points, obstacles: obstacles) else {
        continue
      }
      let cost = Self.routeCost(points: points)
      if let current = best {
        if cost < current.cost {
          best = (points, cost)
        }
      } else {
        best = (points, cost)
      }
    }
    return best?.points
  }

  func fallback(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    PolicyCanvasHandCodedOrthogonalRouter().route(
      source: source,
      target: target,
      context: PolicyCanvasRouteContext(
        lane: context.lane,
        groups: context.groups,
        sourceGroupID: context.sourceGroupID,
        targetGroupID: context.targetGroupID,
        sourceActual: context.sourceActual,
        targetActual: context.targetActual,
        lineSpacing: context.lineSpacing
      )
    )
  }
}
