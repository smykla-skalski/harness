import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Regression gates for routing defects surfaced in the algorithm review
/// (`.bart/algorithm_review/policy_canvas_bugs.md`):
///   1. post-snap collision falsely rejecting a valid A* route (node
///      dimensions are not channel-grid multiples, so a far padded edge snaps
///      inward and trips the re-validation),
///   2. the endpoint obstacle drop blinding A* to a neighbouring node that
///      merely lies within an anchor's routing pad,
///   3. the fallback detour bounding itself by the whole-canvas obstacle box
///      instead of the local span.
@Suite("Policy canvas routing fixes")
struct PolicyCanvasRoutingFixesTests {
  private let lineSpacing = PolicyCanvasLayout.defaultEdgeLineSpacing

  private func context(obstacles: [CGRect] = []) -> PolicyCanvasRouteContext {
    PolicyCanvasRouteContext(
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil,
      obstacles: obstacles,
      lineSpacing: lineSpacing
    )
  }

  // MARK: Fix 1 - post-snap collision false rejection

  @Test("A route grazing a non-grid-aligned far padded edge is kept, not bounced to the fallback")
  func postSnapGrazeKeepsLocalRoute() {
    // Node height 96 is not a channelStep (5) multiple, so the bottom padded
    // edge lands at minY+111 and snaps inward to minY+110. Pre-fix the
    // re-validation rejected that 1pt intrusion and dropped to the fallback
    // detour, which sweeps well past the obstacle (maxY ~= 150). The A* route
    // hugs the clearance band (maxY ~= 110).
    let obstacle = CGRect(x: 150, y: 0, width: 100, height: 96)
    let outcome = PolicyCanvasVisibilityRouter().routeAndCost(
      source: CGPoint(x: 0, y: 96),
      target: CGPoint(x: 400, y: 96),
      context: context(obstacles: [obstacle])
    )
    let maxY = outcome.route.points.map(\.y).max() ?? 0
    #expect(maxY <= obstacle.maxY + PolicyCanvasVisibilityRouter.obstaclePadding)
    #expect(!routeEntersRect(outcome.route.points, rect: obstacle))
  }

  // MARK: Fix 2 - endpoint obstacle drop overreach

  @Test("A non-endpoint node within an anchor's pad stays an obstacle")
  func neighborWithinPadIsNotDropped() {
    let router = PolicyCanvasVisibilityRouter()
    let sourcePort = CGPoint(x: 100, y: 100)
    let targetPort = CGPoint(x: 600, y: 100)
    // A different node sits 9pt past the source port - inside the 15pt pad,
    // but it is not an endpoint, so it must survive as a padded obstacle.
    let neighbor = CGRect(x: 109, y: 80, width: 40, height: 40)
    let prepared = router.preparedObstacles(
      source: sourcePort,
      target: targetPort,
      sourceActual: sourcePort,
      targetActual: targetPort,
      raw: [neighbor]
    )
    #expect(prepared.count == 1)
  }

  // MARK: Fix 3 - global fallback detour

  @Test("The fallback detour bounds itself by local obstacles, not the whole canvas")
  func fallbackDetourStaysLocal() {
    let router = PolicyCanvasVisibilityRouter()
    // A blocker between the endpoints, a wide ceiling forcing the detour
    // downward, and a far obstacle 5000pt below. The detour must hug the
    // local blocker, never sweep down toward the far obstacle (pre-fix
    // maxY ~= 5080, post-fix maxY ~= 180).
    let blocker = CGRect(x: 140, y: 60, width: 20, height: 80)
    let ceiling = CGRect(x: -100, y: 20, width: 500, height: 20)
    let farBelow = CGRect(x: 140, y: 5_000, width: 20, height: 40)
    let points = router.fallbackDetourPoints(
      source: CGPoint(x: 0, y: 100),
      target: CGPoint(x: 300, y: 100),
      obstacles: [blocker, ceiling, farBelow],
      lineSpacing: lineSpacing
    )
    let maxY = points?.map(\.y).max() ?? 0
    #expect(maxY < 1_000)
  }

  // MARK: Helpers

  private func routeEntersRect(_ points: [CGPoint], rect: CGRect) -> Bool {
    guard points.count >= 2 else {
      return false
    }
    for index in 0..<(points.count - 1) {
      let start = points[index]
      let end = points[index + 1]
      if min(start.x, end.x) < rect.maxX && max(start.x, end.x) > rect.minX
        && min(start.y, end.y) < rect.maxY && max(start.y, end.y) > rect.minY
      {
        return true
      }
    }
    return false
  }
}
