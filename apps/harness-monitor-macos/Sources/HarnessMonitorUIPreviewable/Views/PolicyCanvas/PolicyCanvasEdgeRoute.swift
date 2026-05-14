import SwiftUI

struct PolicyCanvasEdgeRoute {
  let points: [CGPoint]
  let labelPosition: CGPoint
  private static let labelLaneSpacing: CGFloat = 32

  init(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup] = [],
    sourceGroupID: String? = nil,
    targetGroupID: String? = nil
  ) {
    let laneOffset = CGFloat(lane % 12) * Self.labelLaneSpacing
    let horizontalDistance = target.x - source.x
    let sourceGroupFrame = Self.groupFrame(sourceGroupID, in: groups)
    let targetGroupFrame = Self.groupFrame(targetGroupID, in: groups)
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
        lane: lane,
        laneOffset: laneOffset
      )
    } else if sourceGroupID != targetGroupID,
      let sourceGroupFrame,
      let targetGroupFrame,
      target.x > source.x
    {
      (points, labelPosition) = Self.interGroupRoute(
        source: source,
        target: target,
        sourceGroupFrame: sourceGroupFrame,
        targetGroupFrame: targetGroupFrame,
        lane: lane
      )
    } else if horizontalDistance > 260, abs(source.y - target.y) < 96 {
      (points, labelPosition) = Self.wideRoute(
        source: source,
        target: target,
        lane: lane,
        laneOffset: laneOffset
      )
    } else {
      (points, labelPosition) = Self.defaultRoute(
        source: source,
        target: target,
        horizontalDistance: horizontalDistance,
        lane: lane,
        laneOffset: laneOffset
      )
    }
  }

  private static func groupFrame(_ id: String?, in groups: [PolicyCanvasGroup]) -> CGRect? {
    guard let id else {
      return nil
    }
    return groups.first { $0.id == id }?.frame
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
    lane: Int,
    laneOffset: CGFloat
  ) -> ([CGPoint], CGPoint) {
    let sourceRunX = source.x + 48 + laneOffset
    let targetRunX = target.x - 48 - laneOffset
    let topBase = (blockers.map(\.minY).min() ?? PolicyCanvasLayout.initialContentOrigin.y) - 34
    let topLaneY = topBase - laneOffset
    let bottomLaneY =
      (blockers.map(\.maxY).max() ?? PolicyCanvasLayout.initialContentOrigin.y) + 42 + laneOffset
    let routedY = topLaneY >= 18 ? topLaneY : bottomLaneY
    let points = [
      source,
      CGPoint(x: sourceRunX, y: source.y),
      CGPoint(x: sourceRunX, y: routedY),
      CGPoint(x: targetRunX, y: routedY),
      CGPoint(x: targetRunX, y: target.y),
      target,
    ]
    return (points, labelPosition(for: points, lane: lane))
  }

  private static func interGroupRoute(
    source: CGPoint,
    target: CGPoint,
    sourceGroupFrame: CGRect,
    targetGroupFrame: CGRect,
    lane: Int
  ) -> ([CGPoint], CGPoint) {
    let gapMinX = sourceGroupFrame.maxX + 34
    let gapMaxX = targetGroupFrame.minX - 34
    let laneOffset = CGFloat((lane % 5) - 2) * 12
    let laneYOffset = CGFloat((lane % 5) - 2) * Self.labelLaneSpacing
    let preferredBusX = ((gapMinX + gapMaxX) / 2) + laneOffset
    let busX =
      gapMinX < gapMaxX
      ? min(gapMaxX, max(gapMinX, preferredBusX))
      : source.x + max(72, (target.x - source.x) * 0.46)
    let sourceExitX = min(busX, sourceGroupFrame.maxX + 18)
    let routedSourceY = min(
      sourceGroupFrame.maxY - 38,
      max(sourceGroupFrame.minY + 38, source.y + laneYOffset)
    )
    let points = [
      source,
      CGPoint(x: sourceExitX, y: source.y),
      CGPoint(x: sourceExitX, y: routedSourceY),
      CGPoint(x: busX, y: routedSourceY),
      CGPoint(x: busX, y: target.y),
      target,
    ]
    let labelPosition = CGPoint(x: (sourceExitX + busX) / 2, y: routedSourceY)
    return (points, labelPosition)
  }

  private static func wideRoute(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
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
    return (points, labelPosition(for: points, lane: lane))
  }

  private static func defaultRoute(
    source: CGPoint,
    target: CGPoint,
    horizontalDistance: CGFloat,
    lane: Int,
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
    return (points, labelPosition(for: points, lane: lane))
  }

  private static func labelPosition(for points: [CGPoint], lane: Int) -> CGPoint {
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
    let horizontal = abs(segment.1.x - segment.0.x) >= abs(segment.1.y - segment.0.y)
    let laneT = min(0.78, max(0.22, 0.38 + CGFloat(lane % 6) * 0.07))
    let positionFraction = horizontal ? laneT : 0.5
    return CGPoint(
      x: segment.0.x + ((segment.1.x - segment.0.x) * positionFraction),
      y: segment.0.y + ((segment.1.y - segment.0.y) * positionFraction)
    )
  }

  private static func segmentLength(_ segment: (CGPoint, CGPoint)) -> CGFloat {
    hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y)
  }
}
