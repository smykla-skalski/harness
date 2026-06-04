import CoreGraphics

/// Crossing, overlap, and body-hit metrics for the crossing-aware post-process.
///
/// Scoring is *local*. Shifting one channel can only change the crossings and
/// overlaps of pairs that involve that channel's edges - every pair that excludes
/// the channel is byte-identical across all of its candidate placements. So a
/// candidate is scored against just the moved edges (one another plus the fixed
/// rest), which orders placements exactly as a full-scene rescore would, at a
/// fraction of the cost. The proper-cross predicate mirrors the fan-in channel
/// gate exactly - a horizontal segment's interior cut by a vertical segment's
/// interior at 0.5pt tolerance. Overlap counts interior collinear stacks past the
/// gate's 8pt threshold; body hits count routes whose segments cut a node or
/// group-title frame. The pass rejects any shift that adds a crossing or a body
/// hit not already present in the pre-spread baseline.
enum PolicyCanvasNudgeRouteMetrics {
  /// The pre-spread routing the result is measured against: the crossing pairs
  /// that already existed (keyed `lowerID|higherID`) and the edges whose route
  /// already cut a node or group-title body. A spread is kept only if it adds
  /// neither a crossing nor a body hit beyond this set.
  struct Baseline {
    let crossings: Set<String>
    let bodyHitEdges: Set<String>
  }

  /// Penalty of one channel placement, scored only over pairs that involve the
  /// channel's edges. Lexicographic: never add a body hit, then never add a
  /// crossing, then minimise interior overlaps. `isLower` is the comparison the
  /// spread search uses to pick the best placement.
  struct LocalPenalty {
    let addedBodyHits: Int
    let addedCrossings: Int
    let overlapPairs: Int

    func isLower(than other: Self) -> Bool {
      if addedBodyHits != other.addedBodyHits {
        return addedBodyHits < other.addedBodyHits
      }
      if addedCrossings != other.addedCrossings {
        return addedCrossings < other.addedCrossings
      }
      return overlapPairs < other.overlapPairs
    }
  }

  struct RouteEntry {
    let id: String
    let points: [CGPoint]
    /// Interior segments (stubs dropped) used for overlap scoring.
    let interior: [PolicyCanvasRouteSegment]
    /// All segments including the port stubs, cached so the channel-band prune can
    /// test a route without rebuilding its polyline each time it is consulted.
    let segments: [PolicyCanvasRouteSegment]
    /// Bounding box of the whole polyline. Two routes can only cross or overlap
    /// where their boxes meet, so this prunes far-apart pairs before the segment
    /// test - a route outside the shifting channel's band cannot interact with it.
    let bounds: CGRect
  }

  static func entry(id: String, points: [CGPoint]) -> RouteEntry {
    let segments = policyCanvasRouteSegments(
      PolicyCanvasEdgeRoute(points: points, labelPosition: .zero)
    )
    let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    return RouteEntry(
      id: id,
      points: points,
      interior: Array(segments.dropFirst().dropLast()),
      segments: segments,
      bounds: bounds
    )
  }

  /// Whether any of a route's segments enters `rect`, mirroring the obstacle
  /// intersection test but reading the entry's cached segments directly.
  static func segmentsEnter(_ entry: RouteEntry, _ rect: CGRect) -> Bool {
    entry.segments.contains { segment in
      if segment.isHorizontal {
        let low = min(segment.start.x, segment.end.x)
        let high = max(segment.start.x, segment.end.x)
        return rect.minY < segment.start.y && rect.maxY > segment.start.y
          && max(0, min(high, rect.maxX) - max(low, rect.minX)) > 0.001
      }
      if segment.isVertical {
        let low = min(segment.start.y, segment.end.y)
        let high = max(segment.start.y, segment.end.y)
        return rect.minX < segment.start.x && rect.maxX > segment.start.x
          && max(0, min(high, rect.maxY) - max(low, rect.minY)) > 0.001
      }
      return false
    }
  }

  /// Build the once-per-spread baseline: every existing crossing pair and every
  /// body-hitting edge in the pre-spread routing. O(routes^2) but computed a
  /// single time, not per candidate placement.
  static func baseline(
    of pointsByEdge: [String: [CGPoint]],
    obstacles: [CGRect]
  ) -> Baseline {
    let entries = pointsByEdge.keys.sorted().compactMap { id in
      pointsByEdge[id].map { entry(id: id, points: $0) }
    }
    var crossings: Set<String> = []
    var bodyHitEdges: Set<String> = []
    for left in entries.indices {
      let route = PolicyCanvasEdgeRoute(points: entries[left].points, labelPosition: .zero)
      if policyCanvasRouteIntersectsObstacles(route, obstacles: obstacles) {
        bodyHitEdges.insert(entries[left].id)
      }
      for right in entries.index(after: left)..<entries.endIndex
      where properlyCross(entries[left].points, entries[right].points) {
        crossings.insert(crossingKey(entries[left].id, entries[right].id))
      }
    }
    return Baseline(crossings: crossings, bodyHitEdges: bodyHitEdges)
  }

  /// Per-channel scoring invariants: the routes that stay fixed, the obstacles near
  /// the channel band, the pre-spread baseline, and the overlap threshold. Bundled
  /// so the placement scorers take one context instead of a long parameter list.
  struct Scoring {
    let fixed: [RouteEntry]
    let obstacles: [CGRect]
    let baseline: Baseline
    let overlapThreshold: CGFloat
  }

  /// Score a candidate placement of one channel: build the moved edges' entries
  /// and test them against the fixed rest and one another, counting crossings and
  /// body hits not already in the baseline plus the interior overlaps that remain.
  static func localPenalty(
    channelEdges: [String],
    pointsByEdge: [String: [CGPoint]],
    scoring: Scoring
  ) -> LocalPenalty {
    let moved = channelEdges.compactMap { id in
      pointsByEdge[id].map { entry(id: id, points: $0) }
    }
    var addedBodyHits = 0
    for movedEntry in moved where !scoring.baseline.bodyHitEdges.contains(movedEntry.id) {
      let route = PolicyCanvasEdgeRoute(points: movedEntry.points, labelPosition: .zero)
      if policyCanvasRouteIntersectsObstacles(route, obstacles: scoring.obstacles) {
        addedBodyHits += 1
      }
    }
    var addedCrossings = 0
    var overlapPairs = 0
    for index in moved.indices {
      for rightIndex in moved.index(after: index)..<moved.endIndex {
        accumulate(
          moved[index], moved[rightIndex], scoring: scoring,
          addedCrossings: &addedCrossings, overlapPairs: &overlapPairs
        )
      }
      for fixedEntry in scoring.fixed {
        accumulate(
          moved[index], fixedEntry, scoring: scoring,
          addedCrossings: &addedCrossings, overlapPairs: &overlapPairs
        )
      }
    }
    return LocalPenalty(
      addedBodyHits: addedBodyHits, addedCrossings: addedCrossings, overlapPairs: overlapPairs
    )
  }

  private static func accumulate(
    _ left: RouteEntry,
    _ right: RouteEntry,
    scoring: Scoring,
    addedCrossings: inout Int,
    overlapPairs: inout Int
  ) {
    if properlyCross(left.points, right.points),
      !scoring.baseline.crossings.contains(crossingKey(left.id, right.id))
    {
      addedCrossings += 1
    }
    if maximumInteriorOverlap(left.interior, right.interior) > scoring.overlapThreshold {
      overlapPairs += 1
    }
  }

  /// Order-independent key for an edge pair, matching the order the baseline scan
  /// inserts crossings (`lowerID|higherID`) so the local subtraction lines up.
  static func crossingKey(_ left: String, _ right: String) -> String {
    left < right ? "\(left)|\(right)" : "\(right)|\(left)"
  }

  static func maximumInteriorOverlap(
    _ left: [PolicyCanvasRouteSegment],
    _ right: [PolicyCanvasRouteSegment]
  ) -> CGFloat {
    var best: CGFloat = 0
    for leftSegment in left {
      for rightSegment in right where leftSegment.sharesAxisLane(with: rightSegment) {
        best = max(best, leftSegment.overlap(with: rightSegment))
      }
    }
    return best
  }

  static func properlyCross(_ left: [CGPoint], _ right: [CGPoint]) -> Bool {
    for (a0, a1) in zip(left, left.dropFirst()) {
      for (b0, b1) in zip(right, right.dropFirst())
      where segmentsProperlyCross(a0, a1, b0, b1) {
        return true
      }
    }
    return false
  }

  static func segmentsProperlyCross(
    _ a0: CGPoint,
    _ a1: CGPoint,
    _ b0: CGPoint,
    _ b1: CGPoint
  ) -> Bool {
    let tolerance: CGFloat = 0.5
    let aHorizontal = abs(a0.y - a1.y) < tolerance
    let aVertical = abs(a0.x - a1.x) < tolerance
    let bHorizontal = abs(b0.y - b1.y) < tolerance
    let bVertical = abs(b0.x - b1.x) < tolerance
    if aHorizontal, bVertical {
      let crossX = b0.x
      let crossY = a0.y
      return crossX > min(a0.x, a1.x) + tolerance
        && crossX < max(a0.x, a1.x) - tolerance
        && crossY > min(b0.y, b1.y) + tolerance
        && crossY < max(b0.y, b1.y) - tolerance
    }
    if aVertical, bHorizontal {
      return segmentsProperlyCross(b0, b1, a0, a1)
    }
    return false
  }
}
