import CoreGraphics
import Foundation

// Resolve cross-group node collisions the group-agnostic terminal comb leaves
// behind. The comb arranges a non-coherent group's terminals by their own
// topology (a shared collector lifts above its sources, a branch terminal drops
// below its source). When that group's members are scattered across the DAG,
// a lifted or dropped terminal can land directly on top of a foreign group's
// node - the two boxes overlap and the canvas reads as broken.
//
// This pass clears those collisions with a top-to-bottom vertical push-down
// sweep. Nodes are visited in order of their current top edge; each node is
// pushed straight down just far enough to clear every already-placed node from
// a different group whose horizontal span it shares. Pushing the lower node of
// a pair keeps the order of the column intact, so the layered crossing count is
// untouched (the same property that lets the parallel-band seam hold), and the
// move is vertical-only so no node ever changes its rank column. Same-group
// placement is the engine's own job and is left alone.
func policyCanvasResolveCrossGroupNodeOverlaps(
  nodePositions: [String: CGPoint],
  layoutGroupIDByNodeID: [String: String]
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
    let group = layoutGroupIDByNodeID[nodeID]
    var requiredMinY = frame.minY
    for entry in placed {
      guard layoutGroupIDByNodeID[entry.id] != group else { continue }
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
