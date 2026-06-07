import CoreGraphics

extension PolicyCanvasOrthogonalNudgeProcessor {
  /// Segments overlapping a shared lane by less than this are left alone - they
  /// touch end-to-end or barely graze and reading them as one channel would
  /// spread wires that were never really stacked.
  private var minimumChannelOverlap: CGFloat { 4 }

  /// Group same-axis segments into channels: a channel is a maximal connected
  /// run of segments that overlap along their route span and whose parallel lanes
  /// are closer than the required route spacing. Exact stacks and near-parallel
  /// corridor collisions are both spread by the same lane-offset pass.
  func channels(in segments: [PolicyCanvasNudgeSegment]) -> [[PolicyCanvasNudgeSegment]] {
    let sorted = segments.sorted(by: channelSort)
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
        guard sorted[left].edgeID != sorted[right].edgeID else {
          continue
        }
        guard spanOverlap(sorted[left], sorted[right]) > minimumChannelOverlap else {
          continue
        }
        union(left, right, parent: &parent)
      }
    }
    var groups: [Int: [PolicyCanvasNudgeSegment]] = [:]
    for index in sorted.indices {
      groups[find(index, parent: &parent), default: []].append(sorted[index])
    }
    return groups.values
      .filter { $0.count > 1 }
      .map { $0.sorted(by: channelSort) }
      .sorted { left, right in
        channelSort(left[0], right[0])
      }
  }

  /// Assign each segment in a channel its lane offset. Order comes from
  /// `orderedChannel` - a fan's single shared member rank when the channel is one
  /// fan's corridor or column, the barycentre of the entry/exit bends otherwise -
  /// so members keep a consistent vertical order and the spread adds no avoidable
  /// crossing.
  ///
  /// The lane band is fit into the free space on EACH side of the channel
  /// independently and biased toward the roomier side - a fan-in corridor wedged
  /// just under its target has little room above but a whole inter-layer gap
  /// below, so the band slides down into that gap instead of being throttled by
  /// the tight side. A channel with no room on either side is left stacked rather
  /// than routed through a node body.
  func laneOffsets(
    for channel: [PolicyCanvasNudgeSegment]
  ) -> [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)] {
    let ordered = orderedChannel(channel)
    let count = ordered.count
    var freeUp = CGFloat.greatestFiniteMagnitude
    var freeDown = CGFloat.greatestFiniteMagnitude
    for segment in ordered {
      let space = freeSpace(around: segment)
      freeUp = min(freeUp, space.up)
      freeDown = min(freeDown, space.down)
    }
    // Cap each side at the band width: a channel in open space reports
    // `greatestFiniteMagnitude` free room, and an asymmetric cap-less band would
    // teleport the lane to infinity. The band never needs more than its own width
    // on one side, so capping there keeps it centred and finite.
    let maximumRoom = CGFloat(count - 1) * laneGap
    let upRoom = min(maximumRoom, max(0, freeUp - obstacleMargin))
    let downRoom = min(maximumRoom, max(0, freeDown - obstacleMargin))
    let available = upRoom + downRoom
    guard available > 0 else {
      return []
    }
    let needed = CGFloat(count - 1) * laneGap
    let gap = needed <= available ? laneGap : available / CGFloat(count - 1)
    // Centre of the asymmetric free band relative to the channel lane: positive
    // means the band can sit below (or right of) the original line.
    let bandCenter = (downRoom - upRoom) / 2
    let laneCenter = ordered.map(\.position).reduce(0, +) / CGFloat(count)
    let center = CGFloat(count - 1) / 2
    return ordered.enumerated().map { rank, segment in
      let targetPosition = laneCenter + bandCenter + (CGFloat(rank) - center) * gap
      return (segment, targetPosition - segment.position)
    }
  }

  private func channelSort(
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

  /// Lane order for a channel. When every segment belongs to one fan - all
  /// converging on the same target, or all diverging from the same source - the
  /// channel is ordered by that fan's single member rank so the corridor and the
  /// column the same fan turns into agree at their shared corner. Anything else
  /// keeps the barycentre order of the entry/exit bends.
  func orderedChannel(
    _ channel: [PolicyCanvasNudgeSegment]
  ) -> [PolicyCanvasNudgeSegment] {
    if let fanOrdered = fanOrderedChannel(channel) {
      return fanOrdered
    }
    return busOrdered(channel)
  }

  /// Order a non-fan channel - a bus of otherwise unrelated edges that happened
  /// to share a corridor - so no member's drop-stub is left cutting across a
  /// neighbour it was nudged above. For each pair the stub geometry says whether
  /// one must sit below the other; those constraints are resolved with a
  /// topological order (longest-path rank), so a transitive chain a-above-b-above-c
  /// is honoured rather than collapsed into a tie. Genuine incomparables, and any
  /// member left in a constraint cycle, fall back to the barycentre of the
  /// entry/exit bends. A bus need not admit a perfectly crossing-free order; this
  /// minimises the avoidable ones.
  func busOrdered(
    _ channel: [PolicyCanvasNudgeSegment]
  ) -> [PolicyCanvasNudgeSegment] {
    let count = channel.count
    var successors: [Set<Int>] = Array(repeating: [], count: count)
    var remainingAbove = Array(repeating: 0, count: count)
    for above in 0..<count {
      for below in 0..<count where above != below {
        // `below` must sit under `above` when lifting it over forces a crossing
        // that keeping it under does not.
        guard
          firstForcesCross(channel[below], over: channel[above]),
          !firstForcesCross(channel[above], over: channel[below])
        else {
          continue
        }
        if successors[above].insert(below).inserted {
          remainingAbove[below] += 1
        }
      }
    }
    var remaining = Set(0..<count)
    var ordered: [PolicyCanvasNudgeSegment] = []
    while let next = nextInTopologicalOrder(remaining, remainingAbove, channel) {
      ordered.append(channel[next])
      remaining.remove(next)
      for successor in successors[next] where remaining.contains(successor) {
        remainingAbove[successor] -= 1
      }
    }
    return ordered
  }

  /// Pick the next segment for `busOrdered`: the unconstrained one (nothing left
  /// that must sit above it) with the smallest barycentre, or - if a constraint
  /// cycle leaves none unconstrained - the smallest barycentre among what remains,
  /// which breaks the cycle without stalling.
  private func nextInTopologicalOrder(
    _ remaining: Set<Int>,
    _ remainingAbove: [Int],
    _ channel: [PolicyCanvasNudgeSegment]
  ) -> Int? {
    let ready = remaining.filter { remainingAbove[$0] == 0 }
    let pool = ready.isEmpty ? remaining : ready
    return pool.min { lhs, rhs in
      if channel[lhs].orderingKey != channel[rhs].orderingKey {
        return channel[lhs].orderingKey < channel[rhs].orderingKey
      }
      return channel[lhs].edgeID < channel[rhs].edgeID
    }
  }

  /// True when placing `first` at the smaller lane coordinate than `other` forces
  /// a crossing: a stub of `first` that drops to the far side lands strictly
  /// inside `other`'s span, or a stub of `other` that rises back lands strictly
  /// inside `first`'s span.
  private func firstForcesCross(
    _ first: PolicyCanvasNudgeSegment,
    over other: PolicyCanvasNudgeSegment
  ) -> Bool {
    let firstDrops = stubEnds(first).below.contains { strictlyInside($0, other) }
    let otherRises = stubEnds(other).above.contains { strictlyInside($0, first) }
    return firstDrops || otherRises
  }

  /// Span coordinates of a segment's two stubs, split by whether each heads to a
  /// larger ("below"/"right") or smaller ("above"/"left") perpendicular
  /// coordinate than the segment's own lane.
  private func stubEnds(
    _ segment: PolicyCanvasNudgeSegment
  ) -> (below: [CGFloat], above: [CGFloat]) {
    var below: [CGFloat] = []
    var above: [CGFloat] = []
    for (span, connection) in [
      (segment.lowerBound, segment.lowerConnection),
      (segment.upperBound, segment.upperConnection),
    ] {
      if connection > segment.position + tolerance {
        below.append(span)
      } else if connection < segment.position - tolerance {
        above.append(span)
      }
    }
    return (below, above)
  }

  private func strictlyInside(
    _ coordinate: CGFloat,
    _ segment: PolicyCanvasNudgeSegment
  ) -> Bool {
    coordinate > segment.lowerBound + tolerance && coordinate < segment.upperBound - tolerance
  }

  /// Order a single fan's channel by the fan's shared member rank. The member
  /// whose far port reaches furthest from the convergence takes the lane closest
  /// to it, so its long stub and corridor stay inside the shorter members instead
  /// of cutting across their stubs. The rank lists members nearest-first, so that
  /// "furthest hugs the convergence" reading is the rank order when the channel
  /// sits below/right of the convergence (offsets grow toward it) and the reverse
  /// when it sits above/left. Returns nil when the channel is not one clean fan,
  /// or lies on the convergence line (no defined side), leaving the barycentre
  /// order in charge.
  private func fanOrderedChannel(
    _ channel: [PolicyCanvasNudgeSegment]
  ) -> [PolicyCanvasNudgeSegment]? {
    guard let fan = fanMembership(for: channel) else {
      return nil
    }
    let lane = channel.reduce(0) { $0 + $1.position } / CGFloat(channel.count)
    let convergencePerpendicular =
      channel[0].axis == .horizontal ? fan.convergence.y : fan.convergence.x
    let side = lane - convergencePerpendicular
    guard abs(side) > tolerance else {
      return nil
    }
    var ordered = channel.sorted { left, right in
      let leftRank = fan.ranks[left.edgeID] ?? 0
      let rightRank = fan.ranks[right.edgeID] ?? 0
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      return left.edgeID < right.edgeID
    }
    if side > 0 {
      ordered.reverse()
    }
    return ordered
  }

  /// Resolve a channel to one fan: a convergence point and a rank per edge, if
  /// every segment's edge belongs to the same fan-in (preferred) or the same
  /// fan-out. A mixed or unfanned channel resolves to nil.
  private func fanMembership(
    for channel: [PolicyCanvasNudgeSegment]
  ) -> (convergence: CGPoint, ranks: [String: Int])? {
    resolveFan(channel, in: fans.fanInByEdge) ?? resolveFan(channel, in: fans.fanOutByEdge)
  }

  private func resolveFan(
    _ channel: [PolicyCanvasNudgeSegment],
    in table: [String: PolicyCanvasFanMembership]
  ) -> (convergence: CGPoint, ranks: [String: Int])? {
    var groupKey: PolicyCanvasFanContext.PointKey?
    var convergence = CGPoint.zero
    var ranks: [String: Int] = [:]
    for segment in channel {
      guard let membership = table[segment.edgeID] else {
        return nil
      }
      if let groupKey, groupKey != membership.groupKey {
        return nil
      }
      groupKey = membership.groupKey
      convergence = membership.convergence
      ranks[segment.edgeID] = membership.rank
    }
    guard groupKey != nil else {
      return nil
    }
    return (convergence, ranks)
  }

  /// Free distance from a segment's lane to the nearest node body on each side,
  /// measured only across the span the segment actually covers. A node straddling
  /// the lane (a pre-existing body cross) reports zero so the segment is not
  /// nudged deeper into it.
  private func freeSpace(
    around segment: PolicyCanvasNudgeSegment
  ) -> (up: CGFloat, down: CGFloat) {
    var up = CGFloat.greatestFiniteMagnitude
    var down = CGFloat.greatestFiniteMagnitude
    let position = segment.position
    for obstacle in obstacles {
      let laneMin: CGFloat
      let laneMax: CGFloat
      let spanMin: CGFloat
      let spanMax: CGFloat
      switch segment.axis {
      case .horizontal:
        laneMin = obstacle.minY
        laneMax = obstacle.maxY
        spanMin = obstacle.minX
        spanMax = obstacle.maxX
      case .vertical:
        laneMin = obstacle.minX
        laneMax = obstacle.maxX
        spanMin = obstacle.minY
        spanMax = obstacle.maxY
      }
      guard spanMin < segment.upperBound, spanMax > segment.lowerBound else {
        continue
      }
      if laneMax <= position + tolerance {
        up = min(up, position - laneMax)
      } else if laneMin >= position - tolerance {
        down = min(down, laneMin - position)
      } else {
        return (0, 0)
      }
    }
    return (up, down)
  }
}
