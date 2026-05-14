import SwiftUI

struct PolicyCanvasEdgeRoute {
  let points: [CGPoint]
  let labelPosition: CGPoint

  init(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup] = [],
    sourceGroupID: String? = nil,
    targetGroupID: String? = nil
  ) {
    let laneOffset = CGFloat(lane % 8) * 12
    let horizontalDistance = target.x - source.x
    let blockers = Self.blockingGroups(
      source: source,
      target: target,
      groups: groups,
      sourceGroupID: sourceGroupID,
      targetGroupID: targetGroupID
    )
    if !blockers.isEmpty {
      (points, labelPosition) = Self.blockingRoute(
        source: source,
        target: target,
        blockers: blockers,
        laneOffset: laneOffset
      )
    } else if horizontalDistance > 260, abs(source.y - target.y) < 96 {
      (points, labelPosition) = Self.wideRoute(
        source: source,
        target: target,
        laneOffset: laneOffset
      )
    } else {
      (points, labelPosition) = Self.defaultRoute(
        source: source,
        target: target,
        horizontalDistance: horizontalDistance,
        laneOffset: laneOffset
      )
    }
  }

  private static func blockingGroups(
    source: CGPoint,
    target: CGPoint,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?
  ) -> [CGRect] {
    guard target.x > source.x else {
      return []
    }
    let horizontalRange = min(source.x, target.x)...max(source.x, target.x)
    let yBand = min(source.y, target.y) - 18...max(source.y, target.y) + 18
    return groups.compactMap { group in
      guard group.id != sourceGroupID, group.id != targetGroupID else {
        return nil
      }
      let frame = group.frame.insetBy(dx: -18, dy: -18)
      return crosses(frame: frame, horizontalRange: horizontalRange, yBand: yBand, source: source)
        ? frame
        : nil
    }
  }

  private static func crosses(
    frame: CGRect,
    horizontalRange: ClosedRange<CGFloat>,
    yBand: ClosedRange<CGFloat>,
    source: CGPoint
  ) -> Bool {
    let crossesHorizontally =
      horizontalRange.contains(frame.minX)
      || horizontalRange.contains(frame.maxX)
      || (frame.minX...frame.maxX).contains(source.x)
    let crossesVertically =
      yBand.contains(frame.minY)
      || yBand.contains(frame.maxY)
      || (frame.minY...frame.maxY).contains(source.y)
    return crossesHorizontally && crossesVertically
  }

  private static func blockingRoute(
    source: CGPoint,
    target: CGPoint,
    blockers: [CGRect],
    laneOffset: CGFloat
  ) -> ([CGPoint], CGPoint) {
    let sourceRunX = source.x + 48 + laneOffset
    let targetRunX = target.x - 48 - laneOffset
    let topLaneY = max(
      18,
      (blockers.map(\.minY).min() ?? PolicyCanvasLayout.initialContentOrigin.y) - 34 - laneOffset
    )
    let points = [
      source,
      CGPoint(x: sourceRunX, y: source.y),
      CGPoint(x: sourceRunX, y: topLaneY),
      CGPoint(x: targetRunX, y: topLaneY),
      CGPoint(x: targetRunX, y: target.y),
      target,
    ]
    return (points, labelPosition(for: points))
  }

  private static func wideRoute(
    source: CGPoint,
    target: CGPoint,
    laneOffset: CGFloat
  ) -> ([CGPoint], CGPoint) {
    let sourceRunX = source.x + 54 + laneOffset
    let targetRunX = target.x - 54 - laneOffset
    let topLaneY = max(
      PolicyCanvasLayout.initialContentOrigin.y + 16,
      min(source.y, target.y) - 52 - laneOffset
    )
    let points = [
      source,
      CGPoint(x: sourceRunX, y: source.y),
      CGPoint(x: sourceRunX, y: topLaneY),
      CGPoint(x: targetRunX, y: topLaneY),
      CGPoint(x: targetRunX, y: target.y),
      target,
    ]
    return (points, labelPosition(for: points))
  }

  private static func defaultRoute(
    source: CGPoint,
    target: CGPoint,
    horizontalDistance: CGFloat,
    laneOffset: CGFloat
  ) -> ([CGPoint], CGPoint) {
    let midX =
      horizontalDistance >= 0
      ? source.x + max(72, horizontalDistance * 0.46) + laneOffset
      : max(source.x, target.x) + 84 + laneOffset
    let points = [
      source,
      CGPoint(x: midX, y: source.y),
      CGPoint(x: midX, y: target.y),
      target,
    ]
    return (points, labelPosition(for: points))
  }

  private static func labelPosition(for points: [CGPoint]) -> CGPoint {
    let segments = zip(points, points.dropFirst())
    let preferred =
      segments
      .filter { left, right in
        abs(right.x - left.x) >= abs(right.y - left.y)
      }
      .max { left, right in
        segmentLength(left) < segmentLength(right)
      }
    let segment =
      preferred
      ?? zip(points, points.dropFirst()).max { left, right in
        segmentLength(left) < segmentLength(right)
      }
    guard let segment else {
      return points.first ?? .zero
    }
    return CGPoint(
      x: (segment.0.x + segment.1.x) / 2,
      y: (segment.0.y + segment.1.y) / 2
    )
  }

  private static func segmentLength(_ segment: (CGPoint, CGPoint)) -> CGFloat {
    hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y)
  }
}
