import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

/// Visibility-graph A* router gates from T2.1: explicit cases for the four
/// canonical scenarios named in the recommendations report plus a
/// property-style sweep proving the polyline invariants hold across random
/// graphs.
@Suite("Policy canvas visibility router")
struct PolicyCanvasVisibilityRouterTests {
  @Test("Aligned 2 nodes route as a straight segment with 0 bends")
  func zeroBendsWhenAligned() {
    let route = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 0, y: 100),
      target: CGPoint(x: 400, y: 100),
      context: context()
    )
    #expect(route.points.first == CGPoint(x: 0, y: 100))
    #expect(route.points.last == CGPoint(x: 400, y: 100))
    #expect(bendCount(of: route.points) == 0)
  }

  @Test("Obstacle between source and target forces detour")
  func detoursAroundObstacle() {
    let obstacle = CGRect(x: 150, y: 50, width: 100, height: 100)
    let route = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 0, y: 100),
      target: CGPoint(x: 400, y: 100),
      context: context(obstacles: [obstacle])
    )
    let bends = bendCount(of: route.points)
    #expect(bends >= 2)
    #expect(bends <= 4)
    #expect(!polylineEntersObstacle(route.points, obstacle: obstacle))
  }

  @Test("5 parallel edges around the same obstacle pick distinct detour lanes")
  func parallelEdgesGetDistinctLanes() {
    let obstacle = CGRect(x: 150, y: 50, width: 100, height: 100)
    let routes = (0..<5).map { lane in
      PolicyCanvasVisibilityRouter().route(
        source: CGPoint(x: 0, y: 100),
        target: CGPoint(x: 400, y: 100),
        context: context(lane: lane, obstacles: [obstacle])
      )
    }
    // Each lane offsets the midX/midY anchors by `lane * channelStep`. With
    // an obstacle in the way the detour bus row picks up the lane-specific
    // y-coordinate, giving each parallel edge its own visual channel.
    let busYs = routes.compactMap { route -> CGFloat? in
      guard route.points.count >= 3 else {
        return nil
      }
      return route.points[1].y
    }
    let uniqueBusYs = Set(busYs)
    #expect(uniqueBusYs.count == 5)
  }

  @Test("Two crossing edges intersect at right angles")
  func crossingEdgesIntersectAtRightAngles() {
    let horizontal = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 0, y: 200),
      target: CGPoint(x: 400, y: 200),
      context: context()
    )
    let vertical = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 200, y: 0),
      target: CGPoint(x: 200, y: 400),
      context: context()
    )
    #expect(allSegmentsAxisAligned(horizontal.points))
    #expect(allSegmentsAxisAligned(vertical.points))
  }

  @Test("Property: random graphs produce valid axis-aligned polylines")
  func propertyRandomGraphs() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<20 {
      let nodeCount = Int.random(in: 4...12, using: &generator)
      let nodes = (0..<nodeCount).map { _ in
        CGRect(
          x: CGFloat.random(in: 50...700, using: &generator),
          y: CGFloat.random(in: 50...500, using: &generator),
          width: 100,
          height: 60
        )
      }
      let source = CGPoint(x: 10, y: 300)
      let target = CGPoint(x: 800, y: 300)
      let route = PolicyCanvasVisibilityRouter().route(
        source: source,
        target: target,
        context: context(obstacles: nodes)
      )
      #expect(route.points.first == source)
      #expect(route.points.last == target)
      #expect(allSegmentsAxisAligned(route.points))
      #expect(bendCount(of: route.points) <= 8)
    }
  }

  @Test("20-node graph routes under 16ms")
  func twentyNodeGraphPerformance() {
    var generator = SystemRandomNumberGenerator()
    let nodes = (0..<20).map { _ in
      CGRect(
        x: CGFloat.random(in: 50...1_200, using: &generator),
        y: CGFloat.random(in: 50...800, using: &generator),
        width: 100,
        height: 60
      )
    }
    let router = PolicyCanvasVisibilityRouter()
    let start = Date()
    for index in 0..<10 {
      _ = router.route(
        source: CGPoint(x: 10, y: 400),
        target: CGPoint(x: 1_300, y: 400),
        context: context(lane: index, obstacles: nodes)
      )
    }
    let elapsed = Date().timeIntervalSince(start) / 10.0
    #expect(elapsed < 0.016, "Average route time was \(elapsed * 1000)ms, expected <16ms")
  }

  @Test("Flex anchor selection picks the lowest-bend combination")
  func flexAnchorPicksLowestBendRoute() {
    let router = PolicyCanvasVisibilityRouter()
    // Source candidates: trailing (right) at (200, 100), top at (100, 0),
    // bottom at (100, 200), leading at (0, 100). Target candidates similar.
    // For the natural left-to-right flow, trailing→leading should be the
    // 0-bend pick (both at y=300 on a clear right path).
    let sourceCandidates = [
      CGPoint(x: 200, y: 300),  // trailing
      CGPoint(x: 100, y: 200),  // top
      CGPoint(x: 100, y: 400),  // bottom
      CGPoint(x: 0, y: 300),  // leading
    ]
    let targetCandidates = [
      CGPoint(x: 700, y: 300),  // leading
      CGPoint(x: 800, y: 200),  // top
      CGPoint(x: 800, y: 400),  // bottom
      CGPoint(x: 900, y: 300),  // trailing
    ]
    let flexed = router.route(
      sourceCandidates: sourceCandidates,
      targetCandidates: targetCandidates,
      context: context()
    )
    let pinned = router.route(
      source: sourceCandidates[3],  // leading (worst for left-to-right)
      target: targetCandidates[3],  // trailing (worst)
      context: context()
    )
    #expect(bendCount(of: flexed.points) <= bendCount(of: pinned.points))
    // Trailing→leading produces a straight horizontal route between the
    // two aligned anchors at y=300; flex should land there.
    #expect(flexed.points.first == CGPoint(x: 200, y: 300))
    #expect(flexed.points.last == CGPoint(x: 700, y: 300))
  }

  @Test("Routes around group-style obstacle rects (T4.1)")
  func routesAroundGroupObstacle() {
    // T4.1: callers now pass `viewModel.routingObstacles`, which appends
    // group frames to node frames. The router treats them identically -
    // a group rect between two endpoints outside any group blocks the
    // straight-line route just like a node rect would. Edges with one
    // endpoint inside the group rely on `preparedObstacles`' auto-drop
    // when the padded rect contains source/target.
    let groupRect = CGRect(x: 200, y: 50, width: 200, height: 200)
    let route = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 0, y: 150),
      target: CGPoint(x: 600, y: 150),
      context: context(obstacles: [groupRect])
    )
    #expect(!polylineEntersObstacle(route.points, obstacle: groupRect))
    let bends = bendCount(of: route.points)
    #expect(bends >= 2)
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

  private func bendCount(of points: [CGPoint]) -> Int {
    guard points.count >= 3 else {
      return 0
    }
    var bends = 0
    for index in 1..<points.count - 1 {
      let prev = points[index - 1]
      let cur = points[index]
      let next = points[index + 1]
      let prevH = abs(cur.y - prev.y) < 0.0001
      let nextH = abs(next.y - cur.y) < 0.0001
      if prevH != nextH {
        bends += 1
      }
    }
    return bends
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
      obstacles: obstacles
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

  private func allSegmentsAxisAligned(_ points: [CGPoint]) -> Bool {
    for index in 0..<points.count - 1 {
      let dx = abs(points[index + 1].x - points[index].x)
      let dy = abs(points[index + 1].y - points[index].y)
      if dx > 0.0001 && dy > 0.0001 {
        return false
      }
    }
    return true
  }
}
