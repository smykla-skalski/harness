import SwiftUI

/// Rewrites a genuine multi-source fan-in - three or more distinct sources
/// converging on one target port from below, every rail entering the target's
/// bottom edge - into a nested staircase so the rails never cross.
///
/// The per-edge collision-aware router settles each rail's horizontal at an
/// inconsistent height: some turn at their source-escape lane, others rise nearly
/// to the target before turning. A far rail that turns low then slices through a
/// nearer rail's vertical riser, and the outermost rail's tall final drop reads as
/// a separate line. The sequential router cannot see the whole fan, so it cannot
/// order the lanes.
///
/// This pass runs once on the settled routes with the whole family in hand. It
/// discards the router's heights and assigns each rail one lane by how far its
/// source sits from the fan's center: the outermost rail (longest horizontal
/// travel) runs nearest the target, inner rails fall to lanes farther out. Because
/// left rails keep their horizontals left of center and right rails keep theirs
/// right of center, mirroring the nesting on both sides clears every horizontal of
/// the other rails' risers (a left rail and a right rail never share an x-range, so
/// they cannot cross regardless of lane). Lane heights are spread evenly through
/// the gap between the collector's bottom and the sources' tops with a grid-step
/// margin at each end, so every rise, run, and drop is long enough to read as a
/// corner rather than a stub.
func policyCanvasNestedFanInRoutes(
  _ routes: [String: PolicyCanvasEdgeRoute],
  edges: [PolicyCanvasEdge]
) -> [String: PolicyCanvasEdgeRoute] {
  var result = routes
  let families = Dictionary(grouping: edges, by: \.target)
  for (_, family) in families {
    guard Set(family.map(\.source.nodeID)).count >= 3 else {
      continue
    }
    let rails = family.compactMap { edge -> PolicyCanvasFanInRail? in
      guard let route = result[edge.id], route.points.count >= 2,
        let source = route.points.first, let marker = route.points.last
      else {
        return nil
      }
      return PolicyCanvasFanInRail(id: edge.id, source: source, marker: marker)
    }
    guard rails.count == family.count, rails.count >= 3 else {
      continue
    }
    guard let nested = policyCanvasNestedFanInLanes(rails) else {
      continue
    }
    for (id, route) in nested {
      result[id] = route
    }
  }
  return result
}

private struct PolicyCanvasFanInRail {
  let id: String
  let source: CGPoint
  let marker: CGPoint
}

/// Builds the nested staircase for one fan-in family, or nil when the family is
/// not a clean below-the-target vertical fan-in (mixed marker rows, the collector
/// not lifted above its sources, or too little vertical room for grid-step
/// margins), in which case the router's routes are left untouched.
private func policyCanvasNestedFanInLanes(
  _ rails: [PolicyCanvasFanInRail]
) -> [String: PolicyCanvasEdgeRoute]? {
  // The lane nearest the collector drops a full port lead into its marker, and
  // the lane nearest the sources rises a full port lead off them, so the
  // outermost rails (on those end lanes) never turn straight into a port and the
  // innermost rail clears the source's own top port and label by a readable
  // corner rather than crowding the node it left.
  let margin = PolicyCanvasLayout.edgePortTurnMinimumLead
  // Every rail must drop onto the same collector edge.
  guard Set(rails.map { Int($0.marker.y.rounded()) }).count == 1 else {
    return nil
  }
  let collectorY = rails[0].marker.y
  // Sources sit below the lifted collector (larger y). Use the lowest source top
  // (largest y) so the deepest lane still clears every source by the margin.
  guard let sourceTop = rails.map(\.source.y).max(), sourceTop > collectorY else {
    return nil
  }
  let laneTop = collectorY + margin
  let laneBottom = sourceTop - margin
  guard laneBottom > laneTop else {
    return nil
  }
  let center = rails.map(\.marker.x).reduce(0, +) / CGFloat(rails.count)
  // Assign lanes per approach side. Within each side the outermost source (the
  // longest horizontal traveler) takes lane 0 nearest the collector and inner
  // sources fall to deeper lanes. Both sides share one height per lane index, so
  // the symmetric innermost rails - one approaching from the left, one from the
  // right - turn at the same height and read as a balanced V into the collector
  // instead of two adjacent stubs. A left rail's horizontal stays left of the fan
  // center and a right rail's stays right of it, so sharing a height never makes
  // them cross.
  let lanesByID = policyCanvasFanInLaneOrder(rails.filter { $0.source.x < center }, center: center)
    .merging(
      policyCanvasFanInLaneOrder(rails.filter { $0.source.x >= center }, center: center)
    ) { current, _ in current }
  let denominator = CGFloat(max(1, lanesByID.values.max() ?? 0))
  var rewritten: [String: PolicyCanvasEdgeRoute] = [:]
  for rail in rails {
    let lane = lanesByID[rail.id] ?? 0
    let laneY = laneTop + (laneBottom - laneTop) * CGFloat(lane) / denominator
    let points = PolicyCanvasVisibilityRouter.compressCollinear([
      rail.source,
      CGPoint(x: rail.source.x, y: laneY),
      CGPoint(x: rail.marker.x, y: laneY),
      rail.marker,
    ])
    rewritten[rail.id] = PolicyCanvasEdgeRoute(
      points: points,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
    )
  }
  return rewritten
}

/// Lane index per rail within one approach side: the source farthest from the fan
/// center (the longest traveler) takes lane 0 nearest the collector, the next
/// farthest lane 1, and so on. Ties break on edge id so the order is stable.
private func policyCanvasFanInLaneOrder(
  _ side: [PolicyCanvasFanInRail],
  center: CGFloat
) -> [String: Int] {
  let sorted = side.sorted { left, right in
    let leftDistance = abs(left.source.x - center)
    let rightDistance = abs(right.source.x - center)
    return abs(leftDistance - rightDistance) > 0.5
      ? leftDistance > rightDistance : left.id < right.id
  }
  return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset) })
}
