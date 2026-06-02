import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasProjectedRouteInput {
  let cachedOutput: PolicyCanvasRouteWorkerOutput
  let cachedNodePositionsByID: [String: CGPoint]
  let currentNodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let fontScale: CGFloat
}

func policyCanvasNodePositionsByID(_ nodes: [PolicyCanvasNode]) -> [String: CGPoint] {
  Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
}

func policyCanvasProjectedRouteOutput(
  input: PolicyCanvasProjectedRouteInput
) -> PolicyCanvasRouteWorkerOutput {
  guard !input.cachedOutput.routes.isEmpty, !input.cachedNodePositionsByID.isEmpty else {
    return input.cachedOutput
  }

  let movedNodeDeltas = policyCanvasMovedNodeDeltas(
    currentNodes: input.currentNodes,
    cachedNodePositionsByID: input.cachedNodePositionsByID
  )
  guard !movedNodeDeltas.isEmpty else {
    return input.cachedOutput
  }

  let currentNodesByID = Dictionary(uniqueKeysWithValues: input.currentNodes.map { ($0.id, $0) })
  var routes = input.cachedOutput.routes
  var labelPositions = input.cachedOutput.labelPositions
  var didProjectRoute = false
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
      context: PolicyCanvasRouteProjectionContext(
        edge: edge,
        sourceDelta: sourceDelta,
        targetDelta: targetDelta,
        currentNodesByID: currentNodesByID,
        groups: input.groups
      )
    )
    guard projectedRoute != route else {
      continue
    }
    routes[edge.id] = projectedRoute
    if labelPositions[edge.id] != nil {
      labelPositions[edge.id] = projectedRoute.labelPosition
    }
    didProjectRoute = true
  }
  guard didProjectRoute else {
    return input.cachedOutput
  }

  return policyCanvasProjectedRouteOutput(
    input: input,
    routes: routes,
    labelPositions: labelPositions
  )
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

private struct PolicyCanvasRouteProjectionContext {
  let edge: PolicyCanvasEdge
  let sourceDelta: CGSize
  let targetDelta: CGSize
  let currentNodesByID: [String: PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
}

private func policyCanvasProjectedRoute(
  _ route: PolicyCanvasEdgeRoute,
  context: PolicyCanvasRouteProjectionContext
) -> PolicyCanvasEdgeRoute {
  guard let source = route.points.first, let target = route.points.last else {
    return route
  }
  if context.sourceDelta == context.targetDelta {
    return PolicyCanvasEdgeRoute(
      points: route.points.map { policyCanvasTranslatedPoint($0, by: context.sourceDelta) },
      labelPosition: policyCanvasTranslatedPoint(route.labelPosition, by: context.sourceDelta)
    )
  }
  return PolicyCanvasEdgeRoute(
    source: policyCanvasTranslatedPoint(source, by: context.sourceDelta),
    target: policyCanvasTranslatedPoint(target, by: context.targetDelta),
    lane: 0,
    groups: context.groups,
    sourceGroupID: context.currentNodesByID[context.edge.source.nodeID]?.groupID,
    targetGroupID: context.currentNodesByID[context.edge.target.nodeID]?.groupID
  )
}

private func policyCanvasTranslatedPoint(_ point: CGPoint, by delta: CGSize) -> CGPoint {
  CGPoint(x: point.x + delta.width, y: point.y + delta.height)
}
