import CoreGraphics

extension PolicyCanvasPreparedRouteInput {
  /// Last-resort orthogonal go-around for an edge whose standard re-route still
  /// cuts through a node body. The visibility A* (and its alternate-side
  /// retries) can fail to find the clear right-angle path that geometrically
  /// exists when a node is dropped into an open lane on top of an existing wire
  /// - the route then keeps crossing the body, which persists after the drop.
  ///
  /// This builds simple L- and Z-shaped detours between the crossing route's
  /// terminals, each turning at a clearance outside an obstacle edge, validates
  /// every candidate against the full obstacle set (minus the frames the edge
  /// legitimately touches at its own endpoints), and returns the cheapest clear
  /// one with the original terminal stubs preserved so the wire stays attached
  /// to its ports. Returns `nil` when nothing clears (the edge is genuinely
  /// boxed in, e.g. the node was dropped on top of other bodies), so the caller
  /// keeps the prior route rather than inventing a worse one.
  ///
  /// Router-agnostic on purpose: it reasons only about obstacle rectangles and
  /// the route polyline, so it survives a future swap of the underlying router.
  func policyCanvasBodyHitGoAroundRoute(
    edge: PolicyCanvasEdge,
    crossingRoute: PolicyCanvasEdgeRoute,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasEdgeRoute? {
    guard let source = crossingRoute.points.first,
      let target = crossingRoute.points.last,
      source != target
    else {
      return nil
    }
    let clearance = max(
      PolicyCanvasLayout.edgePortTurnMinimumLead,
      PolicyCanvasLayout.defaultEdgeLineSpacing * 2
    )
    let probe = PolicyCanvasVisibilityRouter.endpointDropProbe
    // Validate against every obstacle except the ones the edge touches at its
    // own terminals, so a valid detour is not rejected for grazing its own
    // source or target node body.
    let obstacles = routingObstacles().filter { rect in
      let own = rect.insetBy(dx: -probe, dy: -probe)
      return !own.contains(source) && !own.contains(target)
    }
    guard !obstacles.isEmpty else {
      return nil
    }

    let detourYs = obstacles.flatMap { [$0.minY - clearance, $0.maxY + clearance] }
    let detourXs = obstacles.flatMap { [$0.minX - clearance, $0.maxX + clearance] }
    var candidates: [[CGPoint]] = []
    candidates.reserveCapacity(detourYs.count + detourXs.count)
    for y in detourYs {
      candidates.append([
        source, CGPoint(x: source.x, y: y), CGPoint(x: target.x, y: y), target,
      ])
    }
    for x in detourXs {
      candidates.append([
        source, CGPoint(x: x, y: source.y), CGPoint(x: x, y: target.y), target,
      ])
    }

    var best: (route: PolicyCanvasEdgeRoute, cost: CGFloat)?
    for points in candidates {
      let candidate = PolicyCanvasEdgeRoute(
        points: points,
        labelPosition: points[points.count / 2]
      )
      guard !policyCanvasRouteIntersectsObstacles(candidate, obstacles: obstacles) else {
        continue
      }
      let cost = policyCanvasManhattanLength(points)
      if best == nil || cost < (best?.cost ?? .infinity) {
        best = (candidate, cost)
      }
    }
    guard let detour = best?.route else {
      return nil
    }

    // Re-attach the original port stubs so the wire still meets its dots, then
    // confirm the bridged result actually clears the body before adopting it.
    let bridged = policyCanvasRoutePreservingTerminalStubs(
      original: crossingRoute,
      processed: detour
    )
    guard precomputedBodyHits(edge: edge, route: bridged, nodeIndex: nodeIndex).isEmpty else {
      return nil
    }
    return bridged
  }
}

/// Total orthogonal (Manhattan) travel of a polyline, used only to rank clear
/// go-around candidates so the detour closest to the direct path wins.
func policyCanvasManhattanLength(_ points: [CGPoint]) -> CGFloat {
  zip(points, points.dropFirst()).reduce(0) { total, pair in
    total + abs(pair.1.x - pair.0.x) + abs(pair.1.y - pair.0.y)
  }
}
