import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas displayed route bridge")
struct PolicyCanvasDisplayedRouteBridgeTests {
  // Lane-spread behaviour is owned by `PolicyCanvasLaneSpreadTests`, which
  // asserts the current contract: a non-zero lane shifts the dominant interior
  // bus perpendicular by its signed lane offset (that separation is the whole
  // point of the spread). Two earlier tests here asserted the opposite
  // pre-redesign contract ("interior bus-track points never move") and were
  // removed rather than kept as contradictory coverage.

  @Test("Displayed routes keep a minimum straight run before the first turn")
  func displayedRoutesKeepMinimumStraightRunBeforeFirstTurn() {
    let route = policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: StubRouteRouter(),
        source: (point: CGPoint(x: 100, y: 100), side: .trailing),
        sourceFanoutLane: 0,
        target: (point: CGPoint(x: 400, y: 240), side: .leading),
        targetFanoutLane: 0,
        context: context()
      )
    )

    #expect(route.points[0] == CGPoint(x: 100, y: 100))
    #expect(
      route.points[1]
        == CGPoint(x: 100 + PolicyCanvasLayout.edgePortTurnMinimumLead, y: 100)
    )
    #expect(route.points[2].x == route.points[1].x)
  }

  @Test("Displayed routes stagger source and target elbows by lane")
  func displayedRoutesStaggerSourceAndTargetElbowsByLane() {
    let lane0 = policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: StubRouteRouter(),
        source: (point: CGPoint(x: 100, y: 100), side: .trailing),
        sourceFanoutLane: 0,
        target: (point: CGPoint(x: 400, y: 240), side: .leading),
        targetFanoutLane: 0,
        context: context(lane: 0)
      )
    )
    let lane1 = policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: StubRouteRouter(),
        source: (point: CGPoint(x: 100, y: 100), side: .trailing),
        sourceFanoutLane: 1,
        target: (point: CGPoint(x: 400, y: 240), side: .leading),
        targetFanoutLane: 1,
        context: context(lane: 1)
      )
    )

    #expect(
      abs((lane1.points[1].x - lane0.points[1].x) - PolicyCanvasLayout.defaultEdgeLineSpacing)
        < 0.001
    )
    #expect(
      abs(
        abs(lane1.points[lane1.points.count - 2].x - lane0.points[lane0.points.count - 2].x)
          - PolicyCanvasLayout.defaultEdgeLineSpacing
      ) < 0.001
    )
    #expect(lane1.points[2] != lane0.points[2])
  }

  @Test("Displayed routes use monotonic trailing-side fanout offsets")
  func displayedRoutesUseMonotonicTrailingSideFanoutOffsets() {
    let lane1 = trailingSideRoute(lane: 1)
    let lane2 = trailingSideRoute(lane: 2)
    let lane3 = trailingSideRoute(lane: 3)

    #expect(lane1.points[2].y < lane2.points[2].y)
    #expect(lane2.points[2].y < lane3.points[2].y)
    #expect(lane1.points[2].x < lane2.points[2].x)
    #expect(lane2.points[2].x < lane3.points[2].x)
  }

  @Test("Bottom-side fanout does not add lateral doglegs")
  func bottomSideFanoutDoesNotAddLateralDoglegs() {
    let route = policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: StubRouteRouter(),
        source: (point: CGPoint(x: 100, y: 100), side: .bottom),
        sourceFanoutLane: 2,
        target: (point: CGPoint(x: 400, y: 240), side: .top),
        targetFanoutLane: 0,
        context: context(lane: 2)
      )
    )

    #expect(route.points[0] == CGPoint(x: 100, y: 100))
    #expect(route.points[1].x == route.points[0].x)
    #expect(route.points[1].y > route.points[0].y)
  }

  @Test("Displayed routes keep final bridge segments out of obstacles")
  func displayedRoutesKeepFinalBridgeSegmentsOutOfObstacles() {
    let obstacle = CGRect(x: 280, y: 50, width: 120, height: 120)
    let route = policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: PolicyCanvasVisibilityRouter(),
        source: (point: CGPoint(x: 100, y: 100), side: .trailing),
        sourceFanoutLane: 0,
        target: (point: CGPoint(x: 600, y: 100), side: .leading),
        targetFanoutLane: 0,
        context: context(obstacles: [obstacle])
      )
    )

    #expect(!polylineEntersObstacle(route.points, obstacle: obstacle))
  }

  @Test("Displayed routes keep higher-lane bridge segments out of obstacles")
  func displayedRoutesKeepHigherLaneBridgeSegmentsOutOfObstacles() {
    let obstacle = CGRect(x: 280, y: 50, width: 120, height: 120)
    let route = policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: PolicyCanvasVisibilityRouter(),
        source: (point: CGPoint(x: 100, y: 100), side: .trailing),
        sourceFanoutLane: 3,
        target: (point: CGPoint(x: 600, y: 100), side: .leading),
        targetFanoutLane: 3,
        context: context(lane: 3, obstacles: [obstacle])
      )
    )

    #expect(!polylineEntersObstacle(route.points, obstacle: obstacle))
  }

  @Test("Channel snap rounds intermediate points to 5pt grid")
  func channelSnapAlignsIntermediates() {
    let obstacle = CGRect(x: 100, y: 50, width: 80, height: 120)
    let route = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 0, y: 100),
      target: CGPoint(x: 400, y: 100),
      context: context(lane: 1, obstacles: [obstacle])
    )
    for index in 1..<(route.points.count - 1) {
      let point = route.points[index]
      #expect(point.x.truncatingRemainder(dividingBy: 5) == 0)
      #expect(point.y.truncatingRemainder(dividingBy: 5) == 0)
    }
  }

  private func trailingSideRoute(lane: Int) -> PolicyCanvasEdgeRoute {
    policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: StubRouteRouter(),
        source: (point: CGPoint(x: 100, y: 100), side: .trailing),
        sourceFanoutLane: lane,
        target: (point: CGPoint(x: 400, y: 240), side: .leading),
        targetFanoutLane: lane,
        context: context(lane: lane)
      )
    )
  }

  private func context(
    lane: Int = 0,
    obstacles: [CGRect] = []
  ) -> PolicyCanvasRouteContext {
    PolicyCanvasRouteContext(
      lane: lane,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil,
      obstacles: obstacles,
      lineSpacing: PolicyCanvasLayout.defaultEdgeLineSpacing
    )
  }

  private func polylineEntersObstacle(_ points: [CGPoint], obstacle: CGRect) -> Bool {
    let padded = obstacle.insetBy(
      dx: -PolicyCanvasVisibilityRouter.obstaclePadding + 0.5,
      dy: -PolicyCanvasVisibilityRouter.obstaclePadding + 0.5
    )
    for index in 0..<points.count - 1 {
      let mid = CGPoint(
        x: (points[index].x + points[index + 1].x) / 2,
        y: (points[index].y + points[index + 1].y) / 2
      )
      if padded.contains(mid) {
        return true
      }
    }
    return false
  }

  private struct StubRouteRouter: PolicyCanvasEdgeRouter {
    func route(
      source: CGPoint,
      target: CGPoint,
      context: PolicyCanvasRouteContext
    ) -> PolicyCanvasEdgeRoute {
      let cornerY = (source.y + target.y) / 2
      return PolicyCanvasEdgeRoute(
        points: [
          source,
          CGPoint(x: source.x, y: cornerY),
          CGPoint(x: target.x, y: cornerY),
          target,
        ],
        labelPosition: CGPoint(x: (source.x + target.x) / 2, y: cornerY)
      )
    }
  }
}
