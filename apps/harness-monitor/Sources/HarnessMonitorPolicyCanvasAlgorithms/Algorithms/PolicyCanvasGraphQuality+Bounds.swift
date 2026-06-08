import CoreGraphics

/// Measure overall canvas extent, how densely nodes fill it, and node-body
/// overlaps. The content bounds union node frames with every route point so the
/// extent reflects edges that wander past the node cloud, which is what makes
/// the occupancy ratio a useful empty-space signal.
func policyCanvasMeasureBounds(
  nodeFramesByID: [String: CGRect],
  routes: [String: PolicyCanvasEdgeRoute]
) -> (summary: PolicyCanvasBoundsSummary, overlaps: [PolicyCanvasNodeOverlapViolation]) {
  var union: CGRect?
  for frame in nodeFramesByID.values {
    union = union.map { $0.union(frame) } ?? frame
  }
  for route in routes.values {
    for point in route.points {
      let pointRect = CGRect(x: point.x, y: point.y, width: 0, height: 0)
      union = union.map { $0.union(pointRect) } ?? pointRect
    }
  }
  let bounds = union ?? .zero
  let nodeArea = nodeFramesByID.values.reduce(CGFloat(0)) { partial, frame in
    partial + (frame.width * frame.height)
  }
  let boundsArea = bounds.width * bounds.height
  let summary = PolicyCanvasBoundsSummary(
    contentBounds: bounds,
    nodeOccupancyRatio: boundsArea > 0 ? nodeArea / boundsArea : 0,
    aspectRatio: bounds.height > 0 ? bounds.width / bounds.height : 0
  )
  let sortedNodes = nodeFramesByID.sorted { $0.key < $1.key }
  var overlaps: [PolicyCanvasNodeOverlapViolation] = []
  for leftIndex in sortedNodes.indices {
    for rightIndex in sortedNodes.index(after: leftIndex)..<sortedNodes.endIndex {
      let lhs = sortedNodes[leftIndex]
      let rhs = sortedNodes[rightIndex]
      let intersection = lhs.value.intersection(rhs.value)
      guard !intersection.isNull, intersection.width > 0.5, intersection.height > 0.5 else {
        continue
      }
      overlaps.append(
        PolicyCanvasNodeOverlapViolation(
          nodeA: lhs.key,
          nodeB: rhs.key,
          intersection: intersection
        )
      )
    }
  }
  return (summary, overlaps)
}
