import SwiftUI

// Crowded fallback for label placement: chosen only when no collision-free spot
// exists on an edge. Rank node-body overlap ahead of route/label overlap - a
// label crossing a thin route line still reads fine, but a label sitting on a
// node covers unrelated content and is the worst outcome. So minimize node
// overlap first and only break ties by how much the label grazes other routes
// and labels. This slides a crowded label off a node onto its own run even when
// that run also carries a passing edge.
func policyCanvasLeastBadLabelCandidate(
  _ candidates: [CGPoint],
  size: CGSize,
  nodeFrames: [CGRect],
  lineBlockers: [CGRect],
  fallback: CGPoint
) -> CGPoint {
  func penalty(_ center: CGPoint) -> (node: CGFloat, line: CGFloat) {
    let frame = policyCanvasLabelFrame(center: center, size: size)
    return (
      node: policyCanvasLabelOverlapArea(frame, against: nodeFrames),
      line: policyCanvasLabelOverlapArea(frame, against: lineBlockers)
    )
  }
  return candidates.min { left, right in
    let leftPenalty = penalty(left)
    let rightPenalty = penalty(right)
    if abs(leftPenalty.node - rightPenalty.node) > 0.001 {
      return leftPenalty.node < rightPenalty.node
    }
    return leftPenalty.line < rightPenalty.line
  } ?? fallback
}

func policyCanvasLabelOverlapArea(
  _ frame: CGRect,
  against blockers: [CGRect]
) -> CGFloat {
  blockers.reduce(0) { total, blocker in
    let intersection = frame.intersection(blocker)
    guard !intersection.isNull else {
      return total
    }
    return total + (intersection.width * intersection.height)
  }
}
