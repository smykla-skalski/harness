import SwiftUI

public struct PolicyCanvasEdgeRoute: Equatable, Sendable {
  public let points: [CGPoint]
  public let labelPosition: CGPoint

  public init(points: [CGPoint], labelPosition: CGPoint) {
    self.points = points
    self.labelPosition = labelPosition
  }

  /// True midpoint along the polyline's arc length. Walks segments
  /// accumulating length and interpolates within the segment that crosses
  /// the half-length mark. Used by `PolicyCanvasInteractiveEdge` as the
  /// `.accessibilityActivationPoint` so VoiceOver and keyboard focus
  /// activate on a point that is actually on the stroke - default
  /// frame-center can sit in empty canvas for L-shaped or zig-zag routes,
  /// per Watson's R2 a11y note.
  public var arcLengthMidpoint: CGPoint {
    // Empty or single-point route -> fall back to labelPosition rather
    // than (0, 0). Activation point at the canvas origin would land in
    // empty canvas and miss the stroke entirely; labelPosition is the
    // already-computed visual anchor for this edge, so it's the safest
    // fallback for the degenerate cases that should never reach this
    // path in practice.
    guard points.count >= 2 else {
      return points.first ?? labelPosition
    }
    var total: CGFloat = 0
    for index in 0..<(points.count - 1) {
      total += distance(points[index], points[index + 1])
    }
    // Zero total length (all points coincide) -> labelPosition again,
    // same rationale as the empty-array branch above.
    guard total > 0 else {
      return labelPosition
    }
    let halfway = total / 2
    var traversed: CGFloat = 0
    for index in 0..<(points.count - 1) {
      let from = points[index]
      let to = points[index + 1]
      let segmentLength = distance(from, to)
      if traversed + segmentLength >= halfway {
        let remainder = halfway - traversed
        let ratio = segmentLength == 0 ? 0 : remainder / segmentLength
        return CGPoint(
          x: from.x + (to.x - from.x) * ratio,
          y: from.y + (to.y - from.y) * ratio
        )
      }
      traversed += segmentLength
    }
    return points.last ?? labelPosition
  }

  private func distance(_ start: CGPoint, _ end: CGPoint) -> CGFloat {
    hypot(end.x - start.x, end.y - start.y)
  }

  public init(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup] = [],
    sourceGroupID: String? = nil,
    targetGroupID: String? = nil
  ) {
    let laneOffset = CGFloat(lane % 12) * PolicyCanvasLayout.edgeBusLaneSpacing
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
    } else if sourceGroupID == targetGroupID,
      let sourceGroupFrame,
      abs(horizontalDistance) <= PolicyCanvasLayout.nodeSize.width,
      abs(target.y - source.y) > PolicyCanvasLayout.nodeSize.height
    {
      (points, labelPosition) = Self.verticalStackRoute(
        source: source,
        target: target,
        groupFrame: sourceGroupFrame,
        lane: lane
      )
    } else if sourceGroupID == targetGroupID,
      let sourceGroupFrame,
      target.x > source.x
    {
      (points, labelPosition) = Self.sameGroupForwardRoute(
        source: source,
        target: target,
        groupFrame: sourceGroupFrame,
        lane: lane,
        laneOffset: laneOffset
      )
    } else if sourceGroupID == targetGroupID,
      let sourceGroupFrame,
      target.x <= source.x
    {
      (points, labelPosition) = Self.sameGroupReturnRoute(
        source: source,
        target: target,
        groupFrame: sourceGroupFrame,
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
    // The horizontalRange and yBand below are already direction-symmetric;
    // earlier code short-circuited right-to-left edges with no blockers,
    // which let routes crash straight through obstacles between source and
    // target whenever target.x < source.x.
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
    let direction: CGFloat = target.x >= source.x ? 1 : -1
    let leadDistance = 48 + laneOffset
    let sourceRunX = source.x + leadDistance * direction
    let targetRunX = target.x - leadDistance * direction
    let topBase = (blockers.map(\.minY).min() ?? PolicyCanvasLayout.initialContentOrigin.y) - 58
    let topLaneY = topBase - (CGFloat(lane % 6) * PolicyCanvasLayout.edgeLabelLaneSpacing)
    let bottomLaneY =
      (blockers.map(\.maxY).max() ?? PolicyCanvasLayout.initialContentOrigin.y)
      + 64
      + (CGFloat(lane % 6) * PolicyCanvasLayout.edgeLabelLaneSpacing)
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
    let gapMinX = sourceGroupFrame.maxX + PolicyCanvasLayout.edgeLabelNodeClearance
    let gapMaxX = targetGroupFrame.minX - PolicyCanvasLayout.edgeLabelNodeClearance
    let labelHalfWidth =
      (PolicyCanvasLayout.edgeLabelMaxWidth / 2) + PolicyCanvasLayout.edgeLabelHorizontalMargin
    let labelX = min(
      gapMaxX - labelHalfWidth,
      max(
        gapMinX + labelHalfWidth,
        sourceGroupFrame.maxX + labelHalfWidth + PolicyCanvasLayout.edgeLabelHorizontalMargin
      )
    )
    let busStartX = labelX + labelHalfWidth + PolicyCanvasLayout.edgeLabelHorizontalMargin
    let preferredBusX = busStartX + (CGFloat(lane) * PolicyCanvasLayout.edgeBusLaneSpacing)
    let busX =
      gapMinX < gapMaxX
      ? min(gapMaxX, max(gapMinX, preferredBusX))
      : source.x + max(72, (target.x - source.x) * 0.46)
    let sourceExitX = min(busX, sourceGroupFrame.maxX + PolicyCanvasLayout.edgeLabelNodeClearance)
    let routedSourceY = source.y + (CGFloat(lane) * PolicyCanvasLayout.edgeLabelLaneSpacing)
    let points = [
      source,
      CGPoint(x: sourceExitX, y: source.y),
      CGPoint(x: sourceExitX, y: routedSourceY),
      CGPoint(x: busX, y: routedSourceY),
      CGPoint(x: busX, y: target.y),
      target,
    ]
    let labelPosition = CGPoint(
      x: min(max(labelX, sourceExitX), busX),
      y: routedSourceY
    )
    return (points, labelPosition)
  }

  private static func verticalStackRoute(
    source: CGPoint,
    target: CGPoint,
    groupFrame: CGRect,
    lane: Int
  ) -> ([CGPoint], CGPoint) {
    let laneSlot = CGFloat(lane % 6)
    let labelY = (source.y + target.y) / 2
    let busX = groupFrame.maxX + 220 + (laneSlot * PolicyCanvasLayout.edgeBusLaneSpacing)
    let points = [
      source,
      CGPoint(x: source.x, y: labelY),
      CGPoint(x: busX, y: labelY),
      CGPoint(x: busX, y: target.y),
      target,
    ]
    let labelPosition = CGPoint(
      x: (source.x + busX) / 2,
      y: labelY
    )
    return (points, labelPosition)
  }

  private static func sameGroupForwardRoute(
    source: CGPoint,
    target: CGPoint,
    groupFrame: CGRect,
    lane: Int,
    laneOffset: CGFloat
  ) -> ([CGPoint], CGPoint) {
    let sourceRunX = source.x + 40 + laneOffset
    let targetRunX = target.x - 40 - laneOffset
    let topLaneY = max(
      groupFrame.minY + 38,
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
    let labelPosition = CGPoint(x: (sourceRunX + targetRunX) / 2, y: topLaneY)
    return (points, labelPosition)
  }

  private static func sameGroupReturnRoute(
    source: CGPoint,
    target: CGPoint,
    groupFrame: CGRect,
    lane: Int
  ) -> ([CGPoint], CGPoint) {
    let laneSlot = CGFloat(lane % 6)
    let sourceExitX = groupFrame.maxX + 60
    let busX = groupFrame.maxX + 340 + (laneSlot * PolicyCanvasLayout.edgeBusLaneSpacing)
    let targetRunY = target.y
    let labelY = min(
      groupFrame.maxY - 38,
      max(groupFrame.minY + 38, source.y + (laneSlot * PolicyCanvasLayout.edgeLabelLaneSpacing))
    )
    let points = [
      source,
      CGPoint(x: sourceExitX, y: source.y),
      CGPoint(x: sourceExitX, y: labelY),
      CGPoint(x: busX, y: labelY),
      CGPoint(x: busX, y: targetRunY),
      target,
    ]
    let labelPosition = CGPoint(x: (sourceExitX + busX) / 2, y: labelY)
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
