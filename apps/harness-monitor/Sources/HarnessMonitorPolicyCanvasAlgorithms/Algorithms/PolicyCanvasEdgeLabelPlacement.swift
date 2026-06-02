import SwiftUI

public struct PolicyCanvasLabelPlacementRoute {
  public let id: String
  public let label: String
  public let route: PolicyCanvasEdgeRoute
  public let size: CGSize

  public init(
    id: String,
    label: String,
    route: PolicyCanvasEdgeRoute,
    size: CGSize
  ) {
    self.id = id
    self.label = label
    self.route = route
    self.size = size
  }
}

public func policyCanvasRouteFrames(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> [String: [CGRect]] {
  policyCanvasRouteFrames(routes.map { (id: $0.id, route: $0.route) })
}

public func policyCanvasRouteFrames(
  _ routes: [(id: String, route: PolicyCanvasEdgeRoute)]
) -> [String: [CGRect]] {
  Dictionary(
    uniqueKeysWithValues: routes.map { entry in
      (entry.id, policyCanvasRouteSegmentFrames(entry.route))
    }
  )
}

public func policyCanvasResolvedLabelPositions(
  routes: [(id: String, route: PolicyCanvasEdgeRoute)],
  nodeFrames: [CGRect],
  labelSize: CGSize
) -> [String: CGPoint] {
  let placementRoutes = routes.map {
    PolicyCanvasLabelPlacementRoute(
      id: $0.id,
      label: $0.id,
      route: $0.route,
      size: labelSize
    )
  }
  return policyCanvasResolvedLabelPositions(
    routes: placementRoutes,
    nodeFrames: nodeFrames,
    routeFrames: [:]
  )
}

public func policyCanvasResolvedLabelPositions(
  routes: [(id: String, route: PolicyCanvasEdgeRoute)],
  nodeFrames: [CGRect],
  routeFrames: [String: [CGRect]],
  labelSize: CGSize
) -> [String: CGPoint] {
  let placementRoutes = routes.map {
    PolicyCanvasLabelPlacementRoute(
      id: $0.id,
      label: $0.id,
      route: $0.route,
      size: labelSize
    )
  }
  return policyCanvasResolvedLabelPositions(
    routes: placementRoutes,
    nodeFrames: nodeFrames,
    routeFrames: routeFrames
  )
}

public func policyCanvasResolvedLabelPositions(
  routes rawRoutes: [PolicyCanvasLabelPlacementRoute],
  nodeFrames: [CGRect],
  routeFrames: [String: [CGRect]]
) -> [String: CGPoint] {
  // Collapse redundant collinear points before placing labels so a straight edge
  // is ONE segment. A stray midpoint otherwise splits a straight run in two, and
  // the candidate ranking seats the label on whichever sub-segment happens to
  // contain the midpoint - the source half for some edges, the target half for
  // others - which is the scattered, inconsistent placement seen on sibling-row
  // chain edges. One segment per straight run puts every such label predictably
  // at the run's midpoint.
  let routes = rawRoutes.map { entry in
    PolicyCanvasLabelPlacementRoute(
      id: entry.id,
      label: entry.label,
      route: PolicyCanvasEdgeRoute(
        points: PolicyCanvasVisibilityRouter.compressCollinear(entry.route.points),
        labelPosition: entry.route.labelPosition
      ),
      size: entry.size
    )
  }
  // Each label is keyed by its own edge id and placed independently on that
  // edge. Labels are NOT grouped or staggered by shared text: two edges that
  // happen to carry the same words ("evidence failure") are still distinct
  // edges and each label belongs on its own route. Geometric collision
  // avoidance below separates labels that crowd each other; identical labels
  // on genuinely overlapping geometry simply coincide, which reads correctly.
  let sharedSegmentAvoidance = policyCanvasSharedSegmentLabelAvoidance(routes)
  var occupiedFrames: [CGRect] = []
  var positions: [String: CGPoint] = [:]
  // Seat fan-in families (same-label edges stacking into one node) as a
  // coordinated staircase first, so they claim the open middle of their runs
  // before the greedy pass crowds them into the corners. Sizes are taken from
  // each route entry so the reserved frames match the labels that will draw.
  let sizeByID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0.size) })
  let staircase = policyCanvasFanInLabelStaircasePositions(
    routes: routes,
    nodeFrames: nodeFrames
  )
  for (id, center) in staircase {
    positions[id] = center
    occupiedFrames.append(policyCanvasLabelFrame(center: center, size: sizeByID[id] ?? .zero))
  }
  for entry in policyCanvasSortedLabelRoutes(routes) where positions[entry.id] == nil {
    let blockingRouteFrames = routeFrames.reduce(into: [CGRect]()) { result, element in
      if element.key != entry.id {
        result.append(contentsOf: element.value)
      }
    }
    let avoidedSegments = sharedSegmentAvoidance[entry.id, default: []]
    let preferredAxis = policyCanvasPreferredLabelAxis(avoidedSegments: avoidedSegments)
    let position = policyCanvasResolvedLabelPosition(
      route: entry.route,
      size: entry.size,
      avoidedSegments: avoidedSegments,
      preferredAxis: preferredAxis,
      obstacleFrames: PolicyCanvasLabelObstacleFrames(
        occupied: occupiedFrames,
        nodes: nodeFrames,
        routes: blockingRouteFrames
      )
    )
    positions[entry.id] = position
    occupiedFrames.append(policyCanvasLabelFrame(center: position, size: entry.size))
  }
  return positions
}

func policyCanvasSortedLabelRoutes(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> [PolicyCanvasLabelPlacementRoute] {
  routes.sorted { left, right in
    if left.route.labelPosition.y != right.route.labelPosition.y {
      return left.route.labelPosition.y < right.route.labelPosition.y
    }
    if left.route.labelPosition.x != right.route.labelPosition.x {
      return left.route.labelPosition.x < right.route.labelPosition.x
    }
    return left.id < right.id
  }
}

// Frame collections a label must avoid: already-placed label frames, node
// bodies, and the routed polyline frames of other edges.
struct PolicyCanvasLabelObstacleFrames {
  let occupied: [CGRect]
  let nodes: [CGRect]
  let routes: [CGRect]
}

private func policyCanvasResolvedLabelPosition(
  route: PolicyCanvasEdgeRoute,
  size: CGSize,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?,
  obstacleFrames: PolicyCanvasLabelObstacleFrames
) -> CGPoint {
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  func isClear(_ frame: CGRect) -> Bool {
    !obstacleFrames.occupied.contains(where: { $0.intersects(frame) })
      && !obstacleFrames.nodes.contains(where: { $0.intersects(frame) })
      && !obstacleFrames.routes.contains(where: { $0.intersects(frame) })
  }

  var allCandidates: [CGPoint] = []
  let preferredSegments = policyCanvasPreferredLabelSegments(
    route: route,
    base: base,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  if !preferredSegments.isEmpty {
    let candidates = policyCanvasLabelCandidates(
      segments: preferredSegments,
      base: base,
      labelSize: size,
      preferredAxis: preferredAxis
    )
    for candidate in candidates
    where isClear(policyCanvasLabelFrame(center: candidate, size: size)) {
      return candidate
    }
    allCandidates.append(contentsOf: candidates)
  }
  let candidates = policyCanvasLabelCandidates(
    route: route,
    labelSize: size,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  for candidate in candidates
  where isClear(policyCanvasLabelFrame(center: candidate, size: size)) {
    return candidate
  }
  allCandidates.append(contentsOf: candidates)

  // Crowded: no collision-free spot exists on this edge. Pick the least-bad
  // candidate, ranking node-body overlap ahead of route/label overlap so the
  // label slides onto its own run rather than covering a node - see
  // policyCanvasLeastBadLabelCandidate.
  return policyCanvasLeastBadLabelCandidate(
    allCandidates,
    size: size,
    nodeFrames: obstacleFrames.nodes,
    lineBlockers: obstacleFrames.occupied + obstacleFrames.routes,
    fallback: base
  )
}

private func policyCanvasLabelCandidates(
  route: PolicyCanvasEdgeRoute,
  labelSize: CGSize,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?
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
    preferredAxis: preferredAxis
  )
}

private func policyCanvasLabelCandidates(
  segments: [PolicyCanvasLabelRouteSegment],
  base: CGPoint,
  labelSize: CGSize,
  preferredAxis: PolicyCanvasSegmentAxis?
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
        )
      ))
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
        )
      ))
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

struct PolicyCanvasLabelCandidateKey: Hashable {
  let x: Int
  let y: Int

  init(point: CGPoint, quantum: CGFloat) {
    let step = max(quantum, 1)
    self.x = Int((point.x / step).rounded())
    self.y = Int((point.y / step).rounded())
  }
}

private func policyCanvasPreferredLabelSegments(
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

private func policyCanvasRankedLabelSegments(
  route: PolicyCanvasEdgeRoute,
  base: CGPoint,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?
) -> [PolicyCanvasLabelRouteSegment] {
  return zip(route.points, route.points.dropFirst())
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
