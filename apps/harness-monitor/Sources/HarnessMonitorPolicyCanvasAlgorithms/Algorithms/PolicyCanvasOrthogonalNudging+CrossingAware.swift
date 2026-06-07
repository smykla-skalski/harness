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
  private let overlapThreshold: CGFloat = 8
  /// Spreading one axis shifts the perpendicular extent of the other axis's
  /// segments, so a few passes settle the residual; it converges well before this.
  private let iterations = 4
  /// Tolerance for classifying a segment as axis-aligned, matching the nudge.
  private let axisTolerance: CGFloat = 1
  /// Lane width used to slide a spread band into a clearer corridor position.
  private let laneGap = PolicyCanvasVisibilityRouter.laneSpreadStep

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
    pointsByEdge = spread(pointsByEdge, original: originalPointsByEdge, obstacles: obstacles)
    return pointsByEdge.reduce(into: [:]) { result, entry in
      let points = PolicyCanvasVisibilityRouter.compressCollinear(entry.value)
      result[entry.key] = PolicyCanvasEdgeRoute(
        points: points,
        labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
      )
    }
  }

  /// Iteratively spread shared lanes into parallel lanes, choosing for every
  /// channel the spread direction that clears its overlap without introducing an
  /// orthogonal-axis crossing or a body hit. `baseline` is the pre-spread routing -
  /// the crossing/body-hit set the result must never exceed.
  private func spread(
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
    for _ in 0..<iterations {
      var working = pointsByEdge
      var entries = entryCache(of: displayedPoints(working, preserving: original))
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

  /// Route entries for every edge, segment-decomposed once per spread iteration.
  /// `bestSpread` reads the fixed (non-channel) routes from here instead of
  /// re-decomposing them for each channel; after a channel is applied only its own
  /// edges' entries are refreshed.
  private func entryCache(
    of pointsByEdge: [String: [CGPoint]]
  ) -> [String: PolicyCanvasNudgeRouteMetrics.RouteEntry] {
    pointsByEdge.reduce(into: [:]) { cache, element in
      cache[element.key] = PolicyCanvasNudgeRouteMetrics.entry(
        id: element.key, points: element.value
      )
    }
  }

  private func displayedPoints(
    _ pointsByEdge: [String: [CGPoint]],
    preserving original: [String: [CGPoint]]
  ) -> [String: [CGPoint]] {
    pointsByEdge.reduce(into: [:]) { result, entry in
      guard let originalPoints = original[entry.key] else {
        result[entry.key] = entry.value
        return
      }
      let route = policyCanvasRoutePreservingTerminalStubs(
        original: PolicyCanvasEdgeRoute(points: originalPoints, labelPosition: .zero),
        processed: PolicyCanvasEdgeRoute(points: entry.value, labelPosition: .zero)
      )
      result[entry.key] = route.points
    }
  }

  /// Score every candidate placement for one channel and return the best, or nil
  /// to leave the channel stacked. Only the channel's own edges move, so the rest
  /// of the scene is built once into `fixed` and each placement is scored against
  /// it - identical ordering to a full-scene rescore, still limited to pairs that
  /// involve one of the channel edges. The
  /// zero-shift state is the floor, so a spread is chosen only when it does not add
  /// a body hit or a crossing over leaving the channel alone, and among
  /// non-regressing options the one that removes the most overlap wins.
  private func bestSpread(
    _ offsets: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)],
    context: SpreadSelectionContext
  ) -> [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]? {
    let channelEdges = Set(offsets.map { $0.segment.edgeID })
    let sortedEdges = channelEdges.sorted()
    // Score against only the channel's own points: every placement shifts the same
    // few edges, so slicing them out of `working` avoids copying the whole route
    // dictionary per candidate while `localPenalty` reads exactly these ids.
    let channelPoints = channelEdges.reduce(into: [String: [CGPoint]]()) { slice, id in
      slice[id] = context.working[id]
    }
    let candidatePlacements = placements(from: offsets)
    let interactionBand = movedInteractionBand(
      floor: channelPoints,
      candidates: candidatePlacements,
      original: context.original
    )
    let fixed = relevantFixed(
      channelEdges: channelEdges,
      entries: context.entries,
      band: interactionBand
    )
    // Only obstacles inside the moved-route envelope can be newly hit by a shift;
    // an edge that hits anything outside it already did so before the shift and so
    // sits in the baseline already.
    let nearbyObstacles =
      interactionBand.map { rect in context.obstacles.filter { $0.intersects(rect) } }
      ?? context.obstacles
    let scoring = PolicyCanvasNudgeRouteMetrics.Scoring(
      fixed: fixed,
      obstacles: nearbyObstacles,
      baseline: context.baseline,
      overlapThreshold: overlapThreshold,
      minimumLaneSpacing: laneGap
    )
    func localPenalty(
      of state: [String: [CGPoint]]
    ) -> PolicyCanvasNudgeRouteMetrics.LocalPenalty {
      PolicyCanvasNudgeRouteMetrics.localPenalty(
        channelEdges: sortedEdges,
        pointsByEdge: displayedPoints(state, preserving: context.original),
        scoring: scoring
      )
    }
    // Zero-shift floor. If the channel already has no overlap, body hit, or added
    // crossing there is nothing a spread could improve - no placement can score
    // below an all-zero penalty - so skip the search entirely.
    let floor = localPenalty(of: channelPoints)
    guard floor.addedBodyHits > 0 || floor.addedCrossings > 0 || floor.overlapPairs > 0 else {
      return nil
    }
    var chosen: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]?
    var bestPenalty = floor
    for candidate in candidatePlacements {
      let candidatePenalty = localPenalty(of: apply(candidate, to: channelPoints))
      if candidatePenalty.isLower(than: bestPenalty) {
        bestPenalty = candidatePenalty
        chosen = candidate
        // A fully clean placement - no overlap, no added crossing, no body hit - is
        // optimal; nothing can score below an all-zero penalty, so stop the search.
        // The first placement to reach it is exactly what a full scan would pick.
        if candidatePenalty.addedBodyHits == 0, candidatePenalty.addedCrossings == 0,
          candidatePenalty.overlapPairs == 0
        {
          break
        }
      }
    }
    return chosen
  }

  private struct SpreadSelectionContext {
    let working: [String: [CGPoint]]
    let original: [String: [CGPoint]]
    let entries: [String: PolicyCanvasNudgeRouteMetrics.RouteEntry]
    let obstacles: [CGRect]
    let baseline: PolicyCanvasNudgeRouteMetrics.Baseline
  }

  /// Fixed (non-channel) routes that can interact with this channel: routes whose
  /// segments enter the padded envelope swept by the displayed moved routes across
  /// every placement. The envelope is built from terminal-preserved candidate
  /// routes, so restored port bridges cannot hide crossings from the scorer.
  private func relevantFixed(
    channelEdges: Set<String>,
    entries: [String: PolicyCanvasNudgeRouteMetrics.RouteEntry],
    band: CGRect?
  ) -> [PolicyCanvasNudgeRouteMetrics.RouteEntry] {
    let fixed = entries.keys.sorted()
      .filter { !channelEdges.contains($0) }
      .compactMap { entries[$0] }
    guard let band else {
      return fixed
    }
    return fixed.filter { entry in
      PolicyCanvasNudgeRouteMetrics.segmentsEnter(entry, band)
    }
  }

  private func movedInteractionBand(
    floor: [String: [CGPoint]],
    candidates: [[(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]],
    original: [String: [CGPoint]]
  ) -> CGRect? {
    var band = CGRect.null
    let padding = laneGap + 1
    for state in [floor] + candidates.map({ apply($0, to: floor) }) {
      let displayed = displayedPoints(state, preserving: original)
      for points in displayed.values {
        for (start, end) in zip(points, points.dropFirst()) where start != end {
          band = band.union(
            policyCanvasRouteSegmentFrame(start: start, end: end, padding: padding)
          )
        }
      }
    }
    return band.isNull ? nil : band
  }

  /// Spread placements to score for one channel: the fan/bus-ordered offsets and
  /// their reverse, each slid by a few lane widths in either direction. Sliding
  /// the already-separated band lets a crowded corridor's spread settle where it
  /// clears the stack without cutting a foreign stub; reversing covers the non-fan
  /// bus whose crossing-free order is the opposite one. The zero-shift floor in
  /// `bestSpread` still wins unless one placement strictly improves on it.
  private func placements(
    from offsets: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]
  ) -> [[(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]] {
    let halfGap = laneGap / 2
    let slides: [CGFloat] =
      offsets.count.isMultiple(of: 2)
      ? [halfGap, -halfGap, 0, laneGap, -laneGap]
      : [0, laneGap, -laneGap, 2 * laneGap, -2 * laneGap]
    var result: [[(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]] = []
    for ordering in [offsets, offsets.map { ($0.segment, -$0.offset) }] {
      for slide in slides {
        result.append(ordering.map { ($0.segment, $0.offset + slide) })
      }
    }
    return result
  }

  /// Deterministic channel order so the greedy per-channel choice is independent
  /// of the dictionary iteration order the nudge primitives hand back.
  private func ordered(
    _ channels: [[PolicyCanvasNudgeSegment]]
  ) -> [[PolicyCanvasNudgeSegment]] {
    channels.sorted { left, right in
      key(for: left) < key(for: right)
    }
  }

  private func key(for channel: [PolicyCanvasNudgeSegment]) -> String {
    let lowestEdge = channel.map(\.edgeID).min() ?? ""
    let position = Int((channel.first?.position ?? 0).rounded())
    let lowerBound = Int((channel.map(\.lowerBound).min() ?? 0).rounded())
    return "\(lowestEdge)|\(position)|\(lowerBound)"
  }

  private func apply(
    _ shifts: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)],
    to pointsByEdge: [String: [CGPoint]]
  ) -> [String: [CGPoint]] {
    var result = pointsByEdge
    for (segment, offset) in shifts where abs(offset) > 0 {
      guard var points = result[segment.edgeID], segment.startIndex + 1 < points.count else {
        continue
      }
      switch segment.axis {
      case .horizontal:
        points[segment.startIndex].y += offset
        points[segment.startIndex + 1].y += offset
      case .vertical:
        points[segment.startIndex].x += offset
        points[segment.startIndex + 1].x += offset
      }
      result[segment.edgeID] = points
    }
    return result
  }

  /// Split every route into interior axis-aligned segments, tagged exactly as the
  /// nudge expects so the reused `channels`/`laneOffsets` behave identically. The
  /// first and last segment of each route are port stubs and are excluded here;
  /// the worker reattaches those stubs after post-processing.
  /// Edges are walked in sorted order so the segment list is order-independent.
  private func decompose(_ pointsByEdge: [String: [CGPoint]]) -> [PolicyCanvasNudgeSegment] {
    var segments: [PolicyCanvasNudgeSegment] = []
    for edgeID in pointsByEdge.keys.sorted() {
      guard let points = pointsByEdge[edgeID], points.count >= 4 else {
        continue
      }
      for index in 1..<(points.count - 2) {
        let start = points[index]
        let end = points[index + 1]
        let deltaX = abs(start.x - end.x)
        let deltaY = abs(start.y - end.y)
        let axis: PolicyCanvasSegmentAxis
        if deltaY <= axisTolerance, deltaX > axisTolerance {
          axis = .horizontal
        } else if deltaX <= axisTolerance, deltaY > axisTolerance {
          axis = .vertical
        } else {
          continue
        }
        let beforePerpendicular = axis == .horizontal ? points[index - 1].y : points[index - 1].x
        let afterPerpendicular = axis == .horizontal ? points[index + 2].y : points[index + 2].x
        let startSpan = axis == .horizontal ? start.x : start.y
        let endSpan = axis == .horizontal ? end.x : end.y
        let startIsLower = startSpan <= endSpan
        segments.append(
          PolicyCanvasNudgeSegment(
            edgeID: edgeID,
            startIndex: index,
            axis: axis,
            position: axis == .horizontal ? start.y : start.x,
            lowerBound: min(startSpan, endSpan),
            upperBound: max(startSpan, endSpan),
            entryPerpendicular: beforePerpendicular,
            exitPerpendicular: afterPerpendicular,
            lowerConnection: startIsLower ? beforePerpendicular : afterPerpendicular,
            upperConnection: startIsLower ? afterPerpendicular : beforePerpendicular
          )
        )
      }
    }
    return segments
  }
}
