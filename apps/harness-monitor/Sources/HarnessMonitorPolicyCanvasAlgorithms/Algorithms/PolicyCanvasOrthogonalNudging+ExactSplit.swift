import CoreGraphics

extension PolicyCanvasOrthogonalNudgingRouteProcessing {
  /// Final deterministic splitter for crowded same-axis corridors. The
  /// crossing-aware spread above intentionally leaves saturated channels stacked
  /// when every candidate would add a crossing/body hit. Exact stacks and
  /// near-parallel lanes below the required spacing are still hard graph-quality
  /// errors, so this pass separates remaining channels by the full route lane
  /// spacing. It is bounded and uses the same stable channel ordering primitives
  /// as the scorer, keeping runtime predictable on stress samples.
  func clearRemainingCollinearReuse(
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
      let appliedCount = clearOneRoundCollinearReuse(
        working: &working,
        remainingApplications: &remainingApplications,
        processor: processor,
        accepts: accepts
      )
      guard appliedCount > 0 else {
        break
      }
    }
    return working
  }

  /// Runs one full iteration (both axes) of crowded-corridor exact splitting.
  /// Returns the number of accepted channel splits applied in this round (0 = done).
  private func clearOneRoundCollinearReuse(
    working: inout [String: [CGPoint]],
    remainingApplications: inout Int,
    processor: PolicyCanvasOrthogonalNudgeProcessor,
    accepts: ((String, PolicyCanvasEdgeRoute, PolicyCanvasEdgeRoute) -> Bool)?
  ) -> Int {
    var appliedInRound = 0
    for axis in [PolicyCanvasSegmentAxis.horizontal, .vertical] {
      while remainingApplications > 0 {
        let channels = ordered(
          crowdedCorridorChannels(in: decompose(working).filter { $0.axis == axis })
        )
        let (shifts, count) = collectAcceptedShifts(
          channels: channels,
          working: working,
          processor: processor,
          accepts: accepts
        )
        guard !shifts.isEmpty else {
          break
        }
        let next = applyExactSplit(shifts, to: working)
        guard next != working else {
          break
        }
        working = next.mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0) }
        remainingApplications -= count
        appliedInRound += count
      }
    }
    return appliedInRound
  }

  /// Scans channels for acceptable exact-split placements and returns the
  /// combined shift list plus the number of channels that contributed shifts.
  private func collectAcceptedShifts(
    channels: [[PolicyCanvasNudgeSegment]],
    working: [String: [CGPoint]],
    processor: PolicyCanvasOrthogonalNudgeProcessor,
    accepts: ((String, PolicyCanvasEdgeRoute, PolicyCanvasEdgeRoute) -> Bool)?
  ) -> (shifts: [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)], count: Int) {
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
        guard next != working else {
          continue
        }
        guard exactSplit(next, isAcceptedFrom: working, shifts: candidate, accepts: accepts) else {
          continue
        }
        acceptedShifts.append(contentsOf: candidate)
        touchedEdgeIDs.formUnion(channelEdgeIDs)
        acceptedChannelCount += 1
        break
      }
    }
    return (acceptedShifts, acceptedChannelCount)
  }

  func clearRemainingCollinearReuseFast(
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

  func worstCrowdedPair(
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
        guard
          let pair = worstCrowdedPair(
            in: decompose(splitPoints).filter { $0.axis == axis }
          )
        else {
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

  func exactSplitPlacements(
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

  func exactFullSplitPlacements(
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

  func exactMicroSplitOffsets(
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

  func exactSplit(
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

  func applyExactSplit(
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

  func shifted(
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

  func appendOrthogonalBridge(_ point: CGPoint, to points: inout [CGPoint]) {
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
}
