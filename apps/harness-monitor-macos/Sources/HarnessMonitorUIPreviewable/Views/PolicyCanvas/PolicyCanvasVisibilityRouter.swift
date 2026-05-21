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
  func routeAndCost(
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
    let gridAxes = visibilityGridAxes(
      source: source,
      target: target,
      context: context,
      prepared: prepared
    )
    guard
      let sx = gridAxes.xs.firstIndex(of: source.x),
      let sy = gridAxes.ys.firstIndex(of: source.y),
      let tx = gridAxes.xs.firstIndex(of: target.x),
      let ty = gridAxes.ys.firstIndex(of: target.y)
    else {
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
      gridXs: gridAxes.xs,
      gridYs: gridAxes.ys,
      sourceIndex: PolicyCanvasGridIndex(x: sx, y: sy),
      targetIndex: PolicyCanvasGridIndex(x: tx, y: ty),
      obstacles: prepared
    )
    guard let aStarResult, aStarResult.points.count >= 2 else {
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

  func preparedObstacles(
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

  func visibilityGridAxes(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext,
    prepared: [CGRect]
  ) -> (xs: [CGFloat], ys: [CGFloat]) {
    let corridorObstacles = prepared.filter {
      max($0.width, $0.height) >= 220
    }
    let corridorStep = max(
      PolicyCanvasLayout.edgePortTurnMinimumLead,
      context.lineSpacing * 2
    )
    return (
      xs: Self.sortedAxisCoordinates(
        anchor1: source.x,
        anchor2: target.x,
        laneOffset: laneOffsetX(lane: context.lane, spacing: context.lineSpacing),
        bounds: prepared.map { ($0.minX, $0.maxX) },
        corridorBounds: corridorObstacles.map { ($0.minX, $0.maxX) },
        corridorStep: corridorStep
      ),
      ys: Self.sortedAxisCoordinates(
        anchor1: source.y,
        anchor2: target.y,
        laneOffset: laneOffsetY(lane: context.lane, spacing: context.lineSpacing),
        bounds: prepared.map { ($0.minY, $0.maxY) },
        corridorBounds: corridorObstacles.map { ($0.minY, $0.maxY) },
        corridorStep: corridorStep
      )
    )
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

  func laneOffsetX(lane: Int, spacing: CGFloat) -> CGFloat {
    CGFloat(((lane % 12) - 6)) * spacing
  }

  func laneOffsetY(lane: Int, spacing: CGFloat) -> CGFloat {
    CGFloat(((lane / 12) - 6)) * spacing
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
