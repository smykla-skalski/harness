import SwiftUI

/// A top-side output departure can only land on its single visible top marker
/// dot, which the port-dot grid places at the source node's horizontal center.
/// The router escapes straight up from that center column before it can turn, so
/// when an obstacle covers the center column within the turn lead - a node
/// overhanging the top edge, or the source's own group title sitting just above
/// its row - the top port is unusable and no lateral shift can recover it (every
/// off-center column lands on no dot). Used to drop a fan-in feeder whose top
/// center is blocked onto its bottom port instead of diving through the obstacle.
public func policyCanvasTopDepartureCenterColumnBlocked(
  sourceFrame: CGRect?,
  obstacles: [CGRect]
) -> Bool {
  guard let sourceFrame else {
    return false
  }
  let centerX = sourceFrame.midX
  let topY = sourceFrame.minY
  let lead = PolicyCanvasLayout.edgePortTurnMinimumLead
  return obstacles.contains { obstacle in
    obstacle.minX <= centerX + 0.5
      && obstacle.maxX >= centerX - 0.5
      && obstacle.minY < topY - 0.5
      && obstacle.maxY > topY - lead
  }
}
