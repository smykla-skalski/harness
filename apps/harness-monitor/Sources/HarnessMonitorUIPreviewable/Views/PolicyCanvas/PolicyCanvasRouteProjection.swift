import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasProjectedRouteInput {
  let cachedOutput: PolicyCanvasRouteWorkerOutput
  let cachedNodePositionsByID: [String: CGPoint]
  let currentNodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let fontScale: CGFloat
}

struct PolicyCanvasProjectedRouteResult {
  let output: PolicyCanvasRouteWorkerOutput
  let matchesCurrentGraphShape: Bool
  let canCommitAsCurrentGraph: Bool
}

struct PolicyCanvasLiveDragRouteInput {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let fontScale: CGFloat
  let algorithmSelection: PolicyCanvasAlgorithmSelection
  let movedNodeIDs: Set<String>
  let previous: PolicyCanvasRouteWorkerOutput
}

func policyCanvasNodePositionsByID(_ nodes: [PolicyCanvasNode]) -> [String: CGPoint] {
  Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
}

/// Route the edges incident to the dragged nodes through the real selective
/// router synchronously, reusing `previous` for the untouched edges. This is the
/// drag-frame replacement for the geometric projection: the displayed wires are
/// the router's true output (body-clean, port-correct) every tick instead of a
/// translated approximation, so dropping a node changes nothing. A position drag
/// leaves node labels, connect targets, and accessibility entries untouched, so
/// those maps are carried from `previous` rather than recomputed. Returns `nil`
/// when selective routing does not apply (topology changed, or no moved edge);
/// the caller then falls back to the previous output.
func policyCanvasLiveDragRoutedOutput(
  input: PolicyCanvasLiveDragRouteInput
) -> PolicyCanvasRouteWorkerOutput? {
  guard !input.movedNodeIDs.isEmpty, !input.previous.routes.isEmpty else {
    return nil
  }
  let prepared = PolicyCanvasPreparedRouteInput(
    input: PolicyCanvasRouteWorkerInput(
      nodes: input.nodes,
      groups: input.groups,
      edges: input.edges,
      fontScale: input.fontScale,
      algorithmSelection: input.algorithmSelection
    )
  )
  guard
    let computation = prepared.selectiveRouteComputation(
      router: policyCanvasDefaultEdgeRouter(),
      algorithmSelection: input.algorithmSelection,
      movedNodeIDs: input.movedNodeIDs,
      previousRoutes: input.previous.routes,
      previousPortMarkerLayout: input.previous.portMarkerLayout
    )
  else {
    return nil
  }
  return PolicyCanvasRouteWorkerOutput(
    routes: computation.routes,
    labelPositions: computation.labelPositions,
    portVisibility: computation.portVisibility,
    portMarkerLayout: computation.portMarkerLayout,
    visibleBounds: computation.visibleBounds,
    contentSize: policyCanvasVisibleContentSize(visibleBounds: computation.visibleBounds),
    accessibilityEdgeLabelsByID: input.previous.accessibilityEdgeLabelsByID,
    accessibilityNodeEntries: input.previous.accessibilityNodeEntries,
    accessibilityEdgeEntries: input.previous.accessibilityEdgeEntries,
    nodeAccessibilityValuesByID: input.previous.nodeAccessibilityValuesByID,
    connectTargetsByNodeID: input.previous.connectTargetsByNodeID
  )
}

func policyCanvasProjectedRouteOutput(
  input: PolicyCanvasProjectedRouteInput
) -> PolicyCanvasRouteWorkerOutput {
  policyCanvasProjectedRouteResult(input: input).output
}

func policyCanvasProjectedRouteResult(
  input: PolicyCanvasProjectedRouteInput
) -> PolicyCanvasProjectedRouteResult {
  guard !input.cachedOutput.routes.isEmpty, !input.cachedNodePositionsByID.isEmpty else {
    return PolicyCanvasProjectedRouteResult(
      output: input.cachedOutput,
      matchesCurrentGraphShape: false,
      canCommitAsCurrentGraph: false
    )
  }
  guard policyCanvasProjectionMatchesCurrentGraphShape(input) else {
    return PolicyCanvasProjectedRouteResult(
      output: input.cachedOutput,
      matchesCurrentGraphShape: false,
      canCommitAsCurrentGraph: false
    )
  }

  let movedNodeDeltas = policyCanvasMovedNodeDeltas(
    currentNodes: input.currentNodes,
    cachedNodePositionsByID: input.cachedNodePositionsByID
  )
  guard !movedNodeDeltas.isEmpty else {
    return PolicyCanvasProjectedRouteResult(
      output: input.cachedOutput,
      matchesCurrentGraphShape: true,
      canCommitAsCurrentGraph: false
    )
  }

  var routes = input.cachedOutput.routes
  var labelPositions = input.cachedOutput.labelPositions
  for edge in input.edges {
    let sourceDelta = movedNodeDeltas[edge.source.nodeID] ?? .zero
    let targetDelta = movedNodeDeltas[edge.target.nodeID] ?? .zero
    guard sourceDelta != .zero || targetDelta != .zero,
      let route = routes[edge.id]
    else {
      continue
    }
    let projectedRoute = policyCanvasProjectedRoute(
      route,
      sourceDelta: sourceDelta,
      targetDelta: targetDelta
    )
    guard projectedRoute != route else {
      continue
    }
    routes[edge.id] = projectedRoute
    if labelPositions[edge.id] != nil {
      labelPositions[edge.id] = projectedRoute.labelPosition
    }
  }

  return PolicyCanvasProjectedRouteResult(
    output: policyCanvasProjectedRouteOutput(
      input: input,
      routes: routes,
      labelPositions: labelPositions
    ),
    matchesCurrentGraphShape: true,
    canCommitAsCurrentGraph: true
  )
}

private func policyCanvasProjectionMatchesCurrentGraphShape(
  _ input: PolicyCanvasProjectedRouteInput
) -> Bool {
  Set(input.currentNodes.map(\.id)) == Set(input.cachedNodePositionsByID.keys)
    && Set(input.edges.map(\.id)) == Set(input.cachedOutput.routes.keys)
}

private func policyCanvasMovedNodeDeltas(
  currentNodes: [PolicyCanvasNode],
  cachedNodePositionsByID: [String: CGPoint]
) -> [String: CGSize] {
  var movedNodeDeltas: [String: CGSize] = [:]
  movedNodeDeltas.reserveCapacity(currentNodes.count)
  for node in currentNodes {
    guard let cachedPosition = cachedNodePositionsByID[node.id] else {
      continue
    }
    let delta = CGSize(
      width: node.position.x - cachedPosition.x,
      height: node.position.y - cachedPosition.y
    )
    if delta != .zero {
      movedNodeDeltas[node.id] = delta
    }
  }
  return movedNodeDeltas
}

private func policyCanvasProjectedRouteOutput(
  input: PolicyCanvasProjectedRouteInput,
  routes: [String: PolicyCanvasEdgeRoute],
  labelPositions: [String: CGPoint]
) -> PolicyCanvasRouteWorkerOutput {
  let prepared = PolicyCanvasPreparedRouteInput(
    input: PolicyCanvasRouteWorkerInput(
      nodes: input.currentNodes,
      groups: input.groups,
      edges: input.edges,
      fontScale: input.fontScale
    )
  )
  let visibleBounds = prepared.visibleBounds(routes: routes, labelPositions: labelPositions)
  let contentSize = policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
  return PolicyCanvasRouteWorkerOutput(
    routes: routes,
    labelPositions: labelPositions,
    portVisibility: input.cachedOutput.portVisibility,
    portMarkerLayout: input.cachedOutput.portMarkerLayout,
    visibleBounds: visibleBounds,
    contentSize: contentSize,
    accessibilityEdgeLabelsByID: input.cachedOutput.accessibilityEdgeLabelsByID,
    accessibilityNodeEntries: input.cachedOutput.accessibilityNodeEntries,
    accessibilityEdgeEntries: input.cachedOutput.accessibilityEdgeEntries,
    nodeAccessibilityValuesByID: input.cachedOutput.nodeAccessibilityValuesByID,
    connectTargetsByNodeID: input.cachedOutput.connectTargetsByNodeID
  )
}

private func policyCanvasProjectedRoute(
  _ route: PolicyCanvasEdgeRoute,
  sourceDelta: CGSize,
  targetDelta: CGSize
) -> PolicyCanvasEdgeRoute {
  guard !route.points.isEmpty else {
    return route
  }
  if sourceDelta == targetDelta {
    return PolicyCanvasEdgeRoute(
      points: route.points.map { policyCanvasTranslatedPoint($0, by: sourceDelta) },
      labelPosition: policyCanvasTranslatedPoint(route.labelPosition, by: sourceDelta)
    )
  }
  let points = policyCanvasProjectedEndpointPoints(
    route.points,
    sourceDelta: sourceDelta,
    targetDelta: targetDelta
  )
  return PolicyCanvasEdgeRoute(
    points: points,
    labelPosition: policyCanvasProjectedRouteLabelPosition(for: points)
  )
}

private func policyCanvasTranslatedPoint(_ point: CGPoint, by delta: CGSize) -> CGPoint {
  CGPoint(x: point.x + delta.width, y: point.y + delta.height)
}

private func policyCanvasProjectedEndpointPoints(
  _ points: [CGPoint],
  sourceDelta: CGSize,
  targetDelta: CGSize
) -> [CGPoint] {
  guard points.count >= 2 else {
    return points
  }
  var projected = points
  if sourceDelta != .zero {
    projected = policyCanvasProjectEndpoint(
      points: projected,
      endpointIndex: projected.startIndex,
      neighborIndex: projected.index(after: projected.startIndex),
      delta: sourceDelta
    )
  }
  if targetDelta != .zero {
    projected = policyCanvasProjectEndpoint(
      points: projected,
      endpointIndex: projected.index(before: projected.endIndex),
      neighborIndex: projected.index(projected.endIndex, offsetBy: -2),
      delta: targetDelta
    )
  }
  return policyCanvasCompressProjectedRoute(projected)
}

private func policyCanvasProjectEndpoint(
  points: [CGPoint],
  endpointIndex: Int,
  neighborIndex: Int,
  delta: CGSize
) -> [CGPoint] {
  var projected = points
  let movedEndpoint = policyCanvasTranslatedPoint(points[endpointIndex], by: delta)
  let neighbor = points[neighborIndex]
  if movedEndpoint.x == neighbor.x || movedEndpoint.y == neighbor.y {
    projected[endpointIndex] = movedEndpoint
    return projected
  }
  let originalEndpoint = points[endpointIndex]
  let originalSegmentWasHorizontal =
    abs(originalEndpoint.y - neighbor.y) <= abs(originalEndpoint.x - neighbor.x)
  let bend =
    originalSegmentWasHorizontal
    ? CGPoint(x: neighbor.x, y: movedEndpoint.y)
    : CGPoint(x: movedEndpoint.x, y: neighbor.y)
  if endpointIndex < neighborIndex {
    projected.replaceSubrange(endpointIndex...neighborIndex, with: [movedEndpoint, bend, neighbor])
  } else {
    projected.replaceSubrange(neighborIndex...endpointIndex, with: [neighbor, bend, movedEndpoint])
  }
  return projected
}

private func policyCanvasCompressProjectedRoute(_ points: [CGPoint]) -> [CGPoint] {
  guard points.count > 2 else {
    return points
  }
  var result: [CGPoint] = []
  result.reserveCapacity(points.count)
  for point in points {
    if let last = result.last, last == point {
      continue
    }
    result.append(point)
    while result.count >= 3 {
      let count = result.count
      let first = result[count - 3]
      let middle = result[count - 2]
      let last = result[count - 1]
      let isHorizontal = first.y == middle.y && middle.y == last.y
      let isVertical = first.x == middle.x && middle.x == last.x
      guard isHorizontal || isVertical else {
        break
      }
      result.remove(at: count - 2)
    }
  }
  return result
}

private func policyCanvasProjectedRouteLabelPosition(for points: [CGPoint]) -> CGPoint {
  guard points.count >= 2 else {
    return points.first ?? .zero
  }
  var bestStart = points[0]
  var bestEnd = points[1]
  var bestLength: CGFloat = -1
  for (start, end) in zip(points, points.dropFirst()) {
    let length = abs(end.x - start.x) + abs(end.y - start.y)
    if length > bestLength {
      bestStart = start
      bestEnd = end
      bestLength = length
    }
  }
  return CGPoint(
    x: (bestStart.x + bestEnd.x) / 2,
    y: (bestStart.y + bestEnd.y) / 2
  )
}
