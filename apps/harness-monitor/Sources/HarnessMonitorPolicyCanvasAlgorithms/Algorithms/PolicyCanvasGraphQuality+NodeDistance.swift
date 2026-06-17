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
    let leftFrame: CGRect
    let rightFrame: CGRect
    let midY = (sourceFrame.midY + targetFrame.midY) / 2
    if targetFrame.minX >= sourceFrame.maxX {
      gap = targetFrame.minX - sourceFrame.maxX
      gapStart = CGPoint(x: sourceFrame.maxX, y: midY)
      gapEnd = CGPoint(x: targetFrame.minX, y: midY)
      leftFrame = sourceFrame
      rightFrame = targetFrame
    } else if sourceFrame.minX >= targetFrame.maxX {
      gap = sourceFrame.minX - targetFrame.maxX
      gapStart = CGPoint(x: targetFrame.maxX, y: midY)
      gapEnd = CGPoint(x: sourceFrame.minX, y: midY)
      leftFrame = targetFrame
      rightFrame = sourceFrame
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
        gapEnd: gapEnd,
        gapStartCap: CGPoint(x: gapStart.x, y: policyCanvasNodeDistanceCapY(midY: midY, frame: leftFrame)),
        gapEndCap: CGPoint(x: gapEnd.x, y: policyCanvasNodeDistanceCapY(midY: midY, frame: rightFrame))
      )
    )
  }
  return violations.sorted { lhs, rhs in
    abs(lhs.distance - rhs.distance) > 0.001 ? lhs.distance > rhs.distance : lhs.edgeID < rhs.edgeID
  }
}

/// The y the end cap stretches to so it touches its node. The measurement line
/// sits at `midY`; a node entirely below the line (its top edge past `midY`) is
/// met by extending down to that top edge, a node entirely above by extending up
/// to its bottom edge. A node straddling the line already meets it, so the cap
/// stays at `midY` (zero length).
private func policyCanvasNodeDistanceCapY(midY: CGFloat, frame: CGRect) -> CGFloat {
  if midY < frame.minY {
    return frame.minY
  }
  if midY > frame.maxY {
    return frame.maxY
  }
  return midY
}
