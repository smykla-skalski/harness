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
