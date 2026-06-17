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
    let leftX: CGFloat
    let rightX: CGFloat
    let leftFrame: CGRect
    let rightFrame: CGRect
    let midY = (sourceFrame.midY + targetFrame.midY) / 2
    if targetFrame.minX >= sourceFrame.maxX {
      gap = targetFrame.minX - sourceFrame.maxX
      leftX = sourceFrame.maxX
      rightX = targetFrame.minX
      leftFrame = sourceFrame
      rightFrame = targetFrame
    } else if sourceFrame.minX >= targetFrame.maxX {
      gap = sourceFrame.minX - targetFrame.maxX
      leftX = targetFrame.maxX
      rightX = sourceFrame.minX
      leftFrame = targetFrame
      rightFrame = sourceFrame
    } else {
      continue
    }
    guard gap >= thresholds.nodeDistanceGap else {
      continue
    }
    // The averaged mid-y can land on an unrelated node that happens to sit in the
    // gap corridor, making the bar look glued to that node. Lift the bar above any
    // such intruder so it reads as measuring the gap, not hugging a neighbour.
    let barY = policyCanvasNodeDistanceBarY(
      midY: midY,
      corridorLeft: leftX,
      corridorRight: rightX,
      excluding: [sourceID, targetID],
      nodeFramesByID: nodeFramesByID
    )
    let gapStart = CGPoint(x: leftX, y: barY)
    let gapEnd = CGPoint(x: rightX, y: barY)
    violations.append(
      PolicyCanvasNodeDistanceViolation(
        edgeID: edge.id,
        sourceID: sourceID,
        targetID: targetID,
        distance: gap,
        gapStart: gapStart,
        gapEnd: gapEnd,
        gapStartCap: CGPoint(x: gapStart.x, y: policyCanvasNodeDistanceCapY(midY: barY, frame: leftFrame)),
        gapEndCap: CGPoint(x: gapEnd.x, y: policyCanvasNodeDistanceCapY(midY: barY, frame: rightFrame))
      )
    )
  }
  return violations.sorted { lhs, rhs in
    abs(lhs.distance - rhs.distance) > 0.001 ? lhs.distance > rhs.distance : lhs.edgeID < rhs.edgeID
  }
}

/// The y the measurement bar runs at. Normally the averaged mid-y of the two
/// nodes, but lifted above any non-endpoint node whose body straddles that mid-y
/// inside the gap corridor (its x-range reaches the corridor and its y-span
/// contains the mid-y). Such a node would otherwise sit right under the bar with
/// its facing edge at the bar's end, so the bar reads as attached to it; raising
/// the bar one clearance above the topmost intruder pulls it into clear space.
private func policyCanvasNodeDistanceBarY(
  midY: CGFloat,
  corridorLeft: CGFloat,
  corridorRight: CGFloat,
  excluding endpoints: Set<String>,
  nodeFramesByID: [String: CGRect]
) -> CGFloat {
  var obstacleTop: CGFloat?
  for (id, frame) in nodeFramesByID where !endpoints.contains(id) {
    guard
      frame.maxX >= corridorLeft, frame.minX <= corridorRight,
      frame.minY <= midY, midY <= frame.maxY
    else {
      continue
    }
    obstacleTop = min(obstacleTop ?? frame.minY, frame.minY)
  }
  guard let obstacleTop else {
    return midY
  }
  return obstacleTop - PolicyCanvasLayout.nodeDistanceObstacleClearance
}

/// The y the end cap stretches to so it touches its node. The measurement line
/// sits at `midY`; a node entirely below the line (its top edge past `midY`) is
/// met by extending down to that top edge, a node entirely above by extending up
/// to its bottom edge. The cap sits at the node's corner x, where the rounded
/// corner shaves the body inward, so it overshoots the straight edge by one
/// corner radius to actually reach the rounded body. A node straddling the line
/// already meets it, so the cap stays at `midY` (zero length).
private func policyCanvasNodeDistanceCapY(midY: CGFloat, frame: CGRect) -> CGFloat {
  let overshoot = PolicyCanvasLayout.nodeCornerRadius
  if midY < frame.minY {
    return frame.minY + overshoot
  }
  if midY > frame.maxY {
    return frame.maxY - overshoot
  }
  return midY
}
