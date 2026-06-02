import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas

/// The hand-coded fallback router is what `PolicyCanvasVisibilityRouter` falls
/// back to when A* cannot index the grid. These tests pin the obstacle-avoidance
/// behavior that must hold regardless of edge direction.
@Suite("Policy canvas hand-coded fallback")
struct PolicyCanvasHandCodedFallbackTests {
  @Test("right-to-left edge with an obstacle group between detours")
  func rightToLeftDetoursAroundObstacle() {
    let obstacle = PolicyCanvasGroup(
      id: "obs",
      title: "Obs",
      frame: CGRect(x: 150, y: 60, width: 200, height: 100),
      tone: .intake
    )
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 500, y: 100),
      target: CGPoint(x: 50, y: 100),
      lane: 0,
      groups: [obstacle],
      sourceGroupID: nil,
      targetGroupID: nil
    )
    let allOnSourceY = route.points.allSatisfy { abs($0.y - 100) < 0.001 }
    #expect(
      !allOnSourceY,
      "Right-to-left route must detour off y=100 to avoid the obstacle band"
    )
  }

  @Test("left-to-right edge with obstacle still detours (regression guard)")
  func leftToRightStillDetoursAroundObstacle() {
    let obstacle = PolicyCanvasGroup(
      id: "obs",
      title: "Obs",
      frame: CGRect(x: 150, y: 60, width: 200, height: 100),
      tone: .intake
    )
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 50, y: 100),
      target: CGPoint(x: 500, y: 100),
      lane: 0,
      groups: [obstacle],
      sourceGroupID: nil,
      targetGroupID: nil
    )
    let allOnSourceY = route.points.allSatisfy { abs($0.y - 100) < 0.001 }
    #expect(!allOnSourceY)
  }
}
