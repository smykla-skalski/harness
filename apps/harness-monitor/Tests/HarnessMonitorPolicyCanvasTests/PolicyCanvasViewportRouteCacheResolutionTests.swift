import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasViewportRouteCacheResolutionTests {
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
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
    let route = PolicyCanvasEdgeRoute(points: points, labelPosition: CGPoint(x: 50, y: 0))
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

  @Test("a committed live recompute wins over a seed for the same route key")
  func committedCacheWinsOverSeedForSameKey() {
    let key = routeKey(generation: 1)
    var cache = PolicyCanvasViewportRouteCache()
    // The live recompute committed the routed output for this exact key.
    cache.update(
      routeKey: key,
      pipelineIdentity: "canvas",
      output: output(label: "live"),
      nodePositionsByID: ["a": CGPoint(x: 10, y: 10)],
      layoutGeneration: 4
    )
    // A first-paint seed for the same key still lingers in the parameter stream.
    let seed = PolicyCanvasViewportRouteSeed(
      id: "seed",
      routeKey: key,
      pipelineIdentity: "canvas",
      output: output(label: "seed"),
      nodePositionsByID: ["a": CGPoint(x: 0, y: 0)]
    )

    let resolved = policyCanvasViewportResolvedRouteCache(
      routeCache: cache,
      routeKey: key,
      pipelineIdentity: "canvas",
      routeSeed: seed
    )

    // Cache, not seed: a seeded canvas must follow live drags, not pin to load.
    #expect(resolved.output.routes["live"] != nil)
    #expect(resolved.output.routes["seed"] == nil)
    #expect(resolved.appliedRouteKey == key)
  }

  @Test("a seed is used for first paint before any live recompute commits")
  func seedUsedBeforeCacheCommits() {
    let key = routeKey(generation: 1)
    let cache = PolicyCanvasViewportRouteCache()
    let seed = PolicyCanvasViewportRouteSeed(
      id: "seed",
      routeKey: key,
      pipelineIdentity: "canvas",
      output: output(label: "seed"),
      nodePositionsByID: ["a": CGPoint(x: 0, y: 0)]
    )

    let resolved = policyCanvasViewportResolvedRouteCache(
      routeCache: cache,
      routeKey: key,
      pipelineIdentity: "canvas",
      routeSeed: seed
    )

    #expect(resolved.output.routes["seed"] != nil)
    #expect(resolved.appliedRouteKey == key)
  }

  @Test("a stale cache for a different key falls through to projection base")
  func staleCacheKeyExposedAsProjectionBase() {
    let committedKey = routeKey(generation: 1)
    let currentKey = routeKey(generation: 2)
    var cache = PolicyCanvasViewportRouteCache()
    cache.update(
      routeKey: committedKey,
      pipelineIdentity: "canvas",
      output: output(label: "stale"),
      nodePositionsByID: ["a": CGPoint(x: 10, y: 10)],
      layoutGeneration: 1
    )

    let resolved = policyCanvasViewportResolvedRouteCache(
      routeCache: cache,
      routeKey: currentKey,
      pipelineIdentity: "canvas",
      routeSeed: nil
    )

    // The stale output is returned with its own (mismatched) applied key so the
    // body marks it stale and the projection gap-fills until the recompute lands.
    #expect(resolved.output.routes["stale"] != nil)
    #expect(resolved.appliedRouteKey == committedKey)
    #expect(resolved.appliedRouteKey != currentKey)
  }
}
