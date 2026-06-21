import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasRouteCacheIdentityTransitionTests {
  private func routeKey(generation: UInt64) -> PolicyCanvasRouteWorkerKey {
    PolicyCanvasRouteWorkerKey(
      graphGeneration: generation,
      nodeCount: 2,
      groupCount: 0,
      edgeCount: 1,
      fontScale: 1,
      routingHints: nil
    )
  }

  private func output(label: String) -> PolicyCanvasRouteWorkerOutput {
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
      labelPosition: CGPoint(x: 50, y: 0)
    )
    return PolicyCanvasRouteWorkerOutput(
      routes: [label: route],
      labelPositions: [:],
      portVisibility: [:],
      portMarkerLayout: .empty,
      visibleBounds: CGRect(x: 0, y: 0, width: 100, height: 1),
      contentSize: CGSize(width: 100, height: 1),
      accessibilityEdgeLabelsByID: [:],
      accessibilityNodeEntries: [],
      accessibilityEdgeEntries: [],
      nodeAccessibilityValuesByID: [:],
      connectTargetsByNodeID: [:]
    )
  }

  // The blank-canvas-on-restart bug: the document's policyTraceIds.first seeds
  // the cache, routes commit under identity "trace", then activeCanvasId resolves
  // to "canvas" and flips pipelineIdentity. The routeKey is unchanged (same
  // graph), so nothing else re-routes. The old handler cleared the cache here and
  // never rescheduled, leaving hasRenderableRouteOutput false forever - blank.
  @Test("identity flip for the same graph carries routes over without a recompute")
  func sameGraphIdentityFlipCarriesRoutesForward() {
    let key = routeKey(generation: 1)
    var cache = PolicyCanvasViewportRouteCache()
    cache.update(
      routeKey: key,
      pipelineIdentity: "trace",
      output: output(label: "routed"),
      nodePositionsByID: ["a": CGPoint(x: 10, y: 10)],
      layoutGeneration: 3
    )

    let transition = policyCanvasRouteCacheAfterIdentityChange(
      cache: cache,
      newIdentity: "canvas",
      routeKey: key,
      layoutGeneration: 3
    )

    // No blank: the routed output is re-pointed to the new identity and the
    // resolved cache now matches, so the canvas keeps rendering.
    #expect(transition.cache.cachedCanvasIdentity == "canvas")
    #expect(transition.cache.appliedRouteKey == key)
    #expect(transition.cache.cachedOutput.routes["routed"] != nil)
    #expect(transition.schedulesRecompute == false)
    let resolved = policyCanvasViewportResolvedRouteCache(
      routeCache: transition.cache,
      routeKey: key,
      pipelineIdentity: "canvas",
      routeSeed: nil
    )
    #expect(resolved.appliedRouteKey == key)
  }

  @Test("identity flip with no usable cache clears and schedules a recompute")
  func emptyCacheIdentityFlipSchedulesRecompute() {
    let cache = PolicyCanvasViewportRouteCache()

    let transition = policyCanvasRouteCacheAfterIdentityChange(
      cache: cache,
      newIdentity: "canvas",
      routeKey: routeKey(generation: 1),
      layoutGeneration: 0
    )

    #expect(transition.cache.cachedCanvasIdentity == "canvas")
    #expect(transition.cache.appliedRouteKey == nil)
    #expect(transition.schedulesRecompute == true)
  }

  @Test("identity flip adopts a previously cached per-identity output")
  func identityFlipAdoptsStoredPerIdentityOutput() {
    let key = routeKey(generation: 1)
    var cache = PolicyCanvasViewportRouteCache()
    cache.update(
      routeKey: key,
      pipelineIdentity: "canvas",
      output: output(label: "stored"),
      nodePositionsByID: ["a": CGPoint(x: 0, y: 0)],
      layoutGeneration: 2
    )
    // Now sitting on a different identity with an unrelated cached output.
    cache.cachedCanvasIdentity = "other"
    cache.cachedOutput = output(label: "other")
    cache.appliedRouteKey = routeKey(generation: 9)

    let transition = policyCanvasRouteCacheAfterIdentityChange(
      cache: cache,
      newIdentity: "canvas",
      routeKey: key,
      layoutGeneration: 2
    )

    #expect(transition.cache.cachedCanvasIdentity == "canvas")
    #expect(transition.cache.cachedOutput.routes["stored"] != nil)
    #expect(transition.schedulesRecompute == false)
  }
}
