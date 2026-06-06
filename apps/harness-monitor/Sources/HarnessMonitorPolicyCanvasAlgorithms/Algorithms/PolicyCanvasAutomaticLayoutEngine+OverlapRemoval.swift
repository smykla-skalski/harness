import CoreGraphics
import Foundation

// Resolve node collisions left behind by post-placement terminal arrangement.
// The group packer keeps initial members apart, but the terminal comb can later
// lift collectors and drop branch terminals by topology. That can collide with
// either a foreign group or a member in the same group.
//
// This pass clears those collisions with a top-to-bottom vertical push-down
// sweep. Nodes are visited in order of their current top edge; each node is
// pushed straight down just far enough to clear every already-placed node whose
// horizontal span it shares. Pushing the lower node of a pair keeps the order of
// the column intact, and the move is vertical-only so no node changes rank
// column.
func policyCanvasResolveNodeOverlaps(
  nodePositions: [String: CGPoint]
) -> [String: CGPoint] {
  policyCanvasResolveNodeOverlaps(
    nodePositions: nodePositions,
    shouldResolvePair: { _, _ in true }
  )
}

// Resolve cross-group node collisions the group-agnostic terminal comb leaves
// behind. Same-group placement remains the engine's own job on the base layout
// path; final view-model alignment runs the all-pairs cleanup only for grouped
// documents after it has made the last terminal movement.
func policyCanvasResolveCrossGroupNodeOverlaps(
  nodePositions: [String: CGPoint],
  layoutGroupIDByNodeID: [String: String]
) -> [String: CGPoint] {
  policyCanvasResolveNodeOverlaps(
    nodePositions: nodePositions,
    shouldResolvePair: { leftID, rightID in
      layoutGroupIDByNodeID[leftID] != layoutGroupIDByNodeID[rightID]
    }
  )
}

private func policyCanvasResolveNodeOverlaps(
  nodePositions: [String: CGPoint],
  shouldResolvePair: (String, String) -> Bool
) -> [String: CGPoint] {
  var positions = nodePositions
  let orderedIDs = nodePositions.keys.sorted { leftID, rightID in
    let left = nodePositions[leftID] ?? .zero
    let right = nodePositions[rightID] ?? .zero
    if left.y != right.y { return left.y < right.y }
    if left.x != right.x { return left.x < right.x }
    return leftID < rightID
  }

  var placed: [(id: String, frame: CGRect)] = []
  for nodeID in orderedIDs {
    guard let origin = positions[nodeID] else { continue }
    let frame = CGRect(origin: origin, size: PolicyCanvasLayout.nodeSize)
    var requiredMinY = frame.minY
    for entry in placed {
      guard shouldResolvePair(nodeID, entry.id) else { continue }
      guard policyCanvasHorizontalSpansOverlap(frame, entry.frame) else { continue }
      requiredMinY = max(requiredMinY, entry.frame.maxY)
    }
    let resolvedFrame: CGRect
    if requiredMinY > frame.minY {
      positions[nodeID] = CGPoint(x: origin.x, y: requiredMinY)
      resolvedFrame = CGRect(
        origin: CGPoint(x: origin.x, y: requiredMinY),
        size: PolicyCanvasLayout.nodeSize
      )
    } else {
      resolvedFrame = frame
    }
    placed.append((id: nodeID, frame: resolvedFrame))
  }
  return positions
}

private func policyCanvasHorizontalSpansOverlap(_ left: CGRect, _ right: CGRect) -> Bool {
  left.minX < right.maxX && right.minX < left.maxX
}
