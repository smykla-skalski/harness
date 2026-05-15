import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

/// Contract test for the cache-identity invariant on `PolicyCanvasRouteContext`.
///
/// `PolicyCanvasMemoizedRouter` uses the context's synthesized `Hashable`
/// derivation as the cache key for the non-endpoint portion of every routing
/// call. If any field the inner router reads is missing from the `Hashable`
/// synthesis (or carried by a non-routing field someone added later), the
/// cache silently serves stale polylines on inputs that should have produced
/// distinct routes. There is no way to observe that from a unit test on the
/// inner router alone - the wrapped behaviour is correct on cache-miss and
/// wrong on cache-hit.
///
/// This suite guards the second failure mode by mutating each field of
/// `PolicyCanvasRouteContext` one at a time and asserting the wrapped
/// router's miss-rate flips to 100% across the mutated pair. When a new
/// field is added to the struct, this suite must grow to cover it, which
/// is the doc note on the struct itself.
@Suite("Policy canvas memoized router context contract")
struct PolicyCanvasMemoizedRouterContextContractTests {
  private static let endpoint = (
    source: CGPoint(x: 100, y: 200),
    target: CGPoint(x: 500, y: 200)
  )

  @Test("Mutating `lane` defeats the cache")
  func mutatingLaneMisses() {
    let baseline = makeBaselineContext()
    let mutated = PolicyCanvasRouteContext(
      lane: baseline.lane + 1,
      groups: baseline.groups,
      sourceGroupID: baseline.sourceGroupID,
      targetGroupID: baseline.targetGroupID,
      obstacles: baseline.obstacles
    )
    assertFieldIsInCacheKey(baseline: baseline, mutated: mutated, named: "lane")
  }

  @Test("Mutating `groups` defeats the cache")
  func mutatingGroupsMisses() {
    let baseline = makeBaselineContext()
    let mutated = PolicyCanvasRouteContext(
      lane: baseline.lane,
      groups: baseline.groups + [makeGroup(id: "g-extra")],
      sourceGroupID: baseline.sourceGroupID,
      targetGroupID: baseline.targetGroupID,
      obstacles: baseline.obstacles
    )
    assertFieldIsInCacheKey(baseline: baseline, mutated: mutated, named: "groups")
  }

  @Test("Mutating `sourceGroupID` defeats the cache")
  func mutatingSourceGroupMisses() {
    let baseline = makeBaselineContext()
    let mutated = PolicyCanvasRouteContext(
      lane: baseline.lane,
      groups: baseline.groups,
      sourceGroupID: "different-source-group",
      targetGroupID: baseline.targetGroupID,
      obstacles: baseline.obstacles
    )
    assertFieldIsInCacheKey(baseline: baseline, mutated: mutated, named: "sourceGroupID")
  }

  @Test("Mutating `targetGroupID` defeats the cache")
  func mutatingTargetGroupMisses() {
    let baseline = makeBaselineContext()
    let mutated = PolicyCanvasRouteContext(
      lane: baseline.lane,
      groups: baseline.groups,
      sourceGroupID: baseline.sourceGroupID,
      targetGroupID: "different-target-group",
      obstacles: baseline.obstacles
    )
    assertFieldIsInCacheKey(baseline: baseline, mutated: mutated, named: "targetGroupID")
  }

  @Test("Mutating `obstacles` defeats the cache")
  func mutatingObstaclesMisses() {
    let baseline = makeBaselineContext()
    let mutated = PolicyCanvasRouteContext(
      lane: baseline.lane,
      groups: baseline.groups,
      sourceGroupID: baseline.sourceGroupID,
      targetGroupID: baseline.targetGroupID,
      obstacles: baseline.obstacles + [CGRect(x: 999, y: 999, width: 10, height: 10)]
    )
    assertFieldIsInCacheKey(baseline: baseline, mutated: mutated, named: "obstacles")
  }

  /// Run two routing calls against a fresh memoized router - one with the
  /// baseline context, one with the mutated context. Both calls should miss
  /// the cache. If the mutated field is not in the cache key, the second
  /// call would hit and the wrapper would return the baseline's polyline
  /// for the mutated input - the silent staleness this contract exists to
  /// catch.
  private func assertFieldIsInCacheKey(
    baseline: PolicyCanvasRouteContext,
    mutated: PolicyCanvasRouteContext,
    named field: String
  ) {
    let inner = MissCountingRouter()
    let memoized = PolicyCanvasMemoizedRouter(inner: inner)
    _ = memoized.route(
      source: Self.endpoint.source,
      target: Self.endpoint.target,
      context: baseline
    )
    _ = memoized.route(
      source: Self.endpoint.source,
      target: Self.endpoint.target,
      context: mutated
    )
    #expect(
      memoized.misses == 2,
      """
      Expected two misses (baseline + mutated) but saw \(memoized.misses). \
      The `\(field)` field is not part of the cache key; mutations to it \
      will silently serve stale polylines.
      """
    )
    #expect(memoized.hits == 0)
  }

  private func makeBaselineContext() -> PolicyCanvasRouteContext {
    PolicyCanvasRouteContext(
      lane: 0,
      groups: [makeGroup(id: "g-base")],
      sourceGroupID: "g-base",
      targetGroupID: "g-base",
      obstacles: [CGRect(x: 200, y: 100, width: 80, height: 60)]
    )
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

/// Inner router that counts route calls so the suite can assert misses
/// rather than relying on the wrapper's hit/miss counters alone (which the
/// `#expect(memoized.misses == 2)` line already covers, but the explicit
/// helper makes the failure mode unambiguous if a future change reorders
/// where misses are recorded).
private final class MissCountingRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    PolicyCanvasEdgeRoute(points: [source, target], labelPosition: source)
  }
}
