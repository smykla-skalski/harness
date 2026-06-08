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
/// The returned hint carries both that ordinal and a side-by-side
/// `horizontalLaneY`, so the visibility router starts bundled rails on distinct
/// corridors instead of stacking them and hoping post-processing can untangle the
/// overlap later.
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
    let laneYs = policyCanvasBundleLaneYs(for: sorted)
    for (ordinal, entry) in sorted.enumerated() {
      result[entry.edgeID] = PolicyCanvasEdgeCorridorHint(
        key: key,
        horizontalLaneY: laneYs[ordinal],
        verticalLaneX: entry.verticalLaneX,
        bundleOrdinal: ordinal,
        bundleSize: bundleSize
      )
    }
  }
  return result
}

private func policyCanvasBundleLaneYs(
  for entries: [PolicyCanvasCorridorBundleEntry]
) -> [CGFloat] {
  guard !entries.isEmpty else {
    return []
  }
  let rawLaneYs = entries.enumerated().map { ordinal, entry in
    entry.baseHorizontalLaneY
      + policyCanvasCenteredBundleOffset(ordinal: ordinal, count: entries.count)
  }
  guard
    let targetBand = entries.first?.targetBand,
    let minY = rawLaneYs.min(),
    let maxY = rawLaneYs.max()
  else {
    return rawLaneYs
  }
  let bundleSpan = maxY - minY
  let bandSpan = targetBand.upperBound - targetBand.lowerBound
  let shift: CGFloat
  if bundleSpan <= bandSpan {
    if minY < targetBand.lowerBound {
      shift = targetBand.lowerBound - minY
    } else if maxY > targetBand.upperBound {
      shift = targetBand.upperBound - maxY
    } else {
      shift = 0
    }
  } else {
    let bundleCenter = (minY + maxY) / 2
    let bandCenter = (targetBand.lowerBound + targetBand.upperBound) / 2
    shift = bandCenter - bundleCenter
  }
  return rawLaneYs.map { $0 + shift }
}

private func policyCanvasCenteredBundleOffset(
  ordinal: Int,
  count: Int
) -> CGFloat {
  guard count > 1 else {
    return 0
  }
  return (CGFloat(ordinal) - (CGFloat(count - 1) / 2))
    * PolicyCanvasVisibilityRouter.laneSpreadStep
}
