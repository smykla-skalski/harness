import CoreGraphics
import Foundation
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
  /// Per-lane visual separation for parallel edges sharing a bus column.
  /// 12pt is wide enough that 8+ parallel edges (e.g. converging on a
  /// terminal-decisions group) read as distinct rails rather than a
  /// single tight bundle, but narrow enough that simple 2-3-edge fans
  /// still fit within node-clearance bounds. Lifted out of
  /// `channelStep` because the channel snap (5pt) wants the tighter
  /// grid to keep routes axis-aligned, while the visible spread wants
  /// the wider step for legibility.
  static let laneSpreadStep: CGFloat = 12
  /// Bend penalty for A*. 100pt is the dominant cost term once segment
  /// lengths drop below ~100pt, matching the recommendations' research
  /// citation (50-200 typical range).
  static let bendPenalty: CGFloat = 100

  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    routeAndCost(
      source: source,
      target: target,
      context: context
    ).route
  }

  /// Flex-anchor override. Walks every source/target combination, takes the
  /// A* cost back from the visibility engine, and returns the lowest-cost
  /// route. Combos whose A* call falls back (no path through the sparse
  /// grid) report `nil` cost and are skipped during ranking; if every combo
  /// falls back the result is the single-anchor fallback for the first
  /// candidate pair. Ranking sources its cost from `PolicyCanvasVisibilityAStar`
  /// directly, not from a second compute helper - one algorithm, one cost.
  func route(
    sourceCandidates: [CGPoint],
    targetCandidates: [CGPoint],
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    guard !sourceCandidates.isEmpty, !targetCandidates.isEmpty else {
      return route(
        source: sourceCandidates.first ?? .zero,
        target: targetCandidates.first ?? .zero,
        context: context
      )
    }
    var bestRoute: PolicyCanvasEdgeRoute?
    var bestCost: CGFloat = .infinity
    for sourceAnchor in sourceCandidates {
      for targetAnchor in targetCandidates {
        let outcome = routeAndCost(
          source: sourceAnchor,
          target: targetAnchor,
          context: context
        )
        guard let cost = outcome.cost else {
          continue
        }
        if cost < bestCost {
          bestCost = cost
          bestRoute = outcome.route
        }
      }
    }
    return bestRoute
      ?? route(
        source: sourceCandidates[0],
        target: targetCandidates[0],
        context: context
      )
  }

  /// Internal single-anchor routing that returns both the post-processed
  /// route and the raw A* cost. A* cost is `nil` when the algorithm could
  /// not find a path (grid not indexable, no connected path) - the route in
  /// that case is the hand-coded fallback. Flex-anchor selection only
  /// considers candidates with non-nil cost; fallback candidates are skipped
  /// in ranking so an A*-solved combo always wins over a fallback combo.
  private func routeAndCost(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> (route: PolicyCanvasEdgeRoute, cost: CGFloat?) {
    let prepared = preparedObstacles(
      source: source,
      target: target,
      sourceActual: context.sourceActual,
      targetActual: context.targetActual,
      raw: context.obstacles
    )
    let corridorObstacles = prepared.filter {
      max($0.width, $0.height) >= 220
    }
    let gridXs = Self.sortedAxisCoordinates(
      anchor1: source.x,
      anchor2: target.x,
      laneOffset: laneOffsetX(lane: context.lane, spacing: context.lineSpacing),
      bounds: prepared.map { ($0.minX, $0.maxX) },
      corridorBounds: corridorObstacles.map { ($0.minX, $0.maxX) },
      corridorStep: max(
        PolicyCanvasLayout.edgePortTurnMinimumLead,
        context.lineSpacing * 2
      )
    )
    let gridYs = Self.sortedAxisCoordinates(
      anchor1: source.y,
      anchor2: target.y,
      laneOffset: laneOffsetY(lane: context.lane, spacing: context.lineSpacing),
      bounds: prepared.map { ($0.minY, $0.maxY) },
      corridorBounds: corridorObstacles.map { ($0.minY, $0.maxY) },
      corridorStep: max(
        PolicyCanvasLayout.edgePortTurnMinimumLead,
        context.lineSpacing * 2
      )
    )
    guard
      let sx = gridXs.firstIndex(of: source.x),
      let sy = gridYs.firstIndex(of: source.y),
      let tx = gridXs.firstIndex(of: target.x),
      let ty = gridYs.firstIndex(of: target.y)
    else {
      policyCanvasRouterLog.debug(
        """
        visibility router fallback (grid-miss): obstacles=\
        \(prepared.count, privacy: .public) gridX=\
        \(gridXs.count, privacy: .public) gridY=\
        \(gridYs.count, privacy: .public)
        """
      )
      return (
        fallback(
          source: source,
          target: target,
          context: context
        ),
        nil
      )
    }
    let aStarResult = PolicyCanvasVisibilityAStar.run(
      gridXs: gridXs,
      gridYs: gridYs,
      sourceIndex: PolicyCanvasGridIndex(x: sx, y: sy),
      targetIndex: PolicyCanvasGridIndex(x: tx, y: ty),
      obstacles: prepared
    )
    guard let aStarResult, aStarResult.points.count >= 2 else {
      policyCanvasRouterLog.debug(
        """
        visibility router fallback (astar-no-path): obstacles=\
        \(prepared.count, privacy: .public) gridX=\
        \(gridXs.count, privacy: .public) gridY=\
        \(gridYs.count, privacy: .public)
        """
      )
      return (
        fallback(
          source: source,
          target: target,
          context: context
        ),
        nil
      )
    }
    let compressed = Self.compressCollinear(aStarResult.points)
    let spread = Self.applyLaneSpread(
      compressed,
      lane: context.lane,
      source: source,
      target: target,
      lineSpacing: context.lineSpacing
    )
    let snapped = Self.snapToChannels(spread, source: source, target: target)
    let polyline = PolicyCanvasEdgeRoute(
      points: snapped,
      labelPosition: Self.labelPosition(for: snapped)
    )
    return (polyline, aStarResult.cost)
  }

  private func preparedObstacles(
    source: CGPoint,
    target: CGPoint,
    sourceActual: CGPoint?,
    targetActual: CGPoint?,
    raw: [CGRect]
  ) -> [CGRect] {
    let sourceDropPoint = sourceActual ?? source
    let targetDropPoint = targetActual ?? target
    return raw.reduce(into: [CGRect]()) { result, rect in
      let padded = rect.insetBy(dx: -Self.obstaclePadding, dy: -Self.obstaclePadding)
      if padded.contains(sourceDropPoint) || padded.contains(targetDropPoint) {
        return
      }
      result.append(padded)
    }
  }

  static func sortedAxisCoordinates(
    anchor1: CGFloat,
    anchor2: CGFloat,
    laneOffset: CGFloat,
    bounds: [(CGFloat, CGFloat)],
    corridorBounds: [(CGFloat, CGFloat)] = [],
    corridorStep: CGFloat
  ) -> [CGFloat] {
    var values: Set<CGFloat> = [anchor1, anchor2]
    let mid = (anchor1 + anchor2) / 2 + laneOffset
    values.insert(mid)
    for bound in corridorBounds {
      values.insert(bound.0 - corridorStep)
      values.insert(bound.1 + corridorStep)
    }
    for bound in bounds {
      values.insert(bound.0)
      values.insert(bound.1)
    }
    return values.sorted()
  }

  private func laneOffsetX(lane: Int, spacing: CGFloat) -> CGFloat {
    CGFloat(((lane % 12) - 6)) * spacing
  }

  private func laneOffsetY(lane: Int, spacing: CGFloat) -> CGFloat {
    CGFloat(((lane / 12) - 6)) * spacing
  }

  private func fallback(
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

  /// Shift the longest internal bus segment perpendicular to itself by
  /// `lane * laneSpreadStep`, pushing each lane's shared corridor into its own
  /// visual track. Simple 4-point detours keep the older "skip large endpoint
  /// deltas" guard, while longer multi-bend routes spread their dominant
  /// interior run unconditionally because the offset no longer creates a
  /// visible endpoint zig-zag.
  static func applyLaneSpread(
    _ points: [CGPoint],
    lane: Int,
    source: CGPoint,
    target: CGPoint,
    lineSpacing: CGFloat = PolicyCanvasLayout.defaultEdgeLineSpacing
  ) -> [CGPoint] {
    guard lane != 0, points.count >= 4 else {
      return points
    }
    guard let segment = dominantInternalBusSegment(in: points) else {
      return points
    }
    let pointA = points[segment.startIndex]
    let offset = CGFloat(lane) * lineSpacing
    if segment.isHorizontal {
      if points.count == 4, abs(source.y - target.y) > 60 {
        return points
      }
      let midY = (source.y + target.y) / 2
      let direction: CGFloat = pointA.y >= midY ? 1 : -1
      var spread = points
      for index in dominantTrackIndices(in: points, segment: segment) {
        spread[index].y += direction * offset
      }
      return spread
    }
    if points.count == 4, abs(source.x - target.x) > 60 {
      return points
    }
    let midX = (source.x + target.x) / 2
    let direction: CGFloat = pointA.x >= midX ? 1 : -1
    var spread = points
    for index in dominantTrackIndices(in: points, segment: segment) {
      spread[index].x += direction * offset
    }
    return spread
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

  private struct InternalBusSegment {
    let startIndex: Int
    let endIndex: Int
    let isHorizontal: Bool
    let length: CGFloat
    let coordinate: CGFloat
  }

  private static func dominantInternalBusSegment(in points: [CGPoint]) -> InternalBusSegment? {
    guard points.count >= 4 else {
      return nil
    }
    return (1..<(points.count - 2)).compactMap { index in
      let start = points[index]
      let end = points[index + 1]
      if abs(start.y - end.y) < 0.001 {
        return InternalBusSegment(
          startIndex: index,
          endIndex: index + 1,
          isHorizontal: true,
          length: abs(end.x - start.x),
          coordinate: start.y
        )
      }
      if abs(start.x - end.x) < 0.001 {
        return InternalBusSegment(
          startIndex: index,
          endIndex: index + 1,
          isHorizontal: false,
          length: abs(end.y - start.y),
          coordinate: start.x
        )
      }
      return nil
    }
    .max { left, right in
      left.length < right.length
    }
  }

  private static func dominantTrackIndices(
    in points: [CGPoint],
    segment: InternalBusSegment
  ) -> ClosedRange<Int> {
    var startIndex = segment.startIndex
    var endIndex = segment.endIndex
    if segment.isHorizontal {
      while startIndex > 1,
        abs(points[startIndex - 1].y - segment.coordinate) < 0.001,
        abs(points[startIndex].y - segment.coordinate) < 0.001
      {
        startIndex -= 1
      }
      while endIndex < points.count - 2,
        abs(points[endIndex].y - segment.coordinate) < 0.001,
        abs(points[endIndex + 1].y - segment.coordinate) < 0.001
      {
        endIndex += 1
      }
      return startIndex...endIndex
    }
    while startIndex > 1,
      abs(points[startIndex - 1].x - segment.coordinate) < 0.001,
      abs(points[startIndex].x - segment.coordinate) < 0.001
    {
      startIndex -= 1
    }
    while endIndex < points.count - 2,
      abs(points[endIndex].x - segment.coordinate) < 0.001,
      abs(points[endIndex + 1].x - segment.coordinate) < 0.001
    {
      endIndex += 1
    }
    return startIndex...endIndex
  }
}
