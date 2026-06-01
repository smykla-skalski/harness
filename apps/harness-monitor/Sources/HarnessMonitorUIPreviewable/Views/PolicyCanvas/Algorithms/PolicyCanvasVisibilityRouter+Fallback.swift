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
    // Bound the detour by the obstacles local to the source-target span, not
    // the whole canvas. Taking every obstacle's extent made one boxed-in edge
    // sweep a loop around the entire policy graph; the blockers that matter
    // are the ones overlapping the corridor between the two endpoints.
    // Candidate routes are still validated against the full obstacle set
    // below, so a local detour that crosses a far node is still rejected.
    let spanRect = CGRect(
      x: min(source.x, target.x),
      y: min(source.y, target.y),
      width: abs(target.x - source.x),
      height: abs(target.y - source.y)
    ).insetBy(dx: -clearance, dy: -clearance)
    let localObstacles = obstacles.filter { $0.intersects(spanRect) }
    let extent = localObstacles.isEmpty ? obstacles : localObstacles
    let minX = extent.map(\.minX).min() ?? min(source.x, target.x)
    let maxX = extent.map(\.maxX).max() ?? max(source.x, target.x)
    let minY = extent.map(\.minY).min() ?? min(source.y, target.y)
    let maxY = extent.map(\.maxY).max() ?? max(source.y, target.y)
    let corridorMidY = (source.y + target.y) / 2
    let corridorMidX = (source.x + target.x) / 2
    let candidateYs = sortedUniqueFallbackCoordinates(
      [minY - clearance, maxY + clearance]
        + obstacles.flatMap { [$0.minY - clearance, $0.maxY + clearance] },
      preferred: corridorMidY
    )
    let candidateXs = sortedUniqueFallbackCoordinates(
      [minX - clearance, maxX + clearance]
        + obstacles.flatMap { [$0.minX - clearance, $0.maxX + clearance] },
      preferred: corridorMidX
    )
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

  private func sortedUniqueFallbackCoordinates(
    _ values: [CGFloat],
    preferred: CGFloat
  ) -> [CGFloat] {
    Array(Set(values.map(Self.quantizedCoordinate))).sorted { left, right in
      let leftDistance = abs(left - preferred)
      let rightDistance = abs(right - preferred)
      if leftDistance != rightDistance {
        return leftDistance < rightDistance
      }
      return left < right
    }
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
