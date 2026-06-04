import CoreGraphics

/// Crossing-aware global route post-process (Path A).
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
/// is never spread into a new crossing or a node body. Port stubs (a route's first
/// and last segment) are never shifted, so the terminal-on-dot marker contract
/// holds by construction.
struct PolicyCanvasClaudeCrossingAwareRouteProcessing: PolicyCanvasRoutePostProcessingAlgorithm {
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
    var pointsByEdge = input.routes.mapValues {
      PolicyCanvasVisibilityRouter.compressCollinear($0.points)
    }
    pointsByEdge = spread(pointsByEdge, obstacles: obstacles)
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
  /// orthogonal-axis crossing or a body hit. `base` is the pre-spread routing - the
  /// crossing/body-hit count the result must never exceed.
  private func spread(
    _ routes: [String: [CGPoint]],
    obstacles: [CGRect]
  ) -> [String: [CGPoint]] {
    let base = PolicyCanvasClaudeRouteMetrics.snapshot(
      of: routes, obstacles: obstacles, overlapThreshold: overlapThreshold
    )
    let processor = PolicyCanvasOrthogonalNudgeProcessor(
      obstacles: obstacles,
      fans: PolicyCanvasFanContext.make(from: routes)
    )
    var pointsByEdge = routes
    for _ in 0..<iterations {
      var working = pointsByEdge
      var applied = false
      let segments = decompose(working)
      for axis in [PolicyCanvasSegmentAxis.horizontal, .vertical] {
        let channels = ordered(processor.channels(in: segments.filter { $0.axis == axis }))
        for channel in channels where channel.count > 1 {
          let offsets = processor.laneOffsets(for: channel)
          guard !offsets.isEmpty else {
            continue
          }
          if let chosen = bestSpread(offsets, working: working, obstacles: obstacles, base: base) {
            working = apply(chosen, to: working)
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

  /// Score both spread directions for one channel against the live routing and
  /// return the better, or nil to leave the channel stacked. The zero-shift state
  /// is the floor, so a spread is chosen only when it does not add a body hit or a
  /// crossing over leaving the channel alone - and, among non-regressing options,
  /// the one that removes the most overlap wins.
  private func bestSpread(
    _ offsets: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)],
    working: [String: [CGPoint]],
    obstacles: [CGRect],
    base: PolicyCanvasClaudeRouteMetrics.Snapshot
  ) -> [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]? {
    var chosen: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]?
    var bestPenalty = penalty(of: working, obstacles: obstacles, base: base)
    for candidate in placements(from: offsets) {
      let candidatePenalty = penalty(
        of: apply(candidate, to: working), obstacles: obstacles, base: base
      )
      if candidatePenalty.isLower(than: bestPenalty) {
        bestPenalty = candidatePenalty
        chosen = candidate
      }
    }
    return chosen
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
    let slides: [CGFloat] = [0, laneGap, -laneGap, 2 * laneGap, -2 * laneGap]
    var result: [[(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]] = []
    for ordering in [offsets, offsets.map { ($0.segment, -$0.offset) }] {
      for slide in slides {
        result.append(ordering.map { ($0.segment, $0.offset + slide) })
      }
    }
    return result
  }

  private func penalty(
    of pointsByEdge: [String: [CGPoint]],
    obstacles: [CGRect],
    base: PolicyCanvasClaudeRouteMetrics.Snapshot
  ) -> PolicyCanvasClaudeRouteMetrics.Penalty {
    PolicyCanvasClaudeRouteMetrics.penalty(
      of: PolicyCanvasClaudeRouteMetrics.snapshot(
        of: pointsByEdge, obstacles: obstacles, overlapThreshold: overlapThreshold
      ),
      base: base
    )
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
  /// first and last segment of each route are port stubs and are excluded; they
  /// still move because they share a point with the interior segment they feed.
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
