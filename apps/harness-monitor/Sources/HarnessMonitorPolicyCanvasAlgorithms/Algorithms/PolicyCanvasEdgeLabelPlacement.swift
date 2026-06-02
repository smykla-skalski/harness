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
  // avoidance below separates labels that crowd each other, including crowded
  // feeder cases where one label must slide beside its route after the normal
  // on-route search runs out of clear slots.
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
  let duplicatePairs = policyCanvasCrowdedDuplicateLabelPairPositions(
    routes: routes.filter { positions[$0.id] == nil },
    nodeFrames: nodeFrames,
    occupiedFrames: occupiedFrames,
    sharedSegmentAvoidance: sharedSegmentAvoidance,
    routeFrames: routeFrames
  )
  for (id, center) in duplicatePairs {
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

private func policyCanvasCrowdedDuplicateLabelPairPositions(
  routes: [PolicyCanvasLabelPlacementRoute],
  nodeFrames: [CGRect],
  occupiedFrames: [CGRect],
  sharedSegmentAvoidance: [String: [PolicyCanvasSharedLabelSegment]],
  routeFrames: [String: [CGRect]]
) -> [String: CGPoint] {
  let graphHull = nodeFrames.reduce(into: CGRect.null) { partial, frame in
    partial = partial.union(frame)
  }
  func blockingRoutes(excluding excludedIDs: Set<String>) -> [CGRect] {
    routeFrames.reduce(into: [CGRect]()) { result, element in
      if !excludedIDs.contains(element.key) {
        result.append(contentsOf: element.value)
      }
    }
  }
  func isClear(
    center: CGPoint,
    size: CGSize,
    blockers: [CGRect]
  ) -> Bool {
    let frame = policyCanvasLabelFrame(center: center, size: size)
    if !graphHull.isNull && !graphHull.contains(frame) {
      return false
    }
    return !blockers.contains(where: { $0.intersects(frame) })
  }
  var result: [String: CGPoint] = [:]
  var occupied = occupiedFrames
  let groupedMembers = Dictionary(grouping: routes, by: \.label).sorted { left, right in
    let leftAnchor = policyCanvasDuplicateLabelFamilyAnchor(left.value)
    let rightAnchor = policyCanvasDuplicateLabelFamilyAnchor(right.value)
    if leftAnchor.y != rightAnchor.y {
      return leftAnchor.y < rightAnchor.y
    }
    if leftAnchor.x != rightAnchor.x {
      return leftAnchor.x < rightAnchor.x
    }
    return left.key < right.key
  }
  for (_, members) in groupedMembers {
    let crowdedMembers = members.sorted { left, right in
      if left.route.labelPosition.y != right.route.labelPosition.y {
        return left.route.labelPosition.y < right.route.labelPosition.y
      }
      if left.route.labelPosition.x != right.route.labelPosition.x {
        return left.route.labelPosition.x < right.route.labelPosition.x
      }
      return left.id < right.id
    }
    for leftIndex in 0..<crowdedMembers.count {
      let left = crowdedMembers[leftIndex]
      guard result[left.id] == nil else {
        continue
      }
      for rightIndex in (leftIndex + 1)..<crowdedMembers.count {
        let right = crowdedMembers[rightIndex]
        guard result[right.id] == nil else {
          continue
        }
        guard !policyCanvasRoutesShareLabelTrunk(left.route, right.route) else {
          continue
        }
        let pairIDs = Set([left.id, right.id])
        let pairRouteBlockers = blockingRoutes(excluding: pairIDs)
        let leftAvoidedSegments = sharedSegmentAvoidance[left.id, default: []]
        let rightAvoidedSegments = sharedSegmentAvoidance[right.id, default: []]
        let leftPreferredAxis = policyCanvasPreferredLabelAxis(avoidedSegments: leftAvoidedSegments)
        let rightPreferredAxis = policyCanvasPreferredLabelAxis(avoidedSegments: rightAvoidedSegments)
        let leftBlockers = nodeFrames + occupied + pairRouteBlockers
        let rightBlockers = nodeFrames + occupied + pairRouteBlockers
        let leftCandidates = policyCanvasLabelCandidates(
          route: left.route,
          labelSize: left.size,
          avoidedSegments: leftAvoidedSegments,
          preferredAxis: leftPreferredAxis,
          includesAdjacentFallback: true
        )
        let rightCandidates = policyCanvasLabelCandidates(
          route: right.route,
          labelSize: right.size,
          avoidedSegments: rightAvoidedSegments,
          preferredAxis: rightPreferredAxis,
          includesAdjacentFallback: true
        )
        let leftBase = policyCanvasClosestRoutePoint(to: left.route.labelPosition, route: left.route)
        let rightBase = policyCanvasClosestRoutePoint(to: right.route.labelPosition, route: right.route)
        var bestPlacement: (score: CGFloat, left: CGPoint, right: CGPoint)?
        for leftCandidate in leftCandidates {
          guard isClear(center: leftCandidate, size: left.size, blockers: leftBlockers) else {
            continue
          }
          let leftFrame = policyCanvasLabelFrame(center: leftCandidate, size: left.size)
          for rightCandidate in rightCandidates {
            guard isClear(center: rightCandidate, size: right.size, blockers: rightBlockers) else {
              continue
            }
            let rightFrame = policyCanvasLabelFrame(center: rightCandidate, size: right.size)
            guard !leftFrame.intersects(rightFrame) else {
              continue
            }
            let score =
              policyCanvasDistanceSquared(leftCandidate, leftBase)
              + policyCanvasDistanceSquared(rightCandidate, rightBase)
            if let currentBest = bestPlacement, currentBest.score <= score {
              continue
            }
            bestPlacement = (score: score, left: leftCandidate, right: rightCandidate)
          }
        }
        if bestPlacement == nil {
          let relaxedBlockers = nodeFrames + occupied
          for leftCandidate in leftCandidates {
            guard isClear(center: leftCandidate, size: left.size, blockers: relaxedBlockers) else {
              continue
            }
            let leftFrame = policyCanvasLabelFrame(center: leftCandidate, size: left.size)
            for rightCandidate in rightCandidates {
              guard
                isClear(center: rightCandidate, size: right.size, blockers: relaxedBlockers)
              else {
                continue
              }
              let rightFrame = policyCanvasLabelFrame(center: rightCandidate, size: right.size)
              guard !leftFrame.intersects(rightFrame) else {
                continue
              }
              let score =
                policyCanvasDistanceSquared(leftCandidate, leftBase)
                + policyCanvasDistanceSquared(rightCandidate, rightBase)
              if let currentBest = bestPlacement, currentBest.score <= score {
                continue
              }
              bestPlacement = (score: score, left: leftCandidate, right: rightCandidate)
            }
          }
        }
        guard let bestPlacement else {
          continue
        }
        result[left.id] = bestPlacement.left
        result[right.id] = bestPlacement.right
        occupied.append(policyCanvasLabelFrame(center: bestPlacement.left, size: left.size))
        occupied.append(policyCanvasLabelFrame(center: bestPlacement.right, size: right.size))
        break
      }
    }
  }
  return result
}

private func policyCanvasDistanceSquared(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
  let dx = left.x - right.x
  let dy = left.y - right.y
  return (dx * dx) + (dy * dy)
}

private func policyCanvasDuplicateLabelFamilyAnchor(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> CGPoint {
  routes.map(\.route.labelPosition).min { left, right in
    if left.y != right.y {
      return left.y < right.y
    }
    return left.x < right.x
  } ?? .zero
}

private func policyCanvasRoutesShareLabelTrunk(
  _ left: PolicyCanvasEdgeRoute,
  _ right: PolicyCanvasEdgeRoute
) -> Bool {
  let leftSegments = zip(left.points, left.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
  let rightSegments = zip(right.points, right.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
  for leftSegment in leftSegments {
    for rightSegment in rightSegments {
      guard leftSegment.axis == rightSegment.axis else {
        continue
      }
      switch leftSegment.axis {
      case .horizontal:
        guard abs(leftSegment.start.y - rightSegment.start.y) < 0.5 else {
          continue
        }
        if policyCanvasSharedLabelOverlap(leftSegment.xRange, rightSegment.xRange)
          >= policyCanvasMinimumSharedLabelOverlap
        {
          return true
        }
      case .vertical:
        guard abs(leftSegment.start.x - rightSegment.start.x) < 0.5 else {
          continue
        }
        if policyCanvasSharedLabelOverlap(leftSegment.yRange, rightSegment.yRange)
          >= policyCanvasMinimumSharedLabelOverlap
        {
          return true
        }
      }
    }
  }
  return false
}

// Frame collections a label must avoid: already-placed label frames, node
// bodies, and the routed polyline frames of other edges.
struct PolicyCanvasLabelObstacleFrames {
  let occupied: [CGRect]
  let nodes: [CGRect]
  let routes: [CGRect]

  var graphHull: CGRect? {
    let hull = nodes.reduce(into: CGRect.null) { partial, frame in
      partial = partial.union(frame)
    }
    return hull.isNull ? nil : hull
  }
}

private func policyCanvasResolvedLabelPosition(
  route: PolicyCanvasEdgeRoute,
  size: CGSize,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?,
  obstacleFrames: PolicyCanvasLabelObstacleFrames
) -> CGPoint {
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  let lineBlockers = obstacleFrames.occupied + obstacleFrames.routes
  func isClear(_ frame: CGRect, obstacleFrames: PolicyCanvasLabelObstacleFrames) -> Bool {
    !obstacleFrames.occupied.contains(where: { $0.intersects(frame) })
      && !obstacleFrames.nodes.contains(where: { $0.intersects(frame) })
      && !obstacleFrames.routes.contains(where: { $0.intersects(frame) })
  }
  func fitsGraphHull(_ frame: CGRect, obstacleFrames: PolicyCanvasLabelObstacleFrames) -> Bool {
    guard let graphHull = obstacleFrames.graphHull else {
      return true
    }
    return graphHull.contains(frame)
  }
  func firstClearCandidate(
    _ candidates: [CGPoint],
    obstacleFrames: PolicyCanvasLabelObstacleFrames,
    requiresGraphHull: Bool
  ) -> CGPoint? {
    for candidate in candidates {
      let frame = policyCanvasLabelFrame(center: candidate, size: size)
      guard isClear(frame, obstacleFrames: obstacleFrames) else {
        continue
      }
      if requiresGraphHull, !fitsGraphHull(frame, obstacleFrames: obstacleFrames) {
        continue
      }
      return candidate
    }
    return nil
  }
  func leastBadGraphHullCandidate(_ candidates: [CGPoint]) -> CGPoint? {
    let inHullCandidates = candidates.filter { candidate in
      fitsGraphHull(policyCanvasLabelFrame(center: candidate, size: size), obstacleFrames: obstacleFrames)
    }
    guard !inHullCandidates.isEmpty else {
      return nil
    }
    return policyCanvasLeastBadLabelCandidate(
      inHullCandidates,
      size: size,
      nodeFrames: obstacleFrames.nodes,
      lineBlockers: lineBlockers,
      fallback: base
    )
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
    if let candidate = firstClearCandidate(
      candidates,
      obstacleFrames: obstacleFrames,
      requiresGraphHull: true
    ) {
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
  if let candidate = firstClearCandidate(
    candidates,
    obstacleFrames: obstacleFrames,
    requiresGraphHull: true
  ) {
    return candidate
  }
  allCandidates.append(contentsOf: candidates)
  // Keep labels inside the graph hull even when that means grazing a sibling
  // route, instead of jumping to a perfectly clear off-canvas stub.
  if let candidate = leastBadGraphHullCandidate(allCandidates) {
    return candidate
  }
  if let candidate = firstClearCandidate(
    allCandidates,
    obstacleFrames: obstacleFrames,
    requiresGraphHull: false
  ) {
    return candidate
  }

  // Crowded: no collision-free spot exists on this edge. Pick the least-bad
  // candidate, ranking node-body overlap ahead of route/label overlap so the
  // label slides onto its own run rather than covering a node - see
  // policyCanvasLeastBadLabelCandidate.
  return policyCanvasLeastBadLabelCandidate(
    allCandidates,
    size: size,
    nodeFrames: obstacleFrames.nodes,
    lineBlockers: lineBlockers,
    fallback: base
  )
}

private func policyCanvasLabelCandidates(
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

private func policyCanvasLabelCandidates(
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
        ),
        includesAdjacentFallback: includesAdjacentFallback
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
