import CoreGraphics
import XCTest

@testable import HarnessMonitorPolicyCanvasAlgorithms

final class PolicyCanvasMemoizedRouterXCTest: XCTestCase {
  private let context = PolicyCanvasRouteContext(
    lane: 0,
    groups: [],
    sourceGroupID: nil,
    targetGroupID: nil
  )

  func testCapacityOverflowEvictsLeastRecentlyUsedEntry() {
    let inner = CountingRouter()
    let router = PolicyCanvasMemoizedRouter(inner: inner, capacity: 3)

    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 3, y: 0), target: .zero, context: context)

    router.resetStatistics()
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    XCTAssertEqual(router.hits, 1)

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 4, y: 0), target: .zero, context: context)
    XCTAssertEqual(inner.callCount, 1)

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    XCTAssertEqual(inner.callCount, 0)

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 3, y: 0), target: .zero, context: context)
    XCTAssertEqual(inner.callCount, 0)

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    XCTAssertEqual(inner.callCount, 1)
  }

  func testTouchOnHitMovesEntryToHead() {
    let inner = CountingRouter()
    let router = PolicyCanvasMemoizedRouter(inner: inner, capacity: 2)

    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 3, y: 0), target: .zero, context: context)

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    XCTAssertEqual(inner.callCount, 0)

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    XCTAssertEqual(inner.callCount, 1)
  }

  func testInvalidateClearsCacheCleanly() {
    let inner = CountingRouter()
    let router = PolicyCanvasMemoizedRouter(inner: inner, capacity: 4)

    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    router.invalidate()

    inner.callCount = 0
    _ = router.route(source: CGPoint(x: 1, y: 0), target: .zero, context: context)
    _ = router.route(source: CGPoint(x: 2, y: 0), target: .zero, context: context)
    XCTAssertEqual(inner.callCount, 2)
  }
}

private final class CountingRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
  var callCount = 0

  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    callCount += 1
    return PolicyCanvasEdgeRoute(points: [source, target], labelPosition: source)
  }
}
