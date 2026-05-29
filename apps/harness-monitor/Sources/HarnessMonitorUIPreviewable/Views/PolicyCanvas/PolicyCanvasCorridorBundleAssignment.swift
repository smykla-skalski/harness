import Foundation
import SwiftUI

/// A pre-bundle entry built by the routing-hint pass before the corridor
/// sub-lane offset is applied. `stableTiebreak` decides the rail ordinal
/// inside the bundle: the lowest source Y gets the topmost rail so reading
/// the canvas top-to-bottom matches the source order.
///
/// `targetBand` is the per-entry preferred y range (target node's vertical
/// extent extended a few grid steps above). After applying the bundle
/// offset, the final hint y is clamped to this band so a rail never leaves
/// its own target's reach.
struct PolicyCanvasCorridorBundleEntry: Equatable {
  let edgeID: String
  let key: PolicyCanvasRouteCorridorKey
  let baseHorizontalLaneY: CGFloat
  let verticalLaneX: CGFloat?
  let targetNodeID: String
  let targetBand: ClosedRange<CGFloat>?
  let stableTiebreak: String
}

/// Builds the tiebreak that decides rail ordering inside a corridor bundle.
/// Primary keys are anchor Y/X so a 4-edge fanout reads top-to-bottom in
/// source-anchor order. Edge ID is the final tiebreak so parallel edges
/// (same source and target) still pick a deterministic order.
func policyCanvasCorridorBundleTiebreak(
  sourceAnchor: CGPoint,
  targetAnchor: CGPoint,
  sourceNodeID: String,
  targetNodeID: String,
  edgeID: String
) -> String {
  let sourceY = policyCanvasFanoutBucketCoordinate(sourceAnchor.y)
  let targetY = policyCanvasFanoutBucketCoordinate(targetAnchor.y)
  let sourceX = policyCanvasFanoutBucketCoordinate(sourceAnchor.x)
  let targetX = policyCanvasFanoutBucketCoordinate(targetAnchor.x)
  return [
    String(format: "%012d", sourceY),
    String(format: "%012d", targetY),
    String(format: "%012d", sourceX),
    String(format: "%012d", targetX),
    sourceNodeID,
    targetNodeID,
    edgeID,
  ].joined(separator: "|")
}

/// Groups bundle entries by corridor key and assigns each entry a stable
/// `bundleOrdinal` reflecting its rail position within the shared corridor.
/// The ordinal is exposed through the returned hint so downstream label
/// placement, hit-testing, and visual hue assignment can distinguish
/// bundled edges without changing the underlying bus geometry.
///
/// Routes keep the shared `horizontalLaneY` (the bus the visibility router
/// uses). Per-rail distinction lives on top of the bus: labels are spread
/// along the route, fan-in stubs split at the target, and hue cycling can
/// give each rail a distinct color. The ordinal is the deterministic key
/// each of those mechanisms anchors to.
func policyCanvasAssignCorridorBundleHints(
  entries: [PolicyCanvasCorridorBundleEntry]
) -> [String: PolicyCanvasEdgeCorridorHint] {
  let bundles = Dictionary(grouping: entries, by: \.key)
  var result: [String: PolicyCanvasEdgeCorridorHint] = [:]
  result.reserveCapacity(entries.count)
  for (key, bundle) in bundles {
    let sorted = bundle.sorted { left, right in
      left.stableTiebreak < right.stableTiebreak
    }
    let bundleSize = sorted.count
    for (ordinal, entry) in sorted.enumerated() {
      result[entry.edgeID] = PolicyCanvasEdgeCorridorHint(
        key: key,
        horizontalLaneY: entry.baseHorizontalLaneY,
        verticalLaneX: entry.verticalLaneX,
        bundleOrdinal: ordinal,
        bundleSize: bundleSize
      )
    }
  }
  return result
}

/// Re-routes each parallel edge family (edges that share both their source and
/// target port) as a single coherent nested fan so the family never crosses
/// itself. The per-edge router scores each edge independently and can hand
/// siblings divergent shapes - some dropping straight, some detouring through
/// the shared vertical corridor - whose interior rails then cross (visible as
/// the tangled red "evidence failure" fan after a reflow). This pass rebuilds a
/// family's routes as clean drop -> nested-rail -> stub paths: every port attach
/// point stays exactly where the marker layout placed it, and the rails nest by
/// on-screen source position so no two siblings cross.
///
/// Only the canonical vertical fan is rebuilt - every source clears the shared
/// target on the same side. Anything else, or any rebuild whose geometry would
/// run through a non-endpoint node, is left untouched so the pass never trades a
/// crossing for an obstacle clip.
func policyCanvasNestedParallelFamilyRoutes(
  _ routes: [String: PolicyCanvasEdgeRoute],
  edges: [PolicyCanvasEdge],
  nodeFrames: [CGRect]
) -> [String: PolicyCanvasEdgeRoute] {
  var result = routes
  let families = Dictionary(grouping: edges) { edge in
    [edge.source.nodeID, edge.source.portID, edge.target.nodeID, edge.target.portID]
      .joined(separator: "|")
  }
  for family in families.values where family.count > 1 {
    guard
      let rebuilt = policyCanvasNestedFanRebuild(
        family: family, routes: result, nodeFrames: nodeFrames)
    else {
      continue
    }
    for (edgeID, route) in rebuilt {
      result[edgeID] = route
    }
  }
  return result
}

private struct PolicyCanvasFanEntry {
  let edgeID: String
  let source: CGPoint
  let target: CGPoint
}

/// Builds nested-fan replacement routes for one parallel family, or nil when
/// the family is not a clean vertical fan or the rebuild would clip a node.
private func policyCanvasNestedFanRebuild(
  family: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute],
  nodeFrames: [CGRect]
) -> [String: PolicyCanvasEdgeRoute]? {
  var entries: [PolicyCanvasFanEntry] = []
  for edge in family {
    guard
      let route = routes[edge.id], route.points.count >= 2,
      let source = route.points.first, let target = route.points.last
    else {
      return nil
    }
    entries.append(PolicyCanvasFanEntry(edgeID: edge.id, source: source, target: target))
  }

  // Require a vertical fan: all sources clear the shared target row on one
  // side. `gap` keeps a near-coplanar family out of the rebuild.
  let gap = PolicyCanvasLayout.defaultEdgeLineSpacing
  let sourceMaxY = entries.map(\.source.y).max() ?? 0
  let sourceMinY = entries.map(\.source.y).min() ?? 0
  let targetMinY = entries.map(\.target.y).min() ?? 0
  let targetMaxY = entries.map(\.target.y).max() ?? 0
  let sourcesAbove = sourceMaxY < targetMinY - gap
  let sourcesBelow = sourceMinY > targetMaxY + gap
  guard sourcesAbove || sourcesBelow else {
    return nil
  }
  let targetEdgeY = sourcesAbove ? targetMinY : targetMaxY

  // Nest by on-screen source X. When the fan sweeps right (targets right of
  // sources) the leftmost source takes the deepest rail - closest to the
  // target - so it never crosses a right-hand sibling's drop; sweeping left
  // mirrors it.
  let sorted = entries.sorted { $0.source.x < $1.source.x }
  let averageSourceX = sorted.map(\.source.x).reduce(0, +) / CGFloat(sorted.count)
  let averageTargetX = sorted.map(\.target.x).reduce(0, +) / CGFloat(sorted.count)
  let depthOrder = averageTargetX >= averageSourceX ? sorted : Array(sorted.reversed())

  var rebuilt: [String: PolicyCanvasEdgeRoute] = [:]
  for (depthRank, entry) in depthOrder.enumerated() {
    let railOffset = gap * CGFloat(depthRank + 1)
    let railY = sourcesAbove ? targetEdgeY - railOffset : targetEdgeY + railOffset
    let points = PolicyCanvasVisibilityRouter.compressCollinear([
      entry.source,
      CGPoint(x: entry.source.x, y: railY),
      CGPoint(x: entry.target.x, y: railY),
      entry.target,
    ])
    guard
      !policyCanvasFanRouteClipsNode(
        points: points, source: entry.source, target: entry.target, nodeFrames: nodeFrames)
    else {
      return nil
    }
    rebuilt[entry.edgeID] = PolicyCanvasEdgeRoute(
      points: points,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points))
  }
  return rebuilt
}

/// True when any segment of a rebuilt fan route passes through a node body other
/// than the family's own source or target node (identified by the node frame
/// that contains the corresponding attach point).
private func policyCanvasFanRouteClipsNode(
  points: [CGPoint],
  source: CGPoint,
  target: CGPoint,
  nodeFrames: [CGRect]
) -> Bool {
  for frame in nodeFrames {
    let endpointFrame = frame.insetBy(dx: -1, dy: -1)
    if endpointFrame.contains(source) || endpointFrame.contains(target) {
      continue
    }
    for (start, end) in zip(points, points.dropFirst())
    where policyCanvasOrthogonalSegmentEntersRect(start, end, frame) {
      return true
    }
  }
  return false
}

/// Bounding-box overlap test for an axis-aligned segment against a rect, using
/// strict comparisons so a segment that merely grazes an edge does not count.
private func policyCanvasOrthogonalSegmentEntersRect(
  _ start: CGPoint,
  _ end: CGPoint,
  _ rect: CGRect
) -> Bool {
  min(start.x, end.x) < rect.maxX
    && max(start.x, end.x) > rect.minX
    && min(start.y, end.y) < rect.maxY
    && max(start.y, end.y) > rect.minY
}
