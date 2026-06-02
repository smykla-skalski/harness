import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Regression gates for four routing/layout defects surfaced in the algorithm
/// review (`.bart/algorithm_review/policy_canvas_bugs.md`):
///   1. post-snap collision falsely rejecting a valid A* route (node
///      dimensions are not channel-grid multiples, so a far padded edge snaps
///      inward and trips the re-validation),
///   2. the endpoint obstacle drop blinding A* to a neighbouring node that
///      merely lies within an anchor's routing pad,
///   3. the fallback detour bounding itself by the whole-canvas obstacle box
///      instead of the local span,
///   4. the corridor-share check comparing a layout-hint lane ordinal against
///      a realized-route Y bucket, so fan-in siblings stop bundling at large
///      canvas coordinates.
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

  // MARK: Fix 4 - corridor key domain mismatch

  @Test("Hint comparison key buckets the lane Y into the realized-route domain")
  func corridorComparisonKeyMatchesRealizedBucket() {
    let busY: CGFloat = 432
    let hint = fanInHint(busY: busY, ordinal: 2)
    let comparison = policyCanvasCorridorComparisonKey(hint: hint, lineSpacing: lineSpacing)
    let laneStep = max(lineSpacing, PolicyCanvasLayout.gridSize)
    #expect(comparison?.laneIndex == Int((busY / laneStep).rounded()))
    #expect(comparison?.laneIndex != hint.key.laneIndex)
  }

  @Test("Fan-in siblings on the same bus share a corridor at large canvas Y")
  func fanInSiblingsShareCorridorAtLargeY() {
    let busY: CGFloat = 432
    let hint = fanInHint(busY: busY, ordinal: 2)
    let currentEdge = edge(id: "e2", sourceNodeID: "s2", targetNodeID: "t", label: "ok")
    let previousEdge = edge(id: "e1", sourceNodeID: "s1", targetNodeID: "t", label: "ok")
    // The key a previously-routed sibling stores: bucketed from its realized
    // bus Y by `policyCanvasCorridorKey(forRoute:)`.
    let realizedKey = PolicyCanvasPreparedRouteInput.policyCanvasCorridorKey(
      forRoute: PolicyCanvasEdgeRoute(
        points: [
          CGPoint(x: 0, y: busY),
          CGPoint(x: 240, y: busY),
          CGPoint(x: 240, y: busY + 60),
        ],
        labelPosition: .zero),
      hint: hint,
      lineSpacing: lineSpacing
    )
    // The defect: comparing the current edge's hint lane ordinal against the
    // realized Y bucket - never equal at realistic Y, so the siblings were
    // pushed apart instead of bundled.
    #expect(
      !policyCanvasRoutesMayShareInteriorCorridor(
        edge: currentEdge, corridorKey: hint.key,
        with: previousEdge, otherCorridorKey: realizedKey))
    // The fix: callers compare the domain-unified key, so the siblings bundle.
    let comparisonKey = policyCanvasCorridorComparisonKey(hint: hint, lineSpacing: lineSpacing)
    #expect(
      policyCanvasRoutesMayShareInteriorCorridor(
        edge: currentEdge, corridorKey: comparisonKey,
        with: previousEdge, otherCorridorKey: realizedKey))
  }

  // MARK: Helpers

  private func fanInHint(busY: CGFloat, ordinal: Int) -> PolicyCanvasEdgeCorridorHint {
    PolicyCanvasEdgeCorridorHint(
      key: PolicyCanvasRouteCorridorKey(
        sourceScopeID: "src",
        targetScopeID: "dst",
        targetNodeID: "t",
        label: "ok",
        laneIndex: ordinal),
      horizontalLaneY: busY,
      verticalLaneX: nil)
  }

  private func edge(
    id: String, sourceNodeID: String, targetNodeID: String, label: String
  ) -> PolicyCanvasEdge {
    PolicyCanvasEdge(
      id: id,
      source: PolicyCanvasPortEndpoint(nodeID: sourceNodeID, portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: targetNodeID, portID: "in", kind: .input),
      label: label)
  }

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
