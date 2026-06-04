import CoreGraphics

/// Crossing, overlap, and body-hit metrics for the crossing-aware post-process.
///
/// The proper-cross predicate mirrors the fan-in channel gate exactly - a
/// horizontal segment's interior cut by a vertical segment's interior at 0.5pt
/// tolerance - so a candidate lane assignment is scored against the same crossing
/// count the gate measures. Overlap counts interior collinear stacks past the
/// gate's 8pt threshold; body hits count routes whose segments cross a node or
/// group-title frame. The pass uses these to reject any lane shift that would add
/// a crossing or a body hit while clearing an overlap.
enum PolicyCanvasClaudeRouteMetrics {
  struct Snapshot {
    let crossings: Set<String>
    let overlapPairs: Int
    let bodyHits: Int
  }

  /// Lexicographic penalty of a candidate spread versus the pre-spread base: never
  /// add a body hit, then never add a crossing, then minimise interior overlaps.
  /// `isLower` is the comparison the spread search uses to pick the best placement.
  struct Penalty {
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

  private struct RouteEntry {
    let id: String
    let points: [CGPoint]
    let interior: [PolicyCanvasRouteSegment]
  }

  static func snapshot(
    of pointsByEdge: [String: [CGPoint]],
    obstacles: [CGRect],
    overlapThreshold: CGFloat
  ) -> Snapshot {
    let ordered = pointsByEdge.keys.sorted()
    var routes: [RouteEntry] = []
    var bodyHits = 0
    for id in ordered {
      guard let points = pointsByEdge[id] else {
        continue
      }
      let route = PolicyCanvasEdgeRoute(points: points, labelPosition: .zero)
      let segments = policyCanvasRouteSegments(route)
      routes.append(
        RouteEntry(id: id, points: points, interior: Array(segments.dropFirst().dropLast()))
      )
      if policyCanvasRouteIntersectsObstacles(route, obstacles: obstacles) {
        bodyHits += 1
      }
    }
    var crossings: Set<String> = []
    var overlapPairs = 0
    for left in routes.indices {
      for right in routes.index(after: left)..<routes.endIndex {
        if properlyCross(routes[left].points, routes[right].points) {
          crossings.insert("\(routes[left].id)|\(routes[right].id)")
        }
        let overlap = maximumInteriorOverlap(routes[left].interior, routes[right].interior)
        if overlap > overlapThreshold {
          overlapPairs += 1
        }
      }
    }
    return Snapshot(crossings: crossings, overlapPairs: overlapPairs, bodyHits: bodyHits)
  }

  /// Lexicographic penalty of a candidate versus the pre-spread base: added body
  /// hits first (never trade a clean route into a node), then added crossings,
  /// then the absolute interior-overlap pair count. Lower wins; the zero-shift
  /// option is the floor, so a channel can be left stacked but never regressed
  /// into a new crossing or body hit.
  static func penalty(of candidate: Snapshot, base: Snapshot) -> Penalty {
    Penalty(
      addedBodyHits: max(0, candidate.bodyHits - base.bodyHits),
      addedCrossings: candidate.crossings.subtracting(base.crossings).count,
      overlapPairs: candidate.overlapPairs
    )
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
