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
  /// segments, so a second pass settles residual same-axis stacks after the other
  /// axis moved. More passes had diminishing visual return and dominated large
  /// graphs.
  private let iterations = 2
  /// The exact splitter only runs after terminal preservation, where splitting
  /// one stacked rail changes route point indices and can expose a second-order
  /// bridge overlap. Recompute after each accepted split, but cap applications so
  /// stress samples cannot turn cleanup into an unbounded routing pass.
  private let exactSplitApplicationLimit = 512
  /// Large graphs get a smaller broad-pass channel budget and rely on the
  /// pair-only cleanup below for the few residual tight lanes.
  private let exactFastSplitApplicationLimit = 256
  /// Large samples skip candidate scoring, but still recompute channels between
  /// split batches. One stale decomposition can assign conflicting shifts to a
  /// route that participates in several nearby corridors; a bounded batch loop
  /// keeps the fast path deterministic without letting cleanup dominate routing.
  private let exactFastSplitRoundLimit = 8
  /// After the bulk fast pass, clear a handful of residual channels one at a
  /// time. Stress samples often end with only one or two source-side pairs after
  /// the broad batches spend their cap on denser buses.
  private let exactFastResidualSplitLimit = 16
  /// Tolerance for classifying a segment as axis-aligned, matching the nudge.
  private let axisTolerance: CGFloat = 1
  /// Lane width used to slide a spread band into a clearer corridor position.
  private let laneGap = PolicyCanvasVisibilityRouter.laneSpreadStep
  /// Last-resort exact-lane de-aliasing band. This intentionally stays much
  /// smaller than the visual lane spacing: it is only used when full spacing
  /// would introduce a body hit, and only to eliminate exact corridor reuse.
  private let exactMicroSplitBand = PolicyCanvasVisibilityRouter.channelStep
  /// Above this route count the full slide search costs more than it buys; keep
  /// deterministic ordered/reversed spreads and rely on the zero-shift floor to
  /// avoid regressions.
  private let reducedPlacementRouteCount = 80
  /// Above this size the crossing-aware scorer itself becomes the dominant cost.
  /// Use the same deterministic channel decomposition and lane offsets, but skip
  /// per-candidate global scoring. The per-route body-hit guard below still
  /// rejects shifts that would pierce node bodies.
  private let directPlacementRouteCount = 1_000

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
    let guardedRoutes: [String: PolicyCanvasEdgeRoute] = pointsByEdge.reduce(into: [:]) {
      result, entry in
      let points = PolicyCanvasVisibilityRouter.compressCollinear(entry.value)
      let processed = PolicyCanvasEdgeRoute(
        points: points,
        labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
      )
      guard let original = input.routes[entry.key] else {
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
          postProcessingBodyObstacles(edge: $0, prepared: input.prepared)
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
    return guardedRoutes
  }

  private func postProcessingBodyObstacles(
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
  private func directSpread(
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

  /// Final deterministic splitter for crowded same-axis corridors. The
  /// crossing-aware spread above intentionally leaves saturated channels stacked
  /// when every candidate would add a crossing/body hit. Exact stacks and
  /// near-parallel lanes below the required spacing are still hard graph-quality
  /// errors, so this pass separates remaining channels by the full route lane
  /// spacing. It is bounded and uses the same stable channel ordering primitives
  /// as the scorer, keeping runtime predictable on stress samples.
  private func clearRemainingCollinearReuse(
    _ routes: [String: [CGPoint]],
    obstacles: [CGRect],
    accepts: ((String, PolicyCanvasEdgeRoute, PolicyCanvasEdgeRoute) -> Bool)? = nil
  ) -> [String: [CGPoint]] {
    var working = routes
    let processor = PolicyCanvasOrthogonalNudgeProcessor(
      obstacles: obstacles,
      fans: PolicyCanvasFanContext.make(from: routes)
    )
    if routes.count > reducedPlacementRouteCount {
      return clearRemainingCollinearReuseFast(routes, processor: processor)
    }
    var remainingApplications = exactSplitApplicationLimit
    while remainingApplications > 0 {
      var appliedInRound = false
      for axis in [PolicyCanvasSegmentAxis.horizontal, .vertical] {
        while remainingApplications > 0 {
          let channels = ordered(
            crowdedCorridorChannels(in: decompose(working).filter { $0.axis == axis })
          )
          var acceptedShifts: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)] = []
          var touchedEdgeIDs: Set<String> = []
          var acceptedChannelCount = 0
          for channel in channels where channel.count > 1 {
            let channelEdgeIDs = Set(channel.map(\.edgeID))
            guard touchedEdgeIDs.isDisjoint(with: channelEdgeIDs) else {
              continue
            }
            let offsets = fullLaneOffsets(for: channel, processor: processor)
            guard !offsets.isEmpty else {
              continue
            }
            for candidate in exactSplitPlacements(from: offsets, routeCount: working.count) {
              let next = applyExactSplit(candidate, to: working)
              guard next != working,
                exactSplit(next, isAcceptedFrom: working, shifts: candidate, accepts: accepts)
              else {
                continue
              }
              acceptedShifts.append(contentsOf: candidate)
              touchedEdgeIDs.formUnion(channelEdgeIDs)
              acceptedChannelCount += 1
              break
            }
          }
          guard !acceptedShifts.isEmpty else {
            break
          }
          let next = applyExactSplit(acceptedShifts, to: working)
          guard next != working else {
            break
          }
          working = next.mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0) }
          remainingApplications -= acceptedChannelCount
          appliedInRound = true
        }
      }
      guard appliedInRound else {
        break
      }
    }
    return working
  }

  private func clearRemainingCollinearReuseFast(
    _ routes: [String: [CGPoint]],
    processor: PolicyCanvasOrthogonalNudgeProcessor
  ) -> [String: [CGPoint]] {
    var working = routes
    var remainingApplications = exactFastSplitApplicationLimit
    for _ in 0..<exactFastSplitRoundLimit {
      var appliedInRound = false
      for axis in [PolicyCanvasSegmentAxis.horizontal, .vertical] {
        while remainingApplications > 0 {
          let channels = ordered(
            crowdedCorridorChannels(in: decompose(working).filter { $0.axis == axis })
          )
          var shifts: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)] = []
          var touchedEdgeIDs: Set<String> = []
          var acceptedChannelCount = 0
          for channel in channels where channel.count > 1 {
            let channelEdgeIDs = Set(channel.map(\.edgeID))
            guard touchedEdgeIDs.isDisjoint(with: channelEdgeIDs) else {
              continue
            }
            let offsets = fullLaneOffsets(for: channel, processor: processor)
            guard !offsets.isEmpty else {
              continue
            }
            shifts.append(contentsOf: offsets)
            touchedEdgeIDs.formUnion(channelEdgeIDs)
            acceptedChannelCount += 1
          }
          guard !shifts.isEmpty else {
            break
          }
          let next = applyExactSplit(shifts, to: working)
            .mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0) }
          guard next != working else {
            break
          }
          working = next
          remainingApplications -= acceptedChannelCount
          appliedInRound = true
        }
      }
      guard appliedInRound else {
        break
      }
    }
    return working
  }

  private func worstCrowdedPair(
    in segments: [PolicyCanvasNudgeSegment]
  ) -> [PolicyCanvasNudgeSegment]? {
    let sorted = segments.sorted(by: exactChannelSort)
    guard sorted.count > 1 else {
      return nil
    }
    var best: (left: PolicyCanvasNudgeSegment, right: PolicyCanvasNudgeSegment)?
    var bestSeparation = CGFloat.greatestFiniteMagnitude
    var bestOverlap: CGFloat = 0
    for left in sorted.indices {
      for right in sorted.index(after: left)..<sorted.endIndex {
        let separation = sorted[right].position - sorted[left].position
        if separation >= laneGap - 0.001 {
          break
        }
        guard sorted[left].edgeID != sorted[right].edgeID else {
          continue
        }
        let overlap = spanOverlap(sorted[left], sorted[right])
        guard overlap >= overlapThreshold, separation < laneGap - 0.001 else {
          continue
        }
        let currentKey = residualPairKey(sorted[left], sorted[right])
        let bestKey = best.map { residualPairKey($0.left, $0.right) } ?? ""
        if separation < bestSeparation - 0.001
          || (abs(separation - bestSeparation) <= 0.001
            && (overlap > bestOverlap + 0.001
              || (abs(overlap - bestOverlap) <= 0.001 && currentKey < bestKey)))
        {
          best = (sorted[left], sorted[right])
          bestSeparation = separation
          bestOverlap = overlap
        }
      }
    }
    guard let best else {
      return nil
    }
    return [best.left, best.right].sorted(by: exactChannelSort)
  }

  private func residualPairKey(
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

  func routesClearingRemainingCollinearReuse(
    _ routes: [String: PolicyCanvasEdgeRoute],
    obstacles: [CGRect],
    accepts: ((String, PolicyCanvasEdgeRoute, PolicyCanvasEdgeRoute) -> Bool)? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let splitPoints = clearRemainingCollinearReuse(
      routes.mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0.points) },
      obstacles: obstacles,
      accepts: accepts
    )
    return routes.reduce(into: [:]) { result, entry in
      guard let points = splitPoints[entry.key] else {
        result[entry.key] = entry.value
        return
      }
      let compressed = PolicyCanvasVisibilityRouter.compressCollinear(points)
      result[entry.key] = PolicyCanvasEdgeRoute(
        points: compressed,
        labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
      )
    }
  }

  func routesClearingRemainingParallelPairs(
    _ routes: [String: PolicyCanvasEdgeRoute],
    obstacles: [CGRect],
    accepts: ((String, PolicyCanvasEdgeRoute, PolicyCanvasEdgeRoute) -> Bool)? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    var splitPoints = routes.mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0.points) }
    var remainingApplications = exactFastResidualSplitLimit
    while remainingApplications > 0 {
      var applied = false
      for axis in [PolicyCanvasSegmentAxis.horizontal, .vertical] {
        guard let pair = worstCrowdedPair(
          in: decompose(splitPoints).filter { $0.axis == axis }
        ) else {
          continue
        }
        let offsets = localPairLaneOffsets(for: pair)
        guard !offsets.isEmpty else {
          continue
        }
        for candidate in exactSplitPlacements(from: offsets, routeCount: splitPoints.count) {
          let next = applyExactSplit(candidate, to: splitPoints)
            .mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0) }
          guard next != splitPoints,
            exactSplit(next, isAcceptedFrom: splitPoints, shifts: candidate, accepts: accepts)
          else {
            continue
          }
          splitPoints = next
          applied = true
          break
        }
      }
      guard applied else {
        break
      }
      remainingApplications -= 1
    }
    return routes.reduce(into: [:]) { result, entry in
      guard let points = splitPoints[entry.key] else {
        result[entry.key] = entry.value
        return
      }
      let compressed = PolicyCanvasVisibilityRouter.compressCollinear(points)
      result[entry.key] = PolicyCanvasEdgeRoute(
        points: compressed,
        labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
      )
    }
  }

  private func exactSplitPlacements(
    from offsets: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)],
    routeCount: Int
  ) -> [[(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]] {
    let micro = exactMicroSplitOffsets(from: offsets)
    if routeCount > reducedPlacementRouteCount, !micro.isEmpty {
      return exactFullSplitPlacements(
        from: offsets, routeCount: routeCount,
        seed: [
          micro, micro.map { ($0.segment, -$0.offset) },
        ])
    }
    return exactFullSplitPlacements(from: offsets, routeCount: routeCount, seed: [])
      + (micro.isEmpty ? [] : [micro, micro.map { ($0.segment, -$0.offset) }])
  }

  private func exactFullSplitPlacements(
    from offsets: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)],
    routeCount: Int,
    seed: [[(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]]
  ) -> [[(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]] {
    let slides: [CGFloat] =
      routeCount > reducedPlacementRouteCount
      ? [0, laneGap, -laneGap]
      : [0, laneGap, -laneGap, 2 * laneGap, -2 * laneGap]
    var result = seed
    for ordering in [offsets, offsets.map({ ($0.segment, -$0.offset) })] {
      for slide in slides {
        result.append(ordering.map { ($0.segment, $0.offset + slide) })
      }
    }
    for anchor in offsets {
      result.append(offsets.map { ($0.segment, $0.offset - anchor.offset) })
    }
    return result
  }

  private func exactMicroSplitOffsets(
    from offsets: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)]
  ) -> [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)] {
    guard offsets.count > 1 else {
      return []
    }
    let center = CGFloat(offsets.count - 1) / 2
    let step = exactMicroSplitBand / CGFloat(max(1, offsets.count - 1))
    return offsets.enumerated().map { rank, entry in
      (entry.segment, (CGFloat(rank) - center) * step)
    }
  }

  private func exactSplit(
    _ candidate: [String: [CGPoint]],
    isAcceptedFrom current: [String: [CGPoint]],
    shifts: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)],
    accepts: ((String, PolicyCanvasEdgeRoute, PolicyCanvasEdgeRoute) -> Bool)?
  ) -> Bool {
    guard let accepts else {
      return true
    }
    for edgeID in Set(shifts.map(\.segment.edgeID)).sorted() {
      guard let oldPoints = current[edgeID], let newPoints = candidate[edgeID],
        oldPoints != newPoints
      else {
        continue
      }
      let oldRoute = PolicyCanvasEdgeRoute(points: oldPoints, labelPosition: .zero)
      let newRoute = PolicyCanvasEdgeRoute(points: newPoints, labelPosition: .zero)
      guard accepts(edgeID, oldRoute, newRoute) else {
        return false
      }
    }
    return true
  }

  private func applyExactSplit(
    _ shifts: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)],
    to pointsByEdge: [String: [CGPoint]]
  ) -> [String: [CGPoint]] {
    let shiftsByEdge = Dictionary(grouping: shifts, by: { $0.segment.edgeID })
    var result = pointsByEdge
    for (edgeID, edgeShifts) in shiftsByEdge {
      guard let points = pointsByEdge[edgeID], points.count >= 2 else {
        continue
      }
      let shiftsByStartIndex = Dictionary(
        edgeShifts.map { ($0.segment.startIndex, (axis: $0.segment.axis, offset: $0.offset)) },
        uniquingKeysWith: { _, replacement in replacement }
      )
      var rebuilt: [CGPoint] = []
      appendOrthogonalBridge(points[0], to: &rebuilt)
      for index in 0..<(points.count - 1) {
        let start = points[index]
        let end = points[index + 1]
        if let shift = shiftsByStartIndex[index], abs(shift.offset) > 0.001 {
          appendOrthogonalBridge(
            shifted(start, axis: shift.axis, offset: shift.offset),
            to: &rebuilt
          )
          appendOrthogonalBridge(
            shifted(end, axis: shift.axis, offset: shift.offset),
            to: &rebuilt
          )
        }
        appendOrthogonalBridge(end, to: &rebuilt)
      }
      result[edgeID] = policyCanvasCompressPreservingTerminalStubs(rebuilt)
    }
    return result
  }

  private func shifted(
    _ point: CGPoint,
    axis: PolicyCanvasSegmentAxis,
    offset: CGFloat
  ) -> CGPoint {
    switch axis {
    case .horizontal:
      CGPoint(x: point.x, y: PolicyCanvasLayout.routeGridRound(point.y + offset))
    case .vertical:
      CGPoint(x: PolicyCanvasLayout.routeGridRound(point.x + offset), y: point.y)
    }
  }

  private func appendOrthogonalBridge(_ point: CGPoint, to points: inout [CGPoint]) {
    guard let last = points.last else {
      points.append(point)
      return
    }
    if abs(last.x - point.x) > 0.001, abs(last.y - point.y) > 0.001 {
      points.append(CGPoint(x: point.x, y: last.y))
    }
    if points.last != point {
      points.append(point)
    }
  }

  private func crowdedCorridorChannels(
    in segments: [PolicyCanvasNudgeSegment]
  ) -> [[PolicyCanvasNudgeSegment]] {
    var channels: [[PolicyCanvasNudgeSegment]] = []
    let sorted = segments.sorted(by: exactChannelSort)
    guard sorted.count > 1 else {
      return []
    }
    var parent = Array(sorted.indices)
    for left in sorted.indices {
      for right in sorted.index(after: left)..<sorted.endIndex {
        let laneDistance = sorted[right].position - sorted[left].position
        if laneDistance >= laneGap - 0.001 {
          break
        }
        guard sorted[left].edgeID != sorted[right].edgeID,
          spanOverlap(sorted[left], sorted[right]) >= overlapThreshold
        else {
          continue
        }
        union(left, right, parent: &parent)
      }
    }
    var groups: [Int: [PolicyCanvasNudgeSegment]] = [:]
    for index in sorted.indices {
      groups[find(index, parent: &parent), default: []].append(sorted[index])
    }
    channels.append(
      contentsOf: groups.values
        .filter { $0.count > 1 }
        .map { $0.sorted(by: exactChannelSort) }
    )
    return channels.sorted { left, right in
      key(for: left) < key(for: right)
    }
  }

  private func fullLaneOffsets(
    for channel: [PolicyCanvasNudgeSegment],
    processor: PolicyCanvasOrthogonalNudgeProcessor
  ) -> [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)] {
    let ordered = processor.orderedChannel(channel)
    guard ordered.count > 1 else {
      return []
    }
    let laneCenter = ordered.map(\.position).reduce(0, +) / CGFloat(ordered.count)
    let center = CGFloat(ordered.count - 1) / 2
    let firstLane = PolicyCanvasLayout.routeGridRound(laneCenter - (center * laneGap))
    return ordered.enumerated().map { rank, segment in
      let targetPosition = firstLane + (CGFloat(rank) * laneGap)
      return (segment, targetPosition - segment.position)
    }
  }

  private func localPairLaneOffsets(
    for channel: [PolicyCanvasNudgeSegment]
  ) -> [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)] {
    let ordered = channel.sorted(by: exactChannelSort)
    guard ordered.count > 1 else {
      return []
    }
    let laneCenter = ordered.map(\.position).reduce(0, +) / CGFloat(ordered.count)
    let center = CGFloat(ordered.count - 1) / 2
    let firstLane = PolicyCanvasLayout.routeGridRound(laneCenter - (center * laneGap))
    return ordered.enumerated().map { rank, segment in
      let targetPosition = firstLane + (CGFloat(rank) * laneGap)
      return (segment, targetPosition - segment.position)
    }
  }

  private func exactChannelSort(
    _ left: PolicyCanvasNudgeSegment,
    _ right: PolicyCanvasNudgeSegment
  ) -> Bool {
    if left.position != right.position {
      return left.position < right.position
    }
    if left.lowerBound != right.lowerBound {
      return left.lowerBound < right.lowerBound
    }
    if left.upperBound != right.upperBound {
      return left.upperBound < right.upperBound
    }
    if left.edgeID != right.edgeID {
      return left.edgeID < right.edgeID
    }
    return left.startIndex < right.startIndex
  }

  private func spanOverlap(
    _ left: PolicyCanvasNudgeSegment,
    _ right: PolicyCanvasNudgeSegment
  ) -> CGFloat {
    max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
  }

  private func find(_ index: Int, parent: inout [Int]) -> Int {
    if parent[index] != index {
      parent[index] = find(parent[index], parent: &parent)
    }
    return parent[index]
  }

  private func union(_ left: Int, _ right: Int, parent: inout [Int]) {
    let leftRoot = find(left, parent: &parent)
    let rightRoot = find(right, parent: &parent)
    guard leftRoot != rightRoot else {
      return
    }
    parent[rightRoot] = leftRoot
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

  private func routeEntriesSortedByMinX<S: Sequence>(
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

  private struct SpreadSelectionContext {
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
  private func relevantFixed(
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
  /// their reverse. The zero-shift floor in `bestSpread` still wins unless one
  /// placement strictly improves on it, so saturated corridors remain unchanged
  /// instead of being routed through a crossing/body hit. Earlier versions also
  /// slid the separated band by several lane widths; that made large policy
  /// samples spend most of their route budget evaluating near-duplicate
  /// placements for marginal label-free aesthetics.
  private func placements(
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
