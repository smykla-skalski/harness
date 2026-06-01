import CoreGraphics
import Foundation

func policyCanvasEdgeAwareSeedY(
  for nodeID: String,
  nodesByID: [String: PolicyCanvasLayoutNode],
  edges: [PolicyCanvasLayoutEdge]
) -> CGFloat? {
  var neighborYs: [CGFloat] = []
  neighborYs.reserveCapacity(edges.count)
  for edge in edges {
    if edge.sourceNodeID == nodeID, let target = nodesByID[edge.targetNodeID] {
      neighborYs.append(target.currentPosition.y)
    } else if edge.targetNodeID == nodeID, let source = nodesByID[edge.sourceNodeID] {
      neighborYs.append(source.currentPosition.y)
    }
  }
  guard !neighborYs.isEmpty else {
    return nil
  }
  neighborYs.sort()
  let count = neighborYs.count
  if count.isMultiple(of: 2) {
    return (neighborYs[(count / 2) - 1] + neighborYs[count / 2]) / 2
  }
  return neighborYs[count / 2]
}
