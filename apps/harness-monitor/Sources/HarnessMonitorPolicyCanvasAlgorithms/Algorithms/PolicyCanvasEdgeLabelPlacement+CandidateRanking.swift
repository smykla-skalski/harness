import SwiftUI

func policyCanvasLabelCandidates(
  route: PolicyCanvasEdgeRoute,
  labelSize: CGSize,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?,
  includesAdjacentFallback: Bool = false
) -> [CGPoint] {
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  let segments = policyCanvasRankedLabelSegments(
    route: route,
    base: base,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  return policyCanvasLabelCandidates(
    segments: segments,
    base: base,
    labelSize: labelSize,
    preferredAxis: preferredAxis,
    includesAdjacentFallback: includesAdjacentFallback
  )
}

func policyCanvasLabelCandidates(
  segments: [PolicyCanvasLabelRouteSegment],
  base: CGPoint,
  labelSize: CGSize,
  preferredAxis: PolicyCanvasSegmentAxis?,
  includesAdjacentFallback: Bool = false
) -> [CGPoint] {
  var candidates: [CGPoint] = []
  for segment in segments {
    candidates.append(
      contentsOf: policyCanvasLabelCandidates(
        on: segment,
        base: base,
        size: labelSize,
        options: PolicyCanvasLabelPlacementOptions(
          keepsCornerClearance: true,
          preferAdjacentVerticalPlacement: preferredAxis == .vertical && !segment.isHorizontal,
          preferAdjacentHorizontalPlacement: preferredAxis == .horizontal && segment.isHorizontal
        ),
        includesAdjacentFallback: includesAdjacentFallback
      )
    )
  }
  for segment in segments {
    candidates.append(
      contentsOf: policyCanvasLabelCandidates(
        on: segment,
        base: base,
        size: labelSize,
        options: PolicyCanvasLabelPlacementOptions(
          keepsCornerClearance: false,
          preferAdjacentVerticalPlacement: preferredAxis == .vertical && !segment.isHorizontal,
          preferAdjacentHorizontalPlacement: preferredAxis == .horizontal && segment.isHorizontal
        ),
        includesAdjacentFallback: includesAdjacentFallback
      )
    )
  }
  // Dedup with sub-grid tolerance so candidates that drift by <quantum apart
  // collapse to one. Bit-exact Set<CGPoint> dedup let near-duplicates from
  // two adjacent segments cascade through and fight for the same lane.
  let quantum: CGFloat = PolicyCanvasLayout.gridSize / 5
  var seen: Set<PolicyCanvasLabelCandidateKey> = []
  return candidates.filter { point in
    seen.insert(PolicyCanvasLabelCandidateKey(point: point, quantum: quantum)).inserted
  }
}

private struct PolicyCanvasLabelCandidateKey: Hashable {
  let x: Int
  let y: Int

  init(point: CGPoint, quantum: CGFloat) {
    let step = max(quantum, 1)
    self.x = Int((point.x / step).rounded())
    self.y = Int((point.y / step).rounded())
  }
}

func policyCanvasPreferredLabelSegments(
  route: PolicyCanvasEdgeRoute,
  base: CGPoint,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?
) -> [PolicyCanvasLabelRouteSegment] {
  let rankedSegments = policyCanvasRankedLabelSegments(
    route: route,
    base: base,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  let nonAvoidedSegments = rankedSegments.filter { segment in
    !segment.matchesAny(avoidedSegments)
  }
  if let preferredAxis {
    let axisSegments = nonAvoidedSegments.filter { $0.axis == preferredAxis }
    if !axisSegments.isEmpty {
      return axisSegments
    }
  }
  if !nonAvoidedSegments.isEmpty, !avoidedSegments.isEmpty {
    return nonAvoidedSegments
  }
  return []
}

func policyCanvasRankedLabelSegments(
  route: PolicyCanvasEdgeRoute,
  base: CGPoint,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?
) -> [PolicyCanvasLabelRouteSegment] {
  zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
    .sorted { left, right in
      let leftAvoided = left.matchesAny(avoidedSegments)
      let rightAvoided = right.matchesAny(avoidedSegments)
      if leftAvoided != rightAvoided {
        return !leftAvoided
      }
      if let preferredAxis, left.axis != right.axis {
        return left.axis == preferredAxis
      }
      if left.containsProjection(of: base) != right.containsProjection(of: base) {
        return left.containsProjection(of: base)
      }
      if left.isHorizontal != right.isHorizontal {
        return left.isHorizontal
      }
      let leftDistance = left.distanceSquared(to: base)
      let rightDistance = right.distanceSquared(to: base)
      if abs(leftDistance - rightDistance) > 0.001 {
        return leftDistance < rightDistance
      }
      return left.length > right.length
    }
}

// Per-segment label placement flags: whether to keep corner clearance, and
// whether to also emit candidates offset adjacent to the segment along each
// axis when that axis is the preferred one.
struct PolicyCanvasLabelPlacementOptions {
  let keepsCornerClearance: Bool
  let preferAdjacentVerticalPlacement: Bool
  let preferAdjacentHorizontalPlacement: Bool
}
