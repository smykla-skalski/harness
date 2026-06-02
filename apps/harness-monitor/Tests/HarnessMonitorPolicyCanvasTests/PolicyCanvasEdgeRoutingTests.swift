import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Baseline pinning of the six-case hand-coded router. These tests fix the
/// polyline outputs so the channel-model refactor (T1.2) can be detected as
/// an intentional change rather than a silent drift. Visual approval is
/// expected when the channel-model lands.
@Suite("Policy canvas edge routing - baseline pins")
struct PolicyCanvasEdgeRoutingTests {
  @Test("Default route is a 4-point L for an aligned-ish target")
  func defaultRouteShape() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 0
    )
    #expect(route.points.count == 4)
    #expect(route.points.first == CGPoint(x: 0, y: 0))
    #expect(route.points.last == CGPoint(x: 200, y: 100))
  }

  @Test("Default route midX uses 0.46 * horizontalDistance with a 72pt floor")
  func defaultRouteMidX() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 0
    )
    #expect(route.points[1].x == 92)
    #expect(route.points[2].x == 92)
  }

  @Test("Lane offset spreads parallel default routes")
  func defaultRouteLaneOffsetsSpread() {
    let route0 = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 0
    )
    let route1 = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 1
    )
    #expect(route0.points[1].x != route1.points[1].x)
  }

  @Test("Wide route lifts to a top bus lane")
  func wideRouteLifts() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 0, y: 900),
      target: CGPoint(x: 600, y: 900),
      lane: 0
    )
    #expect(route.points.count == 6)
    let busY = route.points[2].y
    #expect(busY < route.points.first!.y)
  }

  @Test("Vertical stack route routes around the group right edge")
  func verticalStackRouteShape() {
    let group = PolicyCanvasGroup(
      id: "g0",
      title: "G",
      frame: CGRect(x: 0, y: 0, width: 200, height: 600),
      tone: .intake
    )
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 100, y: 60),
      target: CGPoint(x: 100, y: 400),
      lane: 0,
      groups: [group],
      sourceGroupID: "g0",
      targetGroupID: "g0"
    )
    #expect(route.points.count == 5)
    #expect(route.points[2].x > group.frame.maxX)
  }

  @Test("Same-group return route exits east and loops back")
  func sameGroupReturnRouteShape() {
    let group = PolicyCanvasGroup(
      id: "g0",
      title: "G",
      frame: CGRect(x: 0, y: 0, width: 400, height: 400),
      tone: .intake
    )
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 320, y: 100),
      target: CGPoint(x: 60, y: 200),
      lane: 0,
      groups: [group],
      sourceGroupID: "g0",
      targetGroupID: "g0"
    )
    #expect(route.points.count == 6)
    let exitX = route.points[1].x
    #expect(exitX > group.frame.maxX)
  }

  @Test("Inter-group route uses bus column between source and target groups")
  func interGroupRouteShape() {
    let sourceGroup = PolicyCanvasGroup(
      id: "g0",
      title: "S",
      frame: CGRect(x: 0, y: 0, width: 200, height: 400),
      tone: .intake
    )
    let targetGroup = PolicyCanvasGroup(
      id: "g1",
      title: "T",
      frame: CGRect(x: 600, y: 0, width: 200, height: 400),
      tone: .evaluation
    )
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 180, y: 100),
      target: CGPoint(x: 620, y: 200),
      lane: 0,
      groups: [sourceGroup, targetGroup],
      sourceGroupID: "g0",
      targetGroupID: "g1"
    )
    #expect(route.points.count == 6)
    let busX = route.points[3].x
    #expect(busX > sourceGroup.frame.maxX)
    #expect(busX < targetGroup.frame.minX)
  }

  @Test("Blocking route routes over an intervening group")
  func blockingRouteShape() {
    let blocker = PolicyCanvasGroup(
      id: "block",
      title: "Block",
      frame: CGRect(x: 200, y: 60, width: 200, height: 200),
      tone: .intake
    )
    let sourceGroup = PolicyCanvasGroup(
      id: "g0",
      title: "S",
      frame: CGRect(x: 0, y: 60, width: 150, height: 200),
      tone: .intake
    )
    let targetGroup = PolicyCanvasGroup(
      id: "g1",
      title: "T",
      frame: CGRect(x: 500, y: 60, width: 150, height: 200),
      tone: .evaluation
    )
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 140, y: 100),
      target: CGPoint(x: 510, y: 100),
      lane: 0,
      groups: [sourceGroup, blocker, targetGroup],
      sourceGroupID: "g0",
      targetGroupID: "g1"
    )
    #expect(route.points.count >= 4)
    #expect(route.points.first == CGPoint(x: 140, y: 100))
    #expect(route.points.last == CGPoint(x: 510, y: 100))
  }

  @Test("Label position lies on one of the route segments")
  func labelPositionIsOnRoute() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 300, y: 200),
      lane: 0
    )
    let labelPosition = route.labelPosition
    let onSomeSegment = zip(route.points, route.points.dropFirst()).contains { left, right in
      let minX = min(left.x, right.x)
      let maxX = max(left.x, right.x)
      let minY = min(left.y, right.y)
      let maxY = max(left.y, right.y)
      return labelPosition.x >= minX - 0.001
        && labelPosition.x <= maxX + 0.001
        && labelPosition.y >= minY - 0.001
        && labelPosition.y <= maxY + 0.001
    }
    #expect(onSomeSegment)
  }
}
