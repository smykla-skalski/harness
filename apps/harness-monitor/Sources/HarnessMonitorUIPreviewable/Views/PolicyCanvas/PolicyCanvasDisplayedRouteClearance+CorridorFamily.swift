import SwiftUI

func policyCanvasRoutesMayShareInteriorCorridor(
  edge: PolicyCanvasEdge,
  corridorKey: PolicyCanvasRouteCorridorKey?,
  with otherEdge: PolicyCanvasEdge,
  otherCorridorKey: PolicyCanvasRouteCorridorKey?
) -> Bool {
  guard policyCanvasEdgesMayShareCorridorFamily(edge: edge, with: otherEdge) else {
    return false
  }
  if let corridorKey, let otherCorridorKey {
    return corridorKey == otherCorridorKey
  }
  if corridorKey == nil && otherCorridorKey == nil {
    return edge.target.nodeID == otherEdge.target.nodeID
  }
  return false
}

/// Comparison key for the *current* edge in the collision-aware corridor
/// checks. Previously-routed edges store a key whose `laneIndex` is bucketed
/// from the realized route's dominant horizontal Y (see
/// `policyCanvasCorridorKey(forRoute:)`), but the current edge has only its
/// layout hint, whose `laneIndex` is an enumerated lane ordinal. Comparing an
/// ordinal against a Y bucket made genuine fan-in siblings (same target and
/// label, distinct sources) read as different corridors at realistic canvas
/// coordinates, so they were spaced apart instead of bundled onto the shared
/// bus. Re-bucket the hint's lane Y with the same formula the realized key
/// uses so both sides of the comparison live in one domain.
func policyCanvasCorridorComparisonKey(
  hint: PolicyCanvasEdgeCorridorHint?,
  lineSpacing: CGFloat
) -> PolicyCanvasRouteCorridorKey? {
  guard let hint else {
    return nil
  }
  let laneStep = max(lineSpacing, PolicyCanvasLayout.gridSize)
  return PolicyCanvasRouteCorridorKey(
    sourceScopeID: hint.key.sourceScopeID,
    targetScopeID: hint.key.targetScopeID,
    targetNodeID: hint.key.targetNodeID,
    label: hint.key.label,
    laneIndex: Int((hint.horizontalLaneY / laneStep).rounded())
  )
}

func policyCanvasRoutesPreferSharedTransportFamily(
  edge: PolicyCanvasEdge,
  corridorKey: PolicyCanvasRouteCorridorKey?,
  with otherEdge: PolicyCanvasEdge,
  otherCorridorKey: PolicyCanvasRouteCorridorKey?
) -> Bool {
  guard policyCanvasEdgesMayShareCorridorFamily(edge: edge, with: otherEdge) else {
    return false
  }
  return
    (policyCanvasRoutesMayShareInteriorCorridor(
      edge: edge,
      corridorKey: corridorKey,
      with: otherEdge,
      otherCorridorKey: otherCorridorKey
    )
    || (edge.source == otherEdge.source && edge.target == otherEdge.target))
}

private func policyCanvasEdgesMayShareCorridorFamily(
  edge: PolicyCanvasEdge,
  with otherEdge: PolicyCanvasEdge
) -> Bool {
  edge.target.nodeID == otherEdge.target.nodeID
    && edge.label == otherEdge.label
}

func policyCanvasRoutesPreferSharedSourceDepartureFamily(
  edge: PolicyCanvasEdge,
  corridorKey: PolicyCanvasRouteCorridorKey?,
  with otherEdge: PolicyCanvasEdge,
  otherCorridorKey: PolicyCanvasRouteCorridorKey?
) -> Bool {
  guard
    edge.source.nodeID == otherEdge.source.nodeID,
    let corridorKey,
    let otherCorridorKey,
    corridorKey.sourceScopeID == otherCorridorKey.sourceScopeID
  else {
    return false
  }
  return true
}

func policyCanvasSiblingBundleBusPenalty(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute]
) -> CGFloat {
  guard
    let lane = policyCanvasDominantHorizontalLaneCoordinate(route)
  else {
    return 0
  }
  let siblingLanes = previousRoutes.compactMap(policyCanvasDominantHorizontalLaneCoordinate)
  guard !siblingLanes.isEmpty else {
    return 0
  }
  let nearestDistance = siblingLanes.map { abs($0 - lane) }.min() ?? 0
  return nearestDistance * 12_000
}

func policyCanvasSourceFamilyDeparturePenalty(
  _ route: PolicyCanvasEdgeRoute,
  with previousRoutes: [PolicyCanvasEdgeRoute],
  minimumSeparation: CGFloat
) -> CGFloat {
  guard let departureBus = policyCanvasPrimaryDepartureBus(route) else {
    return 0
  }
  let siblingCoordinates = previousRoutes.compactMap { previousRoute -> CGFloat? in
    guard let siblingDepartureBus = policyCanvasPrimaryDepartureBus(previousRoute),
      siblingDepartureBus.axis == departureBus.axis
    else {
      return nil
    }
    return siblingDepartureBus.coordinate
  }
  guard !siblingCoordinates.isEmpty else {
    return 0
  }
  let nearestDistance = siblingCoordinates.map { abs($0 - departureBus.coordinate) }.min() ?? 0
  let overlap = max(0, minimumSeparation - nearestDistance)
  return overlap * 18_000
}

private func policyCanvasPrimaryDepartureBus(
  _ route: PolicyCanvasEdgeRoute
) -> (axis: PolicyCanvasSegmentAxis, coordinate: CGFloat)? {
  guard route.points.count >= 4 else {
    return nil
  }
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    if abs(start.y - end.y) < 0.001, abs(start.x - end.x) > 0.001 {
      return (.horizontal, start.y)
    }
    if abs(start.x - end.x) < 0.001, abs(start.y - end.y) > 0.001 {
      return (.vertical, start.x)
    }
  }
  return nil
}

func policyCanvasRoutesRequirePairwiseSpacing(
  edge: PolicyCanvasEdge,
  route: PolicyCanvasEdgeRoute,
  with otherEdge: PolicyCanvasEdge,
  otherRoute: PolicyCanvasEdgeRoute
) -> Bool {
  if !policyCanvasEdgesMayShareCorridorFamily(edge: edge, with: otherEdge) {
    return true
  }
  let sharedNodeIDs = Set(
    [
      edge.source.nodeID == otherEdge.source.nodeID ? edge.source.nodeID : nil,
      edge.source.nodeID == otherEdge.target.nodeID ? edge.source.nodeID : nil,
      edge.target.nodeID == otherEdge.source.nodeID ? edge.target.nodeID : nil,
      edge.target.nodeID == otherEdge.target.nodeID ? edge.target.nodeID : nil,
    ].compactMap { $0 })
  guard !sharedNodeIDs.isEmpty else {
    return true
  }
  for sharedNodeID in sharedNodeIDs {
    guard
      let routeSide = policyCanvasRouteSide(for: edge, nodeID: sharedNodeID, route: route),
      let otherRouteSide = policyCanvasRouteSide(
        for: otherEdge,
        nodeID: sharedNodeID,
        route: otherRoute
      )
    else {
      continue
    }
    if routeSide != otherRouteSide {
      return false
    }
  }
  if edge.source.nodeID == otherEdge.source.nodeID {
    let oppositeAxisDepartureBias =
      (policyCanvasRouteHasStrongVerticalBias(route)
        && policyCanvasRouteHasStrongHorizontalBias(otherRoute))
      || (policyCanvasRouteHasStrongHorizontalBias(route)
        && policyCanvasRouteHasStrongVerticalBias(otherRoute))
    if oppositeAxisDepartureBias {
      return false
    }
  }
  return true
}

private func policyCanvasRouteSide(
  for edge: PolicyCanvasEdge,
  nodeID: String,
  route: PolicyCanvasEdgeRoute
) -> PolicyCanvasPortSide? {
  if edge.source.nodeID == nodeID {
    return policyCanvasRouteSourceSide(route)
  }
  if edge.target.nodeID == nodeID {
    return policyCanvasRouteTargetSide(route)
  }
  return nil
}

private func policyCanvasRouteHasStrongVerticalBias(_ route: PolicyCanvasEdgeRoute) -> Bool {
  guard let source = route.points.first, let target = route.points.last else {
    return false
  }
  return abs(target.y - source.y) >= abs(target.x - source.x) * 2
}

private func policyCanvasRouteHasStrongHorizontalBias(_ route: PolicyCanvasEdgeRoute) -> Bool {
  guard let source = route.points.first, let target = route.points.last else {
    return false
  }
  return abs(target.x - source.x) >= abs(target.y - source.y) * 2
}
