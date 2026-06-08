import CoreGraphics

struct PolicyCanvasObstacleAwareGreedyLabelPlacement: PolicyCanvasEdgeLabelPlacementAlgorithm {
  private let greedyRouteFrameComplexityLimit = 8_000
  private let directMidpointRouteCount = 1_000
  private let directMidpointFrameComplexityLimit = 2_000_000

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
    if labelledRoutes.count >= directMidpointRouteCount
      || labelledRoutes.count * max(1, routeFrameCount) > directMidpointFrameComplexityLimit
    {
      return policyCanvasDirectMidpointLabelPositions(routes: labelledRoutes)
    }
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

func policyCanvasDirectMidpointLabelPositions(
  routes: [PolicyCanvasLabelPlacementRoute]
) -> [String: CGPoint] {
  var positions: [String: CGPoint] = [:]
  positions.reserveCapacity(routes.count)
  var bucketOccupancy: [PolicyCanvasDirectLabelBucket: Int] = [:]
  for entry in policyCanvasSortedLabelRoutes(routes) {
    let base = entry.route.arcLengthMidpoint
    let bucket = PolicyCanvasDirectLabelBucket(point: base)
    let ordinal = bucketOccupancy[bucket, default: 0]
    bucketOccupancy[bucket] = ordinal + 1
    let offset = policyCanvasDirectLabelOffset(
      route: entry.route,
      ordinal: ordinal
    )
    positions[entry.id] = CGPoint(x: base.x + offset.x, y: base.y + offset.y)
  }
  return positions
}

private func policyCanvasDirectLabelOffset(
  route: PolicyCanvasEdgeRoute,
  ordinal: Int
) -> CGPoint {
  guard ordinal > 0 else {
    return .zero
  }
  let lane = CGFloat((ordinal + 1) / 2)
  let sign: CGFloat = ordinal.isMultiple(of: 2) ? -1 : 1
  let distance = lane * PolicyCanvasLayout.gridSize
  switch policyCanvasDominantLabelAxis(route) {
  case .horizontal:
    return CGPoint(x: 0, y: sign * distance)
  case .vertical:
    return CGPoint(x: sign * distance, y: 0)
  }
}

private func policyCanvasDominantLabelAxis(
  _ route: PolicyCanvasEdgeRoute
) -> PolicyCanvasSegmentAxis {
  var horizontal: CGFloat = 0
  var vertical: CGFloat = 0
  for (start, end) in zip(route.points, route.points.dropFirst()) {
    let dx = abs(start.x - end.x)
    let dy = abs(start.y - end.y)
    if dx >= dy {
      horizontal += dx
    } else {
      vertical += dy
    }
  }
  return horizontal >= vertical ? .horizontal : .vertical
}

private struct PolicyCanvasDirectLabelBucket: Hashable {
  let x: Int
  let y: Int

  init(point: CGPoint) {
    let quantum = max(PolicyCanvasLayout.gridSize, 1)
    x = Int((point.x / quantum).rounded())
    y = Int((point.y / quantum).rounded())
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
