import CoreGraphics

/// Crossing-aware global orthogonal nudging - the route post-processing default.
///
/// The first-feasible selector routes every edge independently, so members of a
/// fan-in - or any edges that happen to run the same corridor - are left stacked
/// collinearly on one lane. The orthogonal nudge fans those stacks into parallel
/// lanes, which clears the overlaps, but it spreads each axis without consulting
/// the other: shifting a vertical riser to clear a same-axis overlap can push it
/// straight into another edge's horizontal stub span and introduce an X-crossing
/// the raw routing never had (proven on `pre-intake`x`pre-deny`,
/// `rv-else`x`dp-fail`, `coll-allow`x`coll-human`).
///
/// This pass clears the same overlaps but is crossing-aware. It reuses the nudge's
/// proven channel grouping and lane-offset maths, then for each channel scores
/// both spread directions against every other route and keeps the one that clears
/// the overlap without adding an orthogonal-axis crossing or a body hit. A
/// zero-shift floor makes the choice a ratchet: a channel can be left stacked, but
/// is never spread into a new crossing or a node body. The route worker restores
/// the first and last port stubs after this pass, so the terminal-on-dot marker
/// contract survives interior lane spreading.
struct PolicyCanvasOrthogonalNudgingRouteProcessing: PolicyCanvasRoutePostProcessingAlgorithm {
  /// Interior collinear overlap longer than this reads as a stacked rail and must
  /// be cleared - matches the fan-in channel gate threshold.
  let overlapThreshold: CGFloat = 8
  /// Spreading one axis shifts the perpendicular extent of the other axis's
  /// segments, so a second pass settles residual same-axis stacks after the other
  /// axis moved. More passes had diminishing visual return and dominated large
  /// graphs.
  let iterations = 2
  /// The exact splitter only runs after terminal preservation, where splitting
  /// one stacked rail changes route point indices and can expose a second-order
  /// bridge overlap. Recompute after each accepted split, but cap applications so
  /// stress samples cannot turn cleanup into an unbounded routing pass.
  let exactSplitApplicationLimit = 512
  /// Large graphs get a smaller broad-pass channel budget and rely on the
  /// pair-only cleanup below for the few residual tight lanes.
  let exactFastSplitApplicationLimit = 256
  /// Large samples skip candidate scoring, but still recompute channels between
  /// split batches. One stale decomposition can assign conflicting shifts to a
  /// route that participates in several nearby corridors; a bounded batch loop
  /// keeps the fast path deterministic without letting cleanup dominate routing.
  let exactFastSplitRoundLimit = 8
  /// After the bulk fast pass, clear a handful of residual channels one at a
  /// time. Stress samples often end with only one or two source-side pairs after
  /// the broad batches spend their cap on denser buses.
  let exactFastResidualSplitLimit = 16
  /// Tolerance for classifying a segment as axis-aligned, matching the nudge.
  let axisTolerance: CGFloat = 1
  /// Lane width used to slide a spread band into a clearer corridor position.
  let laneGap = PolicyCanvasVisibilityRouter.laneSpreadStep
  /// Last-resort exact-lane de-aliasing band. This intentionally stays much
  /// smaller than the visual lane spacing: it is only used when full spacing
  /// would introduce a body hit, and only to eliminate exact corridor reuse.
  let exactMicroSplitBand = PolicyCanvasVisibilityRouter.channelStep
  /// Above this route count the full slide search costs more than it buys; keep
  /// deterministic ordered/reversed spreads and rely on the zero-shift floor to
  /// avoid regressions.
  let reducedPlacementRouteCount = 80
  /// Above this size the crossing-aware scorer itself becomes the dominant cost.
  /// Use the same deterministic channel decomposition and lane offsets, but skip
  /// per-candidate global scoring. The per-route body-hit guard below still
  /// rejects shifts that would pierce node bodies.
  let directPlacementRouteCount = 1_000

  func processRoutes(
    input: PolicyCanvasRoutePostProcessingInput
  ) -> [String: PolicyCanvasEdgeRoute] {
    let obstacles = policyCanvasCanonicalObstacles(
      input.prepared.nodes.map(\.frame) + policyCanvasGroupTitleFrames(input.prepared.groups)
    )
    let originalPointsByEdge = input.routes.mapValues(\.points)
    var pointsByEdge = input.routes.mapValues {
      PolicyCanvasVisibilityRouter.compressCollinear($0.points)
    }
    if pointsByEdge.count > directPlacementRouteCount {
      pointsByEdge = directSpread(pointsByEdge, obstacles: obstacles)
    } else {
      pointsByEdge = spread(pointsByEdge, original: originalPointsByEdge, obstacles: obstacles)
    }
    let edgesByID = Dictionary(uniqueKeysWithValues: input.prepared.edges.map { ($0.id, $0) })
    let guardedRoutes = applyRouteGuards(
      pointsByEdge: pointsByEdge,
      originalRoutes: input.routes,
      obstacles: obstacles,
      edgesByID: edgesByID,
      prepared: input.prepared
    )
    return guardedRoutes
  }

  func applyRouteGuards(
    pointsByEdge: [String: [CGPoint]],
    originalRoutes: [String: PolicyCanvasEdgeRoute],
    obstacles: [CGRect],
    edgesByID: [String: PolicyCanvasEdge],
    prepared: PolicyCanvasPreparedRouteInput
  ) -> [String: PolicyCanvasEdgeRoute] {
    pointsByEdge.reduce(into: [:]) { result, entry in
      let points = PolicyCanvasVisibilityRouter.compressCollinear(entry.value)
      let processed = PolicyCanvasEdgeRoute(
        points: points,
        labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
      )
      guard let original = originalRoutes[entry.key] else {
        result[entry.key] = processed
        return
      }
      guard processed.points != original.points else {
        result[entry.key] = processed
        return
      }
      let displayedProcessed = policyCanvasRoutePreservingTerminalStubs(
        original: original,
        processed: processed
      )
      guard displayedProcessed.points != original.points else {
        result[entry.key] = processed
        return
      }
      let bodyObstacles =
        edgesByID[entry.key].map {
          postProcessingBodyObstacles(edge: $0, prepared: prepared)
        } ?? obstacles
      let routeEnvelope = policyCanvasRouteBounds(original.points)
        .union(policyCanvasRouteBounds(displayedProcessed.points))
        .insetBy(dx: -1, dy: -1)
      let nearbyObstacles = bodyObstacles.filter { $0.intersects(routeEnvelope) }
      if !nearbyObstacles.isEmpty,
        policyCanvasRouteIntersectsObstacles(displayedProcessed, obstacles: nearbyObstacles),
        !policyCanvasRouteIntersectsObstacles(original, obstacles: nearbyObstacles)
      {
        result[entry.key] = original
      } else {
        result[entry.key] = processed
      }
    }
  }

  func postProcessingBodyObstacles(
    edge: PolicyCanvasEdge,
    prepared: PolicyCanvasPreparedRouteInput
  ) -> [CGRect] {
    let endpointNodeIDs = Set([edge.source.nodeID, edge.target.nodeID])
    return prepared.nodes
      .filter { !endpointNodeIDs.contains($0.id) }
      .map(\.frame)
      + policyCanvasGroupTitleFrames(prepared.groups)
  }

  /// Iteratively spread shared lanes into parallel lanes, choosing for every
  /// channel the spread direction that clears its overlap without introducing an
  /// orthogonal-axis crossing or a body hit. `baseline` is the pre-spread routing -
  /// the crossing/body-hit set the result must never exceed.
  func spread(
    _ routes: [String: [CGPoint]],
    original: [String: [CGPoint]],
    obstacles: [CGRect]
  ) -> [String: [CGPoint]] {
    let baseline = PolicyCanvasNudgeRouteMetrics.baseline(
      of: displayedPoints(routes, preserving: original),
      obstacles: obstacles
    )
    let processor = PolicyCanvasOrthogonalNudgeProcessor(
      obstacles: obstacles,
      fans: PolicyCanvasFanContext.make(from: routes)
    )
    var pointsByEdge = routes
    let iterationLimit = pointsByEdge.count > reducedPlacementRouteCount ? 1 : iterations
    for _ in 0..<iterationLimit {
      var working = pointsByEdge
      var entries = entryCache(of: displayedPoints(working, preserving: original))
      var orderedEntries = routeEntriesSortedByMinX(entries.values)
      var applied = false
      let segments = decompose(working)
      for axis in [PolicyCanvasSegmentAxis.horizontal, .vertical] {
        let channels = ordered(processor.channels(in: segments.filter { $0.axis == axis }))
        for channel in channels where channel.count > 1 {
          let offsets = processor.laneOffsets(for: channel)
          guard !offsets.isEmpty else {
            continue
          }
          if let chosen = bestSpread(
            offsets,
            context: SpreadSelectionContext(
              working: working,
              original: original,
              entries: entries,
              orderedEntries: orderedEntries,
              obstacles: obstacles,
              baseline: baseline
            )
          ) {
            working = apply(chosen, to: working)
            for edgeID in Set(chosen.map { $0.segment.edgeID }) where working[edgeID] != nil {
              let displayed = displayedPoints(
                [edgeID: working[edgeID] ?? []],
                preserving: original
              )
              entries[edgeID] = PolicyCanvasNudgeRouteMetrics.entry(
                id: edgeID,
                points: displayed[edgeID] ?? working[edgeID] ?? []
              )
            }
            orderedEntries = routeEntriesSortedByMinX(entries.values)
            applied = true
          }
        }
      }
      guard applied else {
        break
      }
      pointsByEdge = working.mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0) }
    }
    return pointsByEdge
  }

  /// Linear-ish large-graph pass: split occupied same-axis corridors into
  /// deterministic lanes without scoring every lane candidate against every
  /// other route. This is intentionally only a complexity fallback; smaller
  /// graphs keep the crossing-aware scorer above.
  func directSpread(
    _ routes: [String: [CGPoint]],
    obstacles: [CGRect]
  ) -> [String: [CGPoint]] {
    let processor = PolicyCanvasOrthogonalNudgeProcessor(
      obstacles: obstacles,
      fans: PolicyCanvasFanContext.make(from: routes)
    )
    var working = routes
    for axis in [PolicyCanvasSegmentAxis.horizontal, .vertical] {
      let segments = decompose(working)
      let channels = ordered(processor.channels(in: segments.filter { $0.axis == axis }))
      for channel in channels where channel.count > 1 {
        let offsets = processor.laneOffsets(for: channel)
        guard !offsets.isEmpty else {
          continue
        }
        working = apply(offsets, to: working)
      }
      working = working.mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0) }
    }
    return working
  }
}
