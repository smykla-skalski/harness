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
public struct PolicyCanvasVisibilityRouter: PolicyCanvasEdgeRouter {
  /// Clearance inset applied to every obstacle. 15pt = 3 * `channelStep`
  /// keeps the post-snap boundary aligned to the channel grid; smaller
  /// non-multiples (e.g. 12pt) let `snapToChannels` round a route's detour
  /// back into the obstacle interior.
  static let obstaclePadding: CGFloat = 15
  /// Channel snap grid. 5pt gives parallel-edge separation without visibly
  /// shifting routes off straight axes when only one edge runs the channel.
  public static let channelStep: CGFloat = PolicyCanvasLayout.routeChannelStep
  /// Containment probe for endpoint-node detection in `preparedObstacles`. An
  /// edge's own source/target anchor sits on its node's border, so a 1pt
  /// outset of the raw frame catches it. Testing the full obstacle pad instead
  /// also dropped any unrelated node lying within the pad of an anchor, which
  /// let A* route through that node's body.
  static let endpointDropProbe: CGFloat = 1
  /// Minimum visual separation for parallel route lanes sharing a corridor.
  /// This intentionally matches the route-worker's default line spacing so
  /// terminal fans, nudged corridors, and router lane offsets all enforce the
  /// same edge-to-edge distance.
  static let laneSpreadStep: CGFloat = PolicyCanvasLayout.defaultEdgeLineSpacing
  /// Bend penalty for A*. 100pt is the dominant cost term once segment
  /// lengths drop below ~100pt, matching the recommendations' research
  /// citation (50-200 typical range).
  static let bendPenalty: CGFloat = 100

  /// Parameters bundled for a single sparse-grid A* attempt.
  struct VisibilityAttemptParameters {
    let laneOffset: Int
    let searchPrepared: [CGRect]
    let validationPrepared: [CGRect]
  }

  public init() {}

  public func route(
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
  public func route(
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
    if let simpleRoute = simpleVisibilityRoute(
      source: source,
      target: target,
      context: context,
      prepared: prepared
    ) {
      return (simpleRoute, Self.routeCost(points: simpleRoute.points))
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
    let searchPrepared = searchObstacles(
      source: source,
      target: target,
      context: context,
      prepared: prepared
    )
    let baseParams = VisibilityAttemptParameters(
      laneOffset: 0,
      searchPrepared: searchPrepared,
      validationPrepared: prepared
    )
    for laneOffset in Self.retryLaneOffsets {
      let params = VisibilityAttemptParameters(
        laneOffset: laneOffset,
        searchPrepared: baseParams.searchPrepared,
        validationPrepared: baseParams.validationPrepared
      )
      if let attempt = visibilityRouteAttempt(
        source: source, target: target, context: context, params: params
      ) {
        return (attempt, Self.routeCost(points: attempt.points))
      }
    }
    if searchPrepared.count != prepared.count {
      for laneOffset in Self.retryLaneOffsets {
        let params = VisibilityAttemptParameters(
          laneOffset: laneOffset,
          searchPrepared: prepared,
          validationPrepared: prepared
        )
        if let attempt = visibilityRouteAttempt(
          source: source, target: target, context: context, params: params
        ) {
          return (attempt, Self.routeCost(points: attempt.points))
        }
      }
    }
    return applyFallbackSafetyRoute(
      source: source,
      target: target,
      context: context,
      prepared: prepared
    )
  }

  /// Applies the hand-coded fallback router, then checks whether the result
  /// pierces any raw obstacle and substitutes a detour if so. Returns a
  /// `(route, cost)` pair; cost is `nil` when the result is a pure fallback
  /// (no A* path was found).
  private func applyFallbackSafetyRoute(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext,
    prepared: [CGRect]
  ) -> (route: PolicyCanvasEdgeRoute, cost: CGFloat?) {
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
    let rawSafetyObstacles = rawObstaclesExcludingEndpointFrames(
      source: source,
      target: target,
      sourceActual: context.sourceActual,
      targetActual: context.targetActual,
      raw: context.obstacles
    )
    if policyCanvasRouteIntersectsObstacles(
      normalizedFallbackPoints,
      obstacles: rawSafetyObstacles
    ),
      let rawDetourPoints = fallbackDetourPoints(
        source: source,
        target: target,
        obstacles: rawSafetyObstacles,
        lineSpacing: context.lineSpacing
      )
    {
      return (
        PolicyCanvasEdgeRoute(
          points: rawDetourPoints,
          labelPosition: Self.labelPosition(for: rawDetourPoints)
        ),
        Self.routeCost(points: rawDetourPoints)
      )
    }
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
  func visibilityRouteAttempt(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext,
    params: VisibilityAttemptParameters
  ) -> PolicyCanvasEdgeRoute? {
    let attemptContext =
      params.laneOffset == 0
      ? context
      : PolicyCanvasRouteContext(
        lane: context.lane + params.laneOffset,
        groups: context.groups,
        sourceGroupID: context.sourceGroupID,
        targetGroupID: context.targetGroupID,
        obstacles: context.obstacles,
        obstaclesAreCanonical: true,
        sourceActual: context.sourceActual,
        targetActual: context.targetActual,
        lineSpacing: context.lineSpacing,
        corridorHint: context.corridorHint
      )
    let gridAxes = visibilityGridAxes(
      source: source,
      target: target,
      context: attemptContext,
      prepared: params.searchPrepared
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
        obstacles: params.searchPrepared
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
    let snapValidationObstacles = params.validationPrepared.map {
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
      sourceActual ?? source,
      targetActual ?? target,
    ]
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

  func rawObstaclesExcludingEndpointFrames(
    source: CGPoint,
    target: CGPoint,
    sourceActual: CGPoint?,
    targetActual: CGPoint?,
    raw: [CGRect]
  ) -> [CGRect] {
    let dropPoints = [
      sourceActual ?? source,
      targetActual ?? target,
    ]
    return raw.filter { rect in
      let ownFrame = rect.insetBy(dx: -Self.endpointDropProbe, dy: -Self.endpointDropProbe)
      return !dropPoints.contains(where: { ownFrame.contains($0) })
    }
  }

}
