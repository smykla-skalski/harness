import CoreGraphics
import Foundation

let policyCanvasMinimumNodeSpacing: CGFloat = PolicyCanvasLayout.defaultEdgeLineSpacing
private let policyCanvasNodeSpacingTolerance: CGFloat = 0.001

// Resolve node collisions left behind by post-placement terminal arrangement.
// The group packer keeps initial members apart, but the terminal comb can later
// lift collectors and drop branch terminals by topology. That can collide with
// either a foreign group or a member in the same group.
//
// This pass clears those collisions with a top-to-bottom vertical push-down
// sweep. Nodes are visited in order of their current top edge; each node is
// pushed straight down just far enough to clear every already-placed node whose
// horizontal span it shares, including the visual edge-line gutter between their
// bodies. Pushing the lower node of a pair keeps the order of the column intact,
// and the move is vertical-only so no node changes rank column.
func policyCanvasResolveNodeOverlaps(
  nodePositions: [String: CGPoint],
  nodeSizes: [String: CGSize] = [:]
) -> [String: CGPoint] {
  policyCanvasResolveNodeOverlaps(
    nodePositions: nodePositions,
    nodeSizes: nodeSizes,
    minimumSpacing: policyCanvasMinimumNodeSpacing,
    shouldResolvePair: { _, _ in true }
  )
}

// Resolve cross-group node collisions the group-agnostic terminal comb leaves
// behind. Same-group placement remains the engine's own job on the base layout
// path; final view-model alignment runs the all-pairs cleanup only for grouped
// documents after it has made the last terminal movement.
func policyCanvasResolveCrossGroupNodeOverlaps(
  nodePositions: [String: CGPoint],
  layoutGroupIDByNodeID: [String: String],
  nodeSizes: [String: CGSize] = [:]
) -> [String: CGPoint] {
  policyCanvasResolveNodeOverlaps(
    nodePositions: nodePositions,
    nodeSizes: nodeSizes,
    minimumSpacing: 0,
    shouldResolvePair: { leftID, rightID in
      layoutGroupIDByNodeID[leftID] != layoutGroupIDByNodeID[rightID]
    }
  )
}

func policyCanvasResolveNodeAndForeignTitleOverlaps(
  nodePositions: [String: CGPoint],
  layoutGroupIDByNodeID: [String: String],
  groupTitleFramesByID: [String: CGRect],
  nodeSizes: [String: CGSize] = [:]
) -> [String: CGPoint] {
  policyCanvasResolveNodeOverlaps(
    nodePositions: nodePositions,
    nodeSizes: nodeSizes,
    minimumSpacing: policyCanvasMinimumNodeSpacing,
    shouldResolvePair: { _, _ in true },
    blockingFrames: { nodeID in
      let nodeGroupID = layoutGroupIDByNodeID[nodeID]
      return groupTitleFramesByID.compactMap { groupID, frame in
        groupID == nodeGroupID ? nil : frame
      }
    }
  )
}

private func policyCanvasResolveNodeOverlaps(
  nodePositions: [String: CGPoint],
  nodeSizes: [String: CGSize],
  minimumSpacing: CGFloat,
  shouldResolvePair: (String, String) -> Bool,
  blockingFrames: (String) -> [CGRect] = { _ in [] }
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
    let nodeSize = nodeSizes[nodeID] ?? PolicyCanvasLayout.nodeSize
    let frame = CGRect(origin: origin, size: nodeSize)
    var requiredMinY = frame.minY
    for entry in placed {
      guard shouldResolvePair(nodeID, entry.id) else { continue }
      guard policyCanvasHorizontalSpansOverlap(frame, entry.frame, spacing: minimumSpacing) else {
        continue
      }
      requiredMinY = max(requiredMinY, entry.frame.maxY + minimumSpacing)
    }
    var candidateFrame = CGRect(
      origin: CGPoint(x: frame.minX, y: requiredMinY),
      size: frame.size
    )
    for obstacle in blockingFrames(nodeID) {
      guard
        policyCanvasFramesNeedVerticalSeparation(
          candidateFrame,
          obstacle,
          spacing: minimumSpacing
        )
      else {
        continue
      }
      requiredMinY = max(requiredMinY, obstacle.maxY + minimumSpacing)
      candidateFrame = CGRect(
        origin: CGPoint(x: frame.minX, y: requiredMinY),
        size: frame.size
      )
    }
    let resolvedFrame: CGRect
    if requiredMinY > frame.minY {
      positions[nodeID] = CGPoint(x: origin.x, y: requiredMinY)
      resolvedFrame = CGRect(
        origin: CGPoint(x: origin.x, y: requiredMinY),
        size: frame.size
      )
    } else {
      resolvedFrame = frame
    }
    placed.append((id: nodeID, frame: resolvedFrame))
  }
  return positions
}

func policyCanvasNodeFramesViolateMinimumSpacing(
  _ left: CGRect,
  _ right: CGRect,
  minimumSpacing: CGFloat = policyCanvasMinimumNodeSpacing
) -> Bool {
  let horizontalGap = max(left.minX - right.maxX, right.minX - left.maxX, 0)
  let verticalGap = max(left.minY - right.maxY, right.minY - left.maxY, 0)
  if horizontalGap == 0 {
    return verticalGap + policyCanvasNodeSpacingTolerance < minimumSpacing
  }
  if verticalGap == 0 {
    return horizontalGap + policyCanvasNodeSpacingTolerance < minimumSpacing
  }
  return hypot(horizontalGap, verticalGap) + policyCanvasNodeSpacingTolerance < minimumSpacing
}

private func policyCanvasHorizontalSpansOverlap(
  _ left: CGRect,
  _ right: CGRect,
  spacing: CGFloat
) -> Bool {
  left.minX < right.maxX + spacing && right.minX < left.maxX + spacing
}

private func policyCanvasFramesNeedVerticalSeparation(
  _ nodeFrame: CGRect,
  _ obstacleFrame: CGRect,
  spacing: CGFloat
) -> Bool {
  policyCanvasHorizontalSpansOverlap(nodeFrame, obstacleFrame, spacing: spacing)
    && nodeFrame.minY < obstacleFrame.maxY + spacing
    && obstacleFrame.minY < nodeFrame.maxY + spacing
}
