import CoreGraphics
import Foundation
import SwiftUI

/// Orthogonal visibility-graph router with A* pathfinding. Produces
/// axis-aligned polylines that avoid node-frame obstacles while minimizing a
/// `length + bendPenalty * bends` cost. Falls back to the hand-coded router
/// when the sparse grid cannot connect source and target (e.g. fully boxed
/// in). Channel snap post-processes intermediate points onto a 5pt grid so
/// parallel edges between the same column pair share visual lanes.
///
/// The algorithm:
///   1. Inset obstacle rects by `obstaclePadding` for clearance; drop any
///      rect containing source or target (the edge's own endpoints).
///   2. Build sparse x and y grid lines from obstacle bounds, source/target
///      coordinates, and one lane-offset midX/midY pair.
///   3. Run A* over (xIndex, yIndex, lastDirection) states. Cost on each
///      step is the axis distance plus `bendPenalty` when direction changes.
///   4. Compress consecutive collinear points, then snap intermediate
///      coordinates to the channel grid.
struct PolicyCanvasVisibilityRouter: PolicyCanvasEdgeRouter {
  /// Clearance inset applied to every obstacle. 15pt = 3 * `channelStep`
  /// keeps the post-snap boundary aligned to the channel grid; smaller
  /// non-multiples (e.g. 12pt) let `snapToChannels` round a route's detour
  /// back into the obstacle interior.
  static let obstaclePadding: CGFloat = 15
  /// Channel snap grid. 5pt gives parallel-edge separation without visibly
  /// shifting routes off straight axes when only one edge runs the channel.
  static let channelStep: CGFloat = 5
  /// Bend penalty for A*. 100pt is the dominant cost term once segment
  /// lengths drop below ~100pt, matching the recommendations' research
  /// citation (50-200 typical range).
  static let bendPenalty: CGFloat = 100

  func route(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?,
    obstacles: [CGRect]
  ) -> PolicyCanvasEdgeRoute {
    let prepared = preparedObstacles(source: source, target: target, raw: obstacles)
    let gridXs = sortedAxisCoordinates(
      anchor1: source.x,
      anchor2: target.x,
      laneOffset: laneOffsetX(lane: lane),
      bounds: prepared.map { ($0.minX, $0.maxX) }
    )
    let gridYs = sortedAxisCoordinates(
      anchor1: source.y,
      anchor2: target.y,
      laneOffset: laneOffsetY(lane: lane),
      bounds: prepared.map { ($0.minY, $0.maxY) }
    )
    guard
      let sx = gridXs.firstIndex(of: source.x),
      let sy = gridYs.firstIndex(of: source.y),
      let tx = gridXs.firstIndex(of: target.x),
      let ty = gridYs.firstIndex(of: target.y)
    else {
      return fallback(
        source: source,
        target: target,
        lane: lane,
        groups: groups,
        sourceGroupID: sourceGroupID,
        targetGroupID: targetGroupID
      )
    }
    let aStarPoints = PolicyCanvasVisibilityAStar.run(
      gridXs: gridXs,
      gridYs: gridYs,
      sourceIndex: PolicyCanvasGridIndex(x: sx, y: sy),
      targetIndex: PolicyCanvasGridIndex(x: tx, y: ty),
      obstacles: prepared
    )
    guard let aStarPoints, aStarPoints.count >= 2 else {
      return fallback(
        source: source,
        target: target,
        lane: lane,
        groups: groups,
        sourceGroupID: sourceGroupID,
        targetGroupID: targetGroupID
      )
    }
    let compressed = Self.compressCollinear(aStarPoints)
    let spread = Self.applyLaneSpread(
      compressed,
      lane: lane,
      source: source,
      target: target
    )
    let snapped = Self.snapToChannels(spread, source: source, target: target)
    return PolicyCanvasEdgeRoute(
      points: snapped,
      labelPosition: Self.labelPosition(for: snapped)
    )
  }

  private func preparedObstacles(source: CGPoint, target: CGPoint, raw: [CGRect]) -> [CGRect] {
    raw.compactMap { rect in
      let padded = rect.insetBy(dx: -Self.obstaclePadding, dy: -Self.obstaclePadding)
      if padded.contains(source) || padded.contains(target) {
        return nil
      }
      return padded
    }
  }

  private func sortedAxisCoordinates(
    anchor1: CGFloat,
    anchor2: CGFloat,
    laneOffset: CGFloat,
    bounds: [(CGFloat, CGFloat)]
  ) -> [CGFloat] {
    var values: Set<CGFloat> = [anchor1, anchor2]
    let mid = (anchor1 + anchor2) / 2 + laneOffset
    values.insert(mid)
    for bound in bounds {
      values.insert(bound.0)
      values.insert(bound.1)
    }
    return values.sorted()
  }

  private func laneOffsetX(lane: Int) -> CGFloat {
    CGFloat(((lane % 12) - 6)) * Self.channelStep
  }

  private func laneOffsetY(lane: Int) -> CGFloat {
    CGFloat(((lane / 12) - 6)) * Self.channelStep
  }

  private func fallback(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?
  ) -> PolicyCanvasEdgeRoute {
    PolicyCanvasHandCodedOrthogonalRouter().route(
      source: source,
      target: target,
      lane: lane,
      groups: groups,
      sourceGroupID: sourceGroupID,
      targetGroupID: targetGroupID,
      obstacles: []
    )
  }

  static func compressCollinear(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count >= 3 else {
      return points
    }
    var result: [CGPoint] = [points[0]]
    for index in 1..<points.count - 1 {
      let prev = points[index - 1]
      let cur = points[index]
      let next = points[index + 1]
      let prevHorizontal = abs(cur.y - prev.y) < 0.0001
      let nextHorizontal = abs(next.y - cur.y) < 0.0001
      if prevHorizontal && nextHorizontal {
        continue
      }
      let prevVertical = abs(cur.x - prev.x) < 0.0001
      let nextVertical = abs(next.x - cur.x) < 0.0001
      if prevVertical && nextVertical {
        continue
      }
      result.append(cur)
    }
    result.append(points[points.count - 1])
    return result
  }

  /// Shift a 4-point detour route's bus segment perpendicular to itself by
  /// `lane * channelStep`, pushing each lane's bus into its own visual track.
  /// A* picks the shortest detour line for every lane; without this spread
  /// step parallel edges between the same column pair stack on top of one
  /// another. Only applies to the simple `[source, A, B, target]` shape - more
  /// complex multi-bend routes are left untouched and rely on lane-anchored
  /// midX/midY grid coordinates instead.
  static func applyLaneSpread(
    _ points: [CGPoint],
    lane: Int,
    source: CGPoint,
    target: CGPoint
  ) -> [CGPoint] {
    guard lane != 0, points.count == 4 else {
      return points
    }
    let offset = CGFloat(lane) * channelStep
    let pointA = points[1]
    let pointB = points[2]
    let busHorizontal = abs(pointA.y - pointB.y) < 0.001
    if busHorizontal {
      let midY = (source.y + target.y) / 2
      let direction: CGFloat = pointA.y >= midY ? 1 : -1
      return [
        points[0],
        CGPoint(x: pointA.x, y: pointA.y + direction * offset),
        CGPoint(x: pointB.x, y: pointB.y + direction * offset),
        points[3],
      ]
    }
    let midX = (source.x + target.x) / 2
    let direction: CGFloat = pointA.x >= midX ? 1 : -1
    return [
      points[0],
      CGPoint(x: pointA.x + direction * offset, y: pointA.y),
      CGPoint(x: pointB.x + direction * offset, y: pointB.y),
      points[3],
    ]
  }

  static func snapToChannels(_ points: [CGPoint], source: CGPoint, target: CGPoint) -> [CGPoint] {
    guard points.count > 2 else {
      return points
    }
    var snapped = points
    for index in 1..<snapped.count - 1 {
      snapped[index] = CGPoint(
        x: snap(snapped[index].x, step: channelStep),
        y: snap(snapped[index].y, step: channelStep)
      )
    }
    snapped[0] = source
    snapped[snapped.count - 1] = target
    return snapped
  }

  private static func snap(_ value: CGFloat, step: CGFloat) -> CGFloat {
    (value / step).rounded() * step
  }

  static func labelPosition(for points: [CGPoint]) -> CGPoint {
    guard points.count >= 2 else {
      return points.first ?? .zero
    }
    var bestIndex = 0
    var bestLength: CGFloat = -1
    for index in 0..<points.count - 1 {
      let left = points[index]
      let right = points[index + 1]
      let horizontalLength = abs(right.x - left.x)
      if horizontalLength > bestLength {
        bestLength = horizontalLength
        bestIndex = index
      }
    }
    if bestLength < 0 {
      bestIndex = 0
      for index in 0..<points.count - 1 {
        let left = points[index]
        let right = points[index + 1]
        let length = hypot(right.x - left.x, right.y - left.y)
        if length > bestLength {
          bestLength = length
          bestIndex = index
        }
      }
    }
    let left = points[bestIndex]
    let right = points[bestIndex + 1]
    return CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
  }
}

/// Grid coordinate as (xIndex, yIndex) into the router's sorted axis arrays.
struct PolicyCanvasGridIndex: Hashable {
  let x: Int
  let y: Int
}

/// A* state for orthogonal routing. Direction tracks how the path arrived at
/// the current cell so bend penalties only apply on actual axis changes.
struct PolicyCanvasAStarState: Hashable {
  let index: PolicyCanvasGridIndex
  let direction: PolicyCanvasAStarDirection
}

enum PolicyCanvasAStarDirection: Hashable {
  case start
  case horizontal
  case vertical
}
