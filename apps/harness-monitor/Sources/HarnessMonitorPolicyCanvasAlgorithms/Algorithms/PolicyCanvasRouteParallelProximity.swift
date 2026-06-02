import SwiftUI

/// Cost of `route` running parallel-and-too-close to any incompatible previous
/// route, used to separate edges that carry different labels yet share a
/// crowded band.
///
/// `policyCanvasRouteMaxInteriorSharedOverlap` only counts EXACT collinear
/// overlap (`abs(Δcoordinate) < 0.001`). Two buses a handful of points apart -
/// a fan-in run at y=1734 beside a through-route at y=1730 - never registered,
/// so the incompatible-separation pass skipped them and they rendered as one
/// colliding line. This metric closes that gap: a same-axis segment pair whose
/// lanes sit within `minimumSpacing` of each other and whose extents overlap
/// scores `overlap * (minimumSpacing - gap)`. Exact collinearity (gap 0) scores
/// highest and still dominates; a pair separated by at least `minimumSpacing`
/// scores zero. The separation search both triggers on and minimizes this cost,
/// so it drives the through-route onto a lane a full `minimumSpacing` clear of
/// the fan band rather than only off an exact shared row.
func policyCanvasRouteMaxIncompatibleParallelCost(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> CGFloat {
  policyCanvasRouteMaxIncompatibleParallelCost(
    segments: policyCanvasInteriorRouteSegments(route),
    with: previousRoutes,
    minimumSpacing: minimumSpacing
  )
}

func policyCanvasRouteMaxIncompatibleParallelCost(
  segments: [PolicyCanvasRouteSegment],
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSpacing: CGFloat
) -> CGFloat {
  policyCanvasRouteMaxIncompatibleParallelCost(
    segments: segments,
    with: previousRoutes.map(policyCanvasInteriorRouteSegments),
    minimumSpacing: minimumSpacing
  )
}

func policyCanvasRouteMaxIncompatibleParallelCost(
  segments: [PolicyCanvasRouteSegment],
  with previousRouteSegments: [[PolicyCanvasRouteSegment]],
  minimumSpacing: CGFloat
) -> CGFloat {
  guard !segments.isEmpty, minimumSpacing > 0 else {
    return 0
  }
  return previousRouteSegments.reduce(CGFloat.zero) { routeMax, previousSegments in
    let pairMax = previousSegments.reduce(CGFloat.zero) { segmentMax, previousSegment in
      let best = segments.reduce(CGFloat.zero) { inner, segment in
        max(
          inner,
          policyCanvasParallelEncroachment(
            segment,
            previousSegment,
            minimumSpacing: minimumSpacing
          )
        )
      }
      return max(segmentMax, best)
    }
    return max(routeMax, pairMax)
  }
}

private func policyCanvasParallelEncroachment(
  _ segment: PolicyCanvasRouteSegment,
  _ other: PolicyCanvasRouteSegment,
  minimumSpacing: CGFloat
) -> CGFloat {
  guard segment.isSameAxis(as: other) else {
    return 0
  }
  let gap = segment.axisDistance(to: other)
  guard gap < minimumSpacing else {
    return 0
  }
  let overlap = segment.overlap(with: other)
  guard overlap > 0.001 else {
    return 0
  }
  return overlap * (minimumSpacing - gap)
}
