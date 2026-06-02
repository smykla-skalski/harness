import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasVisibilityRouterTests {
  @Test("Displayed routes keep a minimum straight run before the first turn")
  func displayedRoutesKeepMinimumStraightRunBeforeFirstTurn() {
    let route = displayedRoute(lane: 0)

    #expect(route.points[0] == CGPoint(x: 100, y: 100))
    #expect(
      route.points[1]
        == CGPoint(
          x: 100 + PolicyCanvasLayout.edgePortTurnMinimumLead,
          y: 100
        )
    )
    #expect(route.points[2].x == route.points[1].x)
  }

  @Test("Displayed routes stagger source and target elbows by lane")
  func displayedRoutesStaggerSourceAndTargetElbowsByLane() {
    let lane0 = displayedRoute(lane: 0)
    let lane1 = displayedRoute(lane: 1)

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
    let lane1 = displayedRoute(lane: 1)
    let lane2 = displayedRoute(lane: 2)
    let lane3 = displayedRoute(lane: 3)

    #expect(lane1.points[2].y < lane2.points[2].y)
    #expect(lane2.points[2].y < lane3.points[2].y)
    #expect(lane1.points[2].x < lane2.points[2].x)
    #expect(lane2.points[2].x < lane3.points[2].x)
  }

  @Test("Displayed routes keep final bridge segments out of obstacles")
  func displayedRoutesKeepFinalBridgeSegmentsOutOfObstacles() {
    let obstacle = CGRect(x: 280, y: 50, width: 120, height: 120)
    let route = visibilityDisplayedRoute(obstacle: obstacle, lane: 0)

    #expect(!polylineEntersObstacle(route.points, obstacle: obstacle))
  }

  @Test("Displayed routes keep higher-lane bridge segments out of obstacles")
  func displayedRoutesKeepHigherLaneBridgeSegmentsOutOfObstacles() {
    let obstacle = CGRect(x: 280, y: 50, width: 120, height: 120)
    let route = visibilityDisplayedRoute(obstacle: obstacle, lane: 3)

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

  private func displayedRoute(lane: Int) -> PolicyCanvasEdgeRoute {
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

  private func visibilityDisplayedRoute(
    obstacle: CGRect,
    lane: Int
  ) -> PolicyCanvasEdgeRoute {
    policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: PolicyCanvasVisibilityRouter(),
        source: (point: CGPoint(x: 100, y: 100), side: .trailing),
        sourceFanoutLane: lane,
        target: (point: CGPoint(x: 600, y: 100), side: .leading),
        targetFanoutLane: lane,
        context: context(lane: lane, obstacles: [obstacle])
      )
    )
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
