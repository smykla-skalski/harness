import CoreGraphics

struct PolicyCanvasObstacleAwareGreedyLabelPlacement: PolicyCanvasEdgeLabelPlacementAlgorithm {
  private let greedyRouteFrameComplexityLimit = 8_000

  func placeLabels(input: PolicyCanvasLabelPlacementInput) -> [String: CGPoint] {
    let prepared = input.prepared
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: prepared.fontScale)
    let routeFrames = policyCanvasRouteFrames(
      input.routes.map { (id: $0.key, route: $0.value) }
    )
    let labelledRoutes: [PolicyCanvasLabelPlacementRoute] = prepared.edges.compactMap { edge in
      guard !edge.label.isEmpty, let route = input.routes[edge.id] else {
        return nil
      }
      return PolicyCanvasLabelPlacementRoute(
        id: edge.id,
        label: edge.label,
        route: route,
        size: metrics.size(for: edge.label)
      )
    }
    let routeFrameCount = routeFrames.values.reduce(0) { $0 + $1.count }
    if labelledRoutes.count * max(1, routeFrameCount) > greedyRouteFrameComplexityLimit {
      return policyCanvasFastResolvedLabelPositions(
        routes: labelledRoutes,
        routeFrames: routeFrames,
        nodeFrames: prepared.nodes.map(\.frame) + policyCanvasGroupTitleFrames(prepared.groups)
      )
    }
    return policyCanvasResolvedLabelPositions(
      routes: labelledRoutes,
      nodeFrames: prepared.nodes.map(\.frame) + policyCanvasGroupTitleFrames(prepared.groups),
      routeFrames: routeFrames
    )
  }
}

struct PolicyCanvasPolylineMidpointLabelPlacement: PolicyCanvasEdgeLabelPlacementAlgorithm {
  func placeLabels(input: PolicyCanvasLabelPlacementInput) -> [String: CGPoint] {
    input.prepared.edges.reduce(into: [:]) { positions, edge in
      guard !edge.label.isEmpty, let route = input.routes[edge.id] else {
        return
      }
      positions[edge.id] = route.arcLengthMidpoint
    }
  }
}
