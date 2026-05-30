import CoreGraphics
import Foundation

/// Orthogonal visibility-graph router with A* pathfinding. Produces
/// axis-aligned polylines that avoid node-frame obstacles while minimizing a
/// `length + bendPenalty * bends` cost. Falls back to the hand-coded router
/// when bounded sparse-grid attempts cannot connect source and target (e.g.
/// fully boxed in). Channel snap post-processes intermediate points onto a 5pt
/// grid so parallel edges between the same column pair share visual lanes.
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
  /// Containment probe for endpoint-node detection in `preparedObstacles`. An
  /// edge's own source/target anchor sits on its node's border, so a 1pt
  /// outset of the raw frame catches it. Testing the full obstacle pad instead
  /// also dropped any unrelated node lying within the pad of an anchor, which
  /// let A* route through that node's body.
  static let endpointDropProbe: CGFloat = 1
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
  /// final emitted-route cost from the visibility engine, and returns the
  /// lowest-cost route. Combos whose visibility call falls back (no path
  /// through the sparse grid) report `nil` cost and are skipped during
  /// ranking; if every combo falls back the result is the single-anchor
  /// fallback for the first candidate pair.
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

  /// Internal single-anchor routing that returns both the post-processed route
  /// and that route's cost (`length + bendPenalty*bends`). Cost is `nil` when
  /// all bounded sparse-grid attempts fail and the route falls back to the
  /// hand-coded router. Flex-anchor selection only considers candidates with
  /// non-nil cost; fallback candidates are skipped in ranking so an A*-solved
  /// combo always wins over a fallback combo.
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
    for laneOffset in Self.retryLaneOffsets {
      if let attempt = visibilityRouteAttempt(
        source: source,
        target: target,
        context: context,
        laneOffset: laneOffset,
        prepared: prepared
      ) {
        return (attempt, Self.routeCost(points: attempt.points))
      }
    }
    if let detourPoints = fallbackDetourPoints(
      source: source,
      target: target,
      obstacles: prepared,
      lineSpacing: context.lineSpacing
    ) {
      return (
        PolicyCanvasEdgeRoute(
          points: detourPoints,
          labelPosition: Self.labelPosition(for: detourPoints)
        ),
        Self.routeCost(points: detourPoints)
      )
    }
    let fallbackRoute = fallback(
      source: source,
      target: target,
      context: context
    )
    let normalizedFallbackPoints = Self.snapToChannels(
      Self.compressCollinear(fallbackRoute.points),
      source: source,
      target: target
    )
    return (
      PolicyCanvasEdgeRoute(
        points: normalizedFallbackPoints,
        labelPosition: Self.labelPosition(for: normalizedFallbackPoints)
      ),
      nil
    )
  }

  /// One sparse-grid A* attempt at a given lane offset. Returns the
  /// post-processed (spread + channel-snapped) route, or `nil` when the grid
  /// indices cannot be located, A* finds no path, or the snapped route still
  /// intersects an obstacle - in which case the caller advances to the next
  /// lane offset or the fallback path.
  private func visibilityRouteAttempt(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext,
    laneOffset: Int,
    prepared: [CGRect]
  ) -> PolicyCanvasEdgeRoute? {
    let attemptContext =
      laneOffset == 0
      ? context
      : PolicyCanvasRouteContext(
        lane: context.lane + laneOffset,
        groups: context.groups,
        sourceGroupID: context.sourceGroupID,
        targetGroupID: context.targetGroupID,
        obstacles: context.obstacles,
        sourceActual: context.sourceActual,
        targetActual: context.targetActual,
        lineSpacing: context.lineSpacing,
        corridorHint: context.corridorHint
      )
    let gridAxes = visibilityGridAxes(
      source: source,
      target: target,
      context: attemptContext,
      prepared: prepared
    )
    guard
      let sx = gridAxes.xs.firstIndex(of: Self.quantizedCoordinate(source.x)),
      let sy = gridAxes.ys.firstIndex(of: Self.quantizedCoordinate(source.y)),
      let tx = gridAxes.xs.firstIndex(of: Self.quantizedCoordinate(target.x)),
      let ty = gridAxes.ys.firstIndex(of: Self.quantizedCoordinate(target.y))
    else {
      return nil
    }
    guard
      let aStarResult = PolicyCanvasVisibilityAStar.run(
        gridXs: gridAxes.xs,
        gridYs: gridAxes.ys,
        sourceIndex: PolicyCanvasGridIndex(x: sx, y: sy),
        targetIndex: PolicyCanvasGridIndex(x: tx, y: ty),
        obstacles: prepared
      ),
      aStarResult.points.count >= 2
    else {
      return nil
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
    // Post-snap validation tolerance. `snapToChannels` rounds intermediate
    // points to the channel grid, moving each coordinate by at most
    // `channelStep / 2`. Node dimensions are not channel-grid multiples, so a
    // route that legally grazed an obstacle's far padded edge can land a
    // sub-snap step inside the padded rect. Re-validating that against the
    // full-padding set wrongly rejects the route and forces a fallback detour.
    // Shrink the obstacles by the snap tolerance for this check so a
    // <= channelStep/2 intrusion into the 15pt pad is not treated as a hit;
    // the real node body still clears by the remaining pad.
    let snapValidationObstacles = prepared.map {
      $0.insetBy(dx: Self.channelStep / 2, dy: Self.channelStep / 2)
    }
    guard !policyCanvasRouteIntersectsObstacles(snapped, obstacles: snapValidationObstacles)
    else {
      return nil
    }
    return PolicyCanvasEdgeRoute(
      points: snapped,
      labelPosition: Self.labelPosition(for: snapped)
    )
  }

  func preparedObstacles(
    source: CGPoint,
    target: CGPoint,
    sourceActual: CGPoint?,
    targetActual: CGPoint?,
    raw: [CGRect]
  ) -> [CGRect] {
    let dropPoints = [
      sourceActual,
      targetActual,
      source,
      target,
    ].compactMap { $0 }
    return raw.reduce(into: [CGRect]()) { result, rect in
      // Drop a rect only when an endpoint anchor lies on its own node frame,
      // probed by a 1pt outset - not when the anchor merely falls inside the
      // 15pt routing pad. The wider padded test dropped neighbouring nodes
      // within a pad's reach of an anchor and let A* cut through their bodies.
      let ownFrame = rect.insetBy(dx: -Self.endpointDropProbe, dy: -Self.endpointDropProbe)
      if dropPoints.contains(where: { ownFrame.contains($0) }) {
        return
      }
      result.append(rect.insetBy(dx: -Self.obstaclePadding, dy: -Self.obstaclePadding))
    }
  }

  func visibilityGridAxes(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext,
    prepared: [CGRect],
    includeAllCorridorBounds: Bool = false
  ) -> (xs: [CGFloat], ys: [CGFloat]) {
    let corridorObstacles =
      includeAllCorridorBounds
      ? prepared
      : prepared.filter {
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
        corridorStep: corridorStep,
        preferredCoordinates: context.corridorHint?.verticalLaneX.map { [$0] } ?? []
      ),
      ys: Self.sortedAxisCoordinates(
        anchor1: source.y,
        anchor2: target.y,
        laneOffset: laneOffsetY(lane: context.lane, spacing: context.lineSpacing),
        bounds: prepared.map { ($0.minY, $0.maxY) },
        corridorBounds: corridorObstacles.map { ($0.minY, $0.maxY) },
        corridorStep: corridorStep,
        preferredCoordinates: context.corridorHint.map { [$0.horizontalLaneY] } ?? []
      )
    )
  }

  /// Snap a coordinate to a 0.001pt grid before Set insertion. Sub-pt
  /// divergence from accumulated float math is below visual perception and
  /// well above 1-ULP error; bit-different computations that should produce
  /// the same logical value collapse to one grid line instead of doubling
  /// the A* search space.
  static func quantizedCoordinate(_ value: CGFloat) -> CGFloat {
    (value * 1_000).rounded() / 1_000
  }

  static func sortedAxisCoordinates(
    anchor1: CGFloat,
    anchor2: CGFloat,
    laneOffset: CGFloat,
    bounds: [(CGFloat, CGFloat)],
    corridorBounds: [(CGFloat, CGFloat)] = [],
    corridorStep: CGFloat,
    preferredCoordinates: [CGFloat] = []
  ) -> [CGFloat] {
    var values: Set<CGFloat> = [quantizedCoordinate(anchor1), quantizedCoordinate(anchor2)]
    let mid = (anchor1 + anchor2) / 2 + laneOffset
    values.insert(quantizedCoordinate(mid))
    for coordinate in preferredCoordinates {
      values.insert(quantizedCoordinate(coordinate))
    }
    for bound in corridorBounds {
      values.insert(quantizedCoordinate(bound.0 - corridorStep))
      values.insert(quantizedCoordinate(bound.1 + corridorStep))
    }
    for bound in bounds {
      values.insert(quantizedCoordinate(bound.0))
      values.insert(quantizedCoordinate(bound.1))
    }
    return values.sorted()
  }

  func laneOffsetX(lane: Int, spacing: CGFloat) -> CGFloat {
    CGFloat(((lane % 12) - 6)) * spacing
  }

  func laneOffsetY(lane: Int, spacing: CGFloat) -> CGFloat {
    CGFloat(((lane / 12) - 6)) * spacing
  }

}
