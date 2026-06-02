import CoreGraphics
import Foundation
import XCTest

@testable import HarnessMonitorPolicyCanvasAlgorithms

final class PolicyCanvasRouterCoreXCTest: XCTestCase {
  func testHandCodedRouterMatchesDirectRouteShape() {
    let router = PolicyCanvasHandCodedOrthogonalRouter()
    let viaRouter = router.route(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      context: routeContext()
    )
    let direct = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 0
    )

    XCTAssertEqual(viaRouter.points, direct.points)
    XCTAssertEqual(viaRouter.labelPosition, direct.labelPosition)
  }

  func testHandCodedRouterLaneSpreadChangesIntermediatePoint() {
    let router = PolicyCanvasHandCodedOrthogonalRouter()
    let lane0 = router.route(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      context: routeContext()
    )
    let lane3 = router.route(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      context: routeContext(lane: 3)
    )

    XCTAssertNotEqual(lane0.points[1].x, lane3.points[1].x)
  }

  func testVisibilityRouterProducesStraightSegmentForAlignedNodes() {
    let route = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 0, y: 100),
      target: CGPoint(x: 400, y: 100),
      context: routeContext()
    )

    XCTAssertEqual(route.points.first, CGPoint(x: 0, y: 100))
    XCTAssertEqual(route.points.last, CGPoint(x: 400, y: 100))
    XCTAssertEqual(bendCount(route.points), 0)
  }

  func testVisibilityRouterDetoursAroundObstacle() {
    let obstacle = CGRect(x: 150, y: 50, width: 100, height: 100)
    let route = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 0, y: 100),
      target: CGPoint(x: 400, y: 100),
      context: routeContext(obstacles: [obstacle])
    )

    let bends = bendCount(route.points)
    XCTAssertGreaterThanOrEqual(bends, 2)
    XCTAssertLessThanOrEqual(bends, 4)
    XCTAssertFalse(polylineEntersObstacle(route.points, obstacle: obstacle))
  }

  func testVisibilityAxisDedupCollapsesSubPointDifferences() {
    let axes = PolicyCanvasVisibilityRouter.sortedAxisCoordinates(
      anchor1: 100.0,
      anchor2: 500,
      laneOffset: 0,
      bounds: [(100.0001, 200)],
      corridorStep: 0
    )

    let occurrences = axes.filter { abs($0 - 100.0) < 0.5 }.count
    XCTAssertEqual(occurrences, 1)
  }

  private func routeContext(
    lane: Int = 0,
    obstacles: [CGRect] = []
  ) -> PolicyCanvasRouteContext {
    PolicyCanvasRouteContext(
      lane: lane,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil,
      obstacles: obstacles
    )
  }

  private func bendCount(_ points: [CGPoint]) -> Int {
    guard points.count >= 3 else {
      return 0
    }
    var bends = 0
    for index in 1..<(points.count - 1) {
      let previous = points[index - 1]
      let current = points[index]
      let next = points[index + 1]
      let incoming = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
      let outgoing = CGPoint(x: next.x - current.x, y: next.y - current.y)
      let incomingAxisIsHorizontal = abs(incoming.x) > abs(incoming.y)
      let outgoingAxisIsHorizontal = abs(outgoing.x) > abs(outgoing.y)
      if incomingAxisIsHorizontal != outgoingAxisIsHorizontal {
        bends += 1
      }
    }
    return bends
  }

  private func polylineEntersObstacle(_ points: [CGPoint], obstacle: CGRect) -> Bool {
    guard points.count >= 2 else {
      return false
    }
    for (start, end) in zip(points, points.dropFirst()) {
      let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
      if obstacle.contains(midpoint) {
        return true
      }
    }
    return false
  }
}
