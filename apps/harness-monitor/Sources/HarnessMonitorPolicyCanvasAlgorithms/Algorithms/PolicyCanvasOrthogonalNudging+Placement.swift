import CoreGraphics

extension PolicyCanvasOrthogonalNudgingRouteProcessing {
  /// Route entries for every edge, segment-decomposed once per spread iteration.
  /// `bestSpread` reads the fixed (non-channel) routes from here instead of
  /// re-decomposing them for each channel; after a channel is applied only its own
  /// edges' entries are refreshed.
  func entryCache(
    of pointsByEdge: [String: [CGPoint]]
  ) -> [String: PolicyCanvasNudgeRouteMetrics.RouteEntry] {
    pointsByEdge.reduce(into: [:]) { cache, element in
      cache[element.key] = PolicyCanvasNudgeRouteMetrics.entry(
        id: element.key, points: element.value
      )
    }
  }

  func routeEntriesSortedByMinX<S: Sequence>(
    _ entries: S
  ) -> [PolicyCanvasNudgeRouteMetrics.RouteEntry]
  where S.Element == PolicyCanvasNudgeRouteMetrics.RouteEntry {
    entries.sorted { left, right in
      if left.bounds.minX != right.bounds.minX {
        return left.bounds.minX < right.bounds.minX
      }
      return left.id < right.id
    }
  }

  func displayedPoints(
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
  func bestSpread(
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
    let candidatePlacements = placements(from: offsets, routeCount: context.working.count)
    let interactionBand = movedInteractionBand(
      floor: channelPoints,
      candidates: candidatePlacements,
      original: context.original
    )
    let fixed = relevantFixed(
      channelEdges: channelEdges,
      entries: context.orderedEntries,
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
    let floorEntries = sortedEdges.compactMap { context.entries[$0] }
    let floor = PolicyCanvasNudgeRouteMetrics.localPenalty(
      movedEntries: floorEntries,
      scoring: scoring
    )
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

  struct SpreadSelectionContext {
    let working: [String: [CGPoint]]
    let original: [String: [CGPoint]]
    let entries: [String: PolicyCanvasNudgeRouteMetrics.RouteEntry]
    let orderedEntries: [PolicyCanvasNudgeRouteMetrics.RouteEntry]
    let obstacles: [CGRect]
    let baseline: PolicyCanvasNudgeRouteMetrics.Baseline
  }

  /// Fixed (non-channel) routes that can interact with this channel: routes whose
  /// segments enter the padded envelope swept by the displayed moved routes across
  /// every placement. The envelope is built from terminal-preserved candidate
  /// routes, so restored port bridges cannot hide crossings from the scorer.
  func relevantFixed(
    channelEdges: Set<String>,
    entries: [PolicyCanvasNudgeRouteMetrics.RouteEntry],
    band: CGRect?
  ) -> [PolicyCanvasNudgeRouteMetrics.RouteEntry] {
    guard let band else {
      return entries.filter { !channelEdges.contains($0.id) }
    }
    var fixed: [PolicyCanvasNudgeRouteMetrics.RouteEntry] = []
    for entry in entries {
      guard !entry.bounds.isNull else {
        continue
      }
      if entry.bounds.minX > band.maxX {
        break
      }
      guard entry.bounds.maxX >= band.minX,
        !channelEdges.contains(entry.id),
        PolicyCanvasNudgeRouteMetrics.segmentsEnter(entry, band)
      else {
        continue
      }
      fixed.append(entry)
    }
    return fixed
  }

  func movedInteractionBand(
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
  /// their reverse. The zero-shift floor in `bestSpread` still wins unless one
  /// placement strictly improves on it, so saturated corridors remain unchanged
  /// instead of being routed through a crossing/body hit. Earlier versions also
  /// slid the separated band by several lane widths; that made large policy
  /// samples spend most of their route budget evaluating near-duplicate
  /// placements for marginal label-free aesthetics.
  func placements(
    from offsets: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)],
    routeCount: Int
  ) -> [[(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]] {
    if routeCount > reducedPlacementRouteCount {
      return [offsets, offsets.map { ($0.segment, -$0.offset) }]
    }
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
  func ordered(
    _ channels: [[PolicyCanvasNudgeSegment]]
  ) -> [[PolicyCanvasNudgeSegment]] {
    channels.sorted { left, right in
      key(for: left) < key(for: right)
    }
  }

  func key(for channel: [PolicyCanvasNudgeSegment]) -> String {
    let lowestEdge = channel.map(\.edgeID).min() ?? ""
    let position = Int((channel.first?.position ?? 0).rounded())
    let lowerBound = Int((channel.map(\.lowerBound).min() ?? 0).rounded())
    return "\(lowestEdge)|\(position)|\(lowerBound)"
  }

  func apply(
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
  func decompose(_ pointsByEdge: [String: [CGPoint]]) -> [PolicyCanvasNudgeSegment] {
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

  func residualPairKey(
    _ left: PolicyCanvasNudgeSegment,
    _ right: PolicyCanvasNudgeSegment
  ) -> String {
    [
      left.edgeID,
      String(left.startIndex),
      right.edgeID,
      String(right.startIndex),
    ].joined(separator: "|")
  }
}
