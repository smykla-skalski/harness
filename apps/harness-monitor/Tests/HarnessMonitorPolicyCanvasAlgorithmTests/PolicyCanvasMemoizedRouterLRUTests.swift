import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas memoized router LRU eviction")
struct PolicyCanvasMemoizedRouterLRUTests {
  @Test("filling past capacity evicts the least-recently-used entry, not the cache")
  func capacityOverflowEvictsLRUOnly() {
    let inner = CountingRouter()
    let router = PolicyCanvasMemoizedRouter(inner: inner, capacity: 3)
    let context = Self.context

    // Fill the cache with 3 distinct entries (keyed on source coordinates).
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 3, y: 0), target: .zero, context: context)

    // Touch entry 1 so 2 is the least recently used.
    router.resetStatistics()
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    #expect(router.hits == 1)

    // Inserting a 4th entry should evict entry 2 (LRU), not entry 1 or 3.
    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 4, y: 0), target: .zero, context: context)
    #expect(inner.callCount == 1, "Insertion is a miss")

    // Entry 1 (most recent of the touched group) should still be cached.
    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    #expect(inner.callCount == 0, "Recently-touched entry 1 should still be cached")

    // Entry 3 (inserted before 4) should still be cached.
    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 3, y: 0), target: .zero, context: context)
    #expect(inner.callCount == 0, "Entry 3 should still be cached")

    // Entry 2 (LRU) should have been evicted.
    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    #expect(inner.callCount == 1, "Entry 2 should have been evicted")
  }

  @Test("touching an entry on hit moves it to head so it survives later eviction")
  func touchOnHitMovesEntryToHead() {
    let inner = CountingRouter()
    let router = PolicyCanvasMemoizedRouter(inner: inner, capacity: 2)
    let context = Self.context

    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    // Cache: head=2, tail=1
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    // After touch: head=1, tail=2
    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 3, y: 0), target: .zero, context: context)
    // Insertion evicts 2 (LRU), keeps 1 (most recently touched).
    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    #expect(inner.callCount == 0, "Touched entry 1 should still be cached")
    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    #expect(inner.callCount == 1, "Entry 2 should have been evicted on the insert of 3")
  }

  @Test("invalidate drops every entry without breaking the linked list")
  func invalidateClearsCacheCleanly() {
    let inner = CountingRouter()
    let router = PolicyCanvasMemoizedRouter(inner: inner, capacity: 4)
    let context = Self.context

    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    router.invalidate()

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    #expect(inner.callCount == 2, "Both routes should miss after invalidate")
  }

  private static let context = PolicyCanvasRouteContext(
    lane: 0,
    groups: [],
    sourceGroupID: nil,
    targetGroupID: nil
  )

  private final class CountingRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
    var callCount: Int = 0

    func route(
      source: CGPoint,
      target: CGPoint,
      context: PolicyCanvasRouteContext
    ) -> PolicyCanvasEdgeRoute {
      callCount += 1
      return PolicyCanvasEdgeRoute(points: [source, target], labelPosition: source)
    }
  }
}
