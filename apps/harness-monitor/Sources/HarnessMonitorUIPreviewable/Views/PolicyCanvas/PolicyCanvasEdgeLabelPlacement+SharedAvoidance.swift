import SwiftUI

func policyCanvasSharedSegmentLabelAvoidance(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> [String: [PolicyCanvasSharedLabelSegment]] {
  let routesByID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0.route) })
  var bundles: [PolicyCanvasSharedLabelBundle] = []
  for entry in policyCanvasSortedLabelRoutes(routes) {
    for segment in policyCanvasSharedLabelSegments(route: entry.route) {
      if let bundleIndex = bundles.firstIndex(where: {
        $0.matches(segment) && !$0.routeIDs.contains(entry.id)
      }) {
        bundles[bundleIndex].append(entry.id, segment: segment)
      } else {
        bundles.append(PolicyCanvasSharedLabelBundle(routeID: entry.id, segment: segment))
      }
    }
  }
  let prioritizedBundles = bundles.sorted { left, right in
    if left.routeIDs.count != right.routeIDs.count {
      return left.routeIDs.count > right.routeIDs.count
    }
    let leftOverlap = left.sharedRange.upperBound - left.sharedRange.lowerBound
    let rightOverlap = right.sharedRange.upperBound - right.sharedRange.lowerBound
    if abs(leftOverlap - rightOverlap) > 0.001 {
      return leftOverlap > rightOverlap
    }
    if left.axis != right.axis {
      return left.axis == .horizontal
    }
    return left.coordinate < right.coordinate
  }
  let seed: [String: [PolicyCanvasSharedLabelSegment]] = [:]
  return prioritizedBundles.reduce(into: seed) { result, bundle in
    guard bundle.routeIDs.count > 1 else {
      return
    }
    let avoidedSegment = PolicyCanvasSharedLabelSegment(
      axis: bundle.axis,
      coordinate: bundle.coordinate,
      range: bundle.sharedRange
    )
    for routeID in bundle.routeIDs
    where
      routesByID[routeID].map({
        policyCanvasRouteHasAlternativeLabelSegment(route: $0, avoiding: [avoidedSegment])
      }) ?? false
    {
      result[routeID, default: []].append(avoidedSegment)
    }
  }
}

// Inclusive `>=`: a segment of exactly `minimumSharedLabelOverlap` qualifies
// as an alternative so labels can still move when the bus is right at the
// minimum overlap length.
private func policyCanvasRouteHasAlternativeLabelSegment(
  route: PolicyCanvasEdgeRoute,
  avoiding avoidedSegments: [PolicyCanvasSharedLabelSegment]
) -> Bool {
  zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
    .contains { segment in
      !segment.matchesAny(avoidedSegments)
        && segment.length >= policyCanvasMinimumSharedLabelOverlap
    }
}

private func policyCanvasSharedLabelSegments(
  route: PolicyCanvasEdgeRoute
) -> [PolicyCanvasSharedLabelSegment] {
  zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
    .filter { $0.length >= policyCanvasMinimumSharedLabelOverlap }
    .map(PolicyCanvasSharedLabelSegment.init(segment:))
}

func policyCanvasPreferredLabelAxis(
  avoidedSegments: [PolicyCanvasSharedLabelSegment]
) -> PolicyCanvasSegmentAxis? {
  let avoidsHorizontal = avoidedSegments.contains(where: { $0.axis == .horizontal })
  let avoidsVertical = avoidedSegments.contains(where: { $0.axis == .vertical })
  if avoidsHorizontal != avoidsVertical {
    return avoidsHorizontal ? .vertical : .horizontal
  }
  if avoidsHorizontal, avoidsVertical {
    return .horizontal
  }
  return nil
}

struct PolicyCanvasSharedLabelSegment {
  let axis: PolicyCanvasSegmentAxis
  let coordinate: CGFloat
  let range: ClosedRange<CGFloat>

  init(segment: PolicyCanvasLabelRouteSegment) {
    axis = segment.axis
    coordinate = segment.isHorizontal ? segment.start.y : segment.start.x
    range = segment.isHorizontal ? segment.xRange : segment.yRange
  }

  init(axis: PolicyCanvasSegmentAxis, coordinate: CGFloat, range: ClosedRange<CGFloat>) {
    self.axis = axis
    self.coordinate = coordinate
    self.range = range
  }
}

private struct PolicyCanvasSharedLabelBundle {
  var axis: PolicyCanvasSegmentAxis
  var coordinate: CGFloat
  var sharedRange: ClosedRange<CGFloat>
  var routeIDs: [String]

  init(routeID: String, segment: PolicyCanvasSharedLabelSegment) {
    axis = segment.axis
    coordinate = segment.coordinate
    sharedRange = segment.range
    routeIDs = [routeID]
  }

  mutating func append(_ routeID: String, segment: PolicyCanvasSharedLabelSegment) {
    let lowerBound = max(sharedRange.lowerBound, segment.range.lowerBound)
    let upperBound = min(sharedRange.upperBound, segment.range.upperBound)
    sharedRange = lowerBound...upperBound
    routeIDs.append(routeID)
  }

  func matches(_ segment: PolicyCanvasSharedLabelSegment) -> Bool {
    axis == segment.axis
      && abs(coordinate - segment.coordinate) < 0.5
      && policyCanvasSharedLabelOverlap(sharedRange, segment.range)
        >= policyCanvasMinimumSharedLabelOverlap
  }
}

private let policyCanvasMinimumSharedLabelOverlap = PolicyCanvasLayout.gridSize * 4

func policyCanvasSharedLabelOverlap(
  _ left: ClosedRange<CGFloat>,
  _ right: ClosedRange<CGFloat>
) -> CGFloat {
  max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
}
