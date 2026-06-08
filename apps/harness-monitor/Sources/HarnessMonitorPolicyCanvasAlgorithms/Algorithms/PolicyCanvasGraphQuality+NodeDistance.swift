import CoreGraphics

/// Flag pairs of connected nodes that sit too far apart horizontally. This is a
/// layout signal, measured from node frames and the edge connectivity rather
/// than the routes: two nodes wired together across a wide empty horizontal gap
/// force a long hauling edge and waste canvas, independent of how the wire is
/// routed. Vertically stacked pairs (frames overlapping in x) are ignored - the
/// gap measured is strictly the horizontal whitespace between the facing
/// vertical edges. One violation per connected node pair, deduplicated, sorted
/// widest first.
func policyCanvasMeasureNodeDistance(
  edges: [PolicyCanvasEdge],
  nodeFramesByID: [String: CGRect],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasNodeDistanceViolation] {
  var seen: Set<String> = []
  var violations: [PolicyCanvasNodeDistanceViolation] = []
  for edge in edges.sorted(by: { $0.id < $1.id }) {
    let sourceID = edge.source.nodeID
    let targetID = edge.target.nodeID
    guard
      sourceID != targetID,
      let sourceFrame = nodeFramesByID[sourceID],
      let targetFrame = nodeFramesByID[targetID]
    else {
      continue
    }
    let key = [sourceID, targetID].sorted().joined(separator: "\u{1}")
    guard !seen.contains(key) else {
      continue
    }
    seen.insert(key)
    let gap: CGFloat
    let gapStart: CGPoint
    let gapEnd: CGPoint
    let midY = (sourceFrame.midY + targetFrame.midY) / 2
    if targetFrame.minX >= sourceFrame.maxX {
      gap = targetFrame.minX - sourceFrame.maxX
      gapStart = CGPoint(x: sourceFrame.maxX, y: midY)
      gapEnd = CGPoint(x: targetFrame.minX, y: midY)
    } else if sourceFrame.minX >= targetFrame.maxX {
      gap = sourceFrame.minX - targetFrame.maxX
      gapStart = CGPoint(x: targetFrame.maxX, y: midY)
      gapEnd = CGPoint(x: sourceFrame.minX, y: midY)
    } else {
      continue
    }
    guard gap >= thresholds.nodeDistanceGap else {
      continue
    }
    violations.append(
      PolicyCanvasNodeDistanceViolation(
        edgeID: edge.id,
        sourceID: sourceID,
        targetID: targetID,
        distance: gap,
        gapStart: gapStart,
        gapEnd: gapEnd
      )
    )
  }
  return violations.sorted { lhs, rhs in
    abs(lhs.distance - rhs.distance) > 0.001 ? lhs.distance > rhs.distance : lhs.edgeID < rhs.edgeID
  }
}
