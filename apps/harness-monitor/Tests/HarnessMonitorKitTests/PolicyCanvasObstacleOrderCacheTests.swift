import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas obstacle order cache key")
struct PolicyCanvasObstacleOrderCacheTests {
  @Test("reordering obstacles hits the cache")
  func reorderingObstaclesHitsCache() {
    let groups = [makeGroup(id: "g-base")]
    let obstacleA = CGRect(x: 100, y: 100, width: 40, height: 40)
    let obstacleB = CGRect(x: 300, y: 200, width: 40, height: 40)
    let baseline = PolicyCanvasRouteContext(
      lane: 0,
      groups: groups,
      sourceGroupID: "g-base",
      targetGroupID: "g-base",
      obstacles: [obstacleA, obstacleB]
    )
    let reordered = PolicyCanvasRouteContext(
      lane: 0,
      groups: groups,
      sourceGroupID: "g-base",
      targetGroupID: "g-base",
      obstacles: [obstacleB, obstacleA]
    )

    let inner = ObstacleCacheTestInnerRouter()
    let memoized = PolicyCanvasMemoizedRouter(inner: inner)
    let source = CGPoint(x: 50, y: 50)
    let target = CGPoint(x: 500, y: 500)

    _ = memoized.route(source: source, target: target, context: baseline)
    _ = memoized.route(source: source, target: target, context: reordered)

    #expect(
      memoized.misses == 1, "Reordered obstacles must hit the cache, got misses=\(memoized.misses)")
    #expect(memoized.hits == 1)
  }

  @Test("contexts with reordered obstacles are equal")
  func contextsWithReorderedObstaclesAreEqual() {
    let groups = [makeGroup(id: "g-base")]
    let obstacleA = CGRect(x: 100, y: 100, width: 40, height: 40)
    let obstacleB = CGRect(x: 300, y: 200, width: 40, height: 40)
    let baseline = PolicyCanvasRouteContext(
      lane: 0,
      groups: groups,
      sourceGroupID: "g-base",
      targetGroupID: "g-base",
      obstacles: [obstacleA, obstacleB]
    )
    let reordered = PolicyCanvasRouteContext(
      lane: 0,
      groups: groups,
      sourceGroupID: "g-base",
      targetGroupID: "g-base",
      obstacles: [obstacleB, obstacleA]
    )
    #expect(baseline == reordered)
  }

  private func makeGroup(id: String) -> PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: id,
      title: id,
      frame: CGRect(x: 0, y: 0, width: 200, height: 200),
      tone: .intake
    )
  }
}

private final class ObstacleCacheTestInnerRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    PolicyCanvasEdgeRoute(points: [source, target], labelPosition: source)
  }
}
