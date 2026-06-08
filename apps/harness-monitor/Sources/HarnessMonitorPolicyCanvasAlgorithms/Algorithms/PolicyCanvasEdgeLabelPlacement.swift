import OSLog
import SwiftUI

private let policyCanvasLabelPlacementSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.perf"
)

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
  let sharedSignpostID = policyCanvasLabelPlacementSignposter.makeSignpostID()
  let sharedInterval = policyCanvasLabelPlacementSignposter.beginInterval(
    "policy_canvas.labels.phase.shared_avoidance",
    id: sharedSignpostID,
    "routes=\(routes.count, privacy: .public)"
  )
  let sharedSegmentAvoidance = policyCanvasSharedSegmentLabelAvoidance(routes)
  policyCanvasLabelPlacementSignposter.endInterval(
    "policy_canvas.labels.phase.shared_avoidance",
    sharedInterval,
    "avoidance=\(sharedSegmentAvoidance.count, privacy: .public)"
  )
  var occupiedFrames: [CGRect] = []
  var positions: [String: CGPoint] = [:]
  // Seat fan-in families (same-label edges stacking into one node) as a
  // coordinated staircase first, so they claim the open middle of their runs
  // before the greedy pass crowds them into the corners. Sizes are taken from
  // each route entry so the reserved frames match the labels that will draw.
  let sizeByID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0.size) })
  let staircaseSignpostID = policyCanvasLabelPlacementSignposter.makeSignpostID()
  let staircaseInterval = policyCanvasLabelPlacementSignposter.beginInterval(
    "policy_canvas.labels.phase.staircase",
    id: staircaseSignpostID,
    "routes=\(routes.count, privacy: .public)"
  )
  let staircase = policyCanvasFanInLabelStaircasePositions(
    routes: routes,
    nodeFrames: nodeFrames
  )
  policyCanvasLabelPlacementSignposter.endInterval(
    "policy_canvas.labels.phase.staircase",
    staircaseInterval,
    "labels=\(staircase.count, privacy: .public)"
  )
  for (id, center) in staircase {
    positions[id] = center
    occupiedFrames.append(policyCanvasLabelFrame(center: center, size: sizeByID[id] ?? .zero))
  }
  let duplicateSignpostID = policyCanvasLabelPlacementSignposter.makeSignpostID()
  let duplicateInterval = policyCanvasLabelPlacementSignposter.beginInterval(
    "policy_canvas.labels.phase.duplicates",
    id: duplicateSignpostID,
    "remaining=\(routes.count - positions.count, privacy: .public)"
  )
  let duplicatePairs = policyCanvasCrowdedDuplicateLabelPairPositions(
    routes: routes.filter { positions[$0.id] == nil },
    nodeFrames: nodeFrames,
    occupiedFrames: occupiedFrames,
    sharedSegmentAvoidance: sharedSegmentAvoidance,
    routeFrames: routeFrames
  )
  policyCanvasLabelPlacementSignposter.endInterval(
    "policy_canvas.labels.phase.duplicates",
    duplicateInterval,
    "labels=\(duplicatePairs.count, privacy: .public)"
  )
  for (id, center) in duplicatePairs {
    positions[id] = center
    occupiedFrames.append(policyCanvasLabelFrame(center: center, size: sizeByID[id] ?? .zero))
  }
  let greedySignpostID = policyCanvasLabelPlacementSignposter.makeSignpostID()
  let greedyInterval = policyCanvasLabelPlacementSignposter.beginInterval(
    "policy_canvas.labels.phase.greedy",
    id: greedySignpostID,
    "remaining=\(routes.count - positions.count, privacy: .public)"
  )
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
  policyCanvasLabelPlacementSignposter.endInterval(
    "policy_canvas.labels.phase.greedy",
    greedyInterval,
    "labels=\(positions.count, privacy: .public)"
  )
  return positions
}

func policyCanvasFastResolvedLabelPositions(
  routes rawRoutes: [PolicyCanvasLabelPlacementRoute],
  routeFrames: [String: [CGRect]],
  nodeFrames: [CGRect]
) -> [String: CGPoint] {
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
  let routeFrameIndex = PolicyCanvasLabelFrameIndex(
    entries: routeFrames.flatMap { id, frames in
      frames.map { PolicyCanvasIndexedLabelFrame(ownerID: id, frame: $0) }
    }
  )
  var occupiedFrameIndex = PolicyCanvasLabelFrameIndex(entries: [])
  var positions: [String: CGPoint] = [:]
  for entry in policyCanvasSortedLabelRoutes(routes) {
    let candidates = policyCanvasLabelCandidates(
      route: entry.route,
      labelSize: entry.size,
      avoidedSegments: [],
      preferredAxis: nil
    ) + [entry.route.arcLengthMidpoint, entry.route.labelPosition]
    let candidateBounds = policyCanvasLabelCandidateBounds(candidates, size: entry.size)
    let nearbyRouteFrames = routeFrameIndex.frames(
      intersecting: candidateBounds,
      excluding: entry.id
    )
    let nearbyOccupiedFrames = occupiedFrameIndex.frames(intersecting: candidateBounds)
    let position =
      candidates.first { candidate in
        let frame = policyCanvasLabelFrame(center: candidate, size: entry.size)
        return !nodeFrames.contains(where: { $0.intersects(frame) })
          && !nearbyRouteFrames.contains(where: { $0.intersects(frame) })
          && !nearbyOccupiedFrames.contains(where: { $0.intersects(frame) })
      }
      ?? policyCanvasLeastBadLabelCandidate(
        candidates,
        size: entry.size,
        nodeFrames: nodeFrames,
        lineBlockers: nearbyRouteFrames + nearbyOccupiedFrames,
        fallback: entry.route.arcLengthMidpoint
    )
    positions[entry.id] = position
    let occupiedFrame = policyCanvasLabelFrame(center: position, size: entry.size)
    occupiedFrameIndex.insert(PolicyCanvasIndexedLabelFrame(ownerID: entry.id, frame: occupiedFrame))
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
  let boundedGraphHull = graphHull.isNull ? nil : graphHull
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
    let crowdedMembers = policyCanvasSortedLabelRoutes(members)
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
        let pairRouteBlockers = routeFrames.reduce(into: [CGRect]()) { frames, element in
          if !pairIDs.contains(element.key) {
            frames.append(contentsOf: element.value)
          }
        }
        let bestPlacement = policyCanvasResolveDuplicateLabelPair(
          PolicyCanvasDuplicateLabelPairContext(
            left: left,
            right: right,
            nodeFrames: nodeFrames,
            occupied: occupied,
            pairRouteBlockers: pairRouteBlockers,
            sharedSegmentAvoidance: sharedSegmentAvoidance,
            graphHull: boundedGraphHull
          )
        )
        guard let bestPlacement else {
          continue
        }
        result[left.id] = bestPlacement.leftCenter
        result[right.id] = bestPlacement.rightCenter
        occupied.append(policyCanvasLabelFrame(center: bestPlacement.leftCenter, size: left.size))
        occupied.append(
          policyCanvasLabelFrame(center: bestPlacement.rightCenter, size: right.size)
        )
        break
      }
    }
  }
  return result
}
