import CoreGraphics
import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasViewportRouteSeed: Equatable {
  let id: String
  let routeKey: PolicyCanvasRouteWorkerKey
  let pipelineIdentity: String?
  let output: PolicyCanvasRouteWorkerOutput
  let nodePositionsByID: [String: CGPoint]
}

struct PolicyCanvasViewportResolvedRouteCache {
  let appliedRouteKey: PolicyCanvasRouteWorkerKey?
  let output: PolicyCanvasRouteWorkerOutput
  let nodePositionsByID: [String: CGPoint]
}

struct PolicyCanvasViewportRouteCache {
  var worker = PolicyCanvasRouteWorker()
  var generation: UInt64 = 0
  var appliedRouteKey: PolicyCanvasRouteWorkerKey?
  var cachedOutput = PolicyCanvasRouteWorkerOutput.empty
  var outputsByCanvasIdentity:
    [String: (output: PolicyCanvasRouteWorkerOutput, nodePositionsByID: [String: CGPoint])] = [:]
  var cachedNodePositionsByID: [String: CGPoint] = [:]
  var cachedCanvasIdentity: String?
  /// The view model's `layoutGeneration` at the last commit. The live recompute
  /// gate skips work when this still matches and the route key is unchanged, so a
  /// restored cache or precomputed seed is not needlessly re-routed.
  var cachedLayoutGeneration: UInt64 = 0

  mutating func clear(pipelineIdentity: String?) {
    appliedRouteKey = nil
    cachedOutput = .empty
    cachedNodePositionsByID = [:]
    cachedCanvasIdentity = pipelineIdentity
  }

  mutating func nextGeneration() -> UInt64 {
    generation &+= 1
    return generation
  }

  func generationMatches(_ generation: UInt64) -> Bool {
    self.generation == generation
  }

  mutating func update(
    routeKey: PolicyCanvasRouteWorkerKey?,
    pipelineIdentity: String?,
    output: PolicyCanvasRouteWorkerOutput,
    nodePositionsByID: [String: CGPoint],
    layoutGeneration: UInt64
  ) {
    cachedCanvasIdentity = pipelineIdentity
    cachedNodePositionsByID = nodePositionsByID
    cachedLayoutGeneration = layoutGeneration
    if cachedOutput.signature != output.signature {
      cachedOutput = output
    }
    if let pipelineIdentity {
      outputsByCanvasIdentity[pipelineIdentity] = (output, nodePositionsByID)
    }
    appliedRouteKey = routeKey
  }
}

/// The cache state to adopt after `pipelineIdentity` changes, plus whether the
/// caller must kick a fresh route recompute to refill it.
struct PolicyCanvasRouteCacheIdentityTransition {
  var cache: PolicyCanvasViewportRouteCache
  let schedulesRecompute: Bool
}

/// Resolve the route cache when the canvas identity flips. The blank-canvas-on-
/// restart bug came from this transition: the document's first policy trace id
/// seeds the cache and routes commit under it, then `activeCanvasId` resolves and
/// flips `pipelineIdentity` to the daemon canvas id. The graph is unchanged, so
/// the route key never moves and nothing else re-routes - yet the old handler
/// cleared the cache here and never rescheduled, leaving `hasRenderableRouteOutput`
/// false for the new identity forever. Three outcomes:
///
/// 1. A per-identity output already exists for the new id - adopt it.
/// 2. The live cache still holds this exact route key with non-empty routes -
///    re-point it to the new identity so the canvas never blanks (same graph).
/// 3. Otherwise clear for the new identity and tell the caller to recompute, so
///    the now-empty cache refills instead of staying blank.
func policyCanvasRouteCacheAfterIdentityChange(
  cache: PolicyCanvasViewportRouteCache,
  newIdentity: String?,
  routeKey: PolicyCanvasRouteWorkerKey,
  layoutGeneration: UInt64
) -> PolicyCanvasRouteCacheIdentityTransition {
  var next = cache
  if let newIdentity, let stored = cache.outputsByCanvasIdentity[newIdentity] {
    next.appliedRouteKey = routeKey
    next.cachedOutput = stored.output
    next.cachedNodePositionsByID = stored.nodePositionsByID
    next.cachedCanvasIdentity = newIdentity
    next.cachedLayoutGeneration = layoutGeneration
    return PolicyCanvasRouteCacheIdentityTransition(cache: next, schedulesRecompute: false)
  }
  if cache.appliedRouteKey == routeKey, !cache.cachedOutput.routes.isEmpty {
    next.cachedCanvasIdentity = newIdentity
    if let newIdentity {
      next.outputsByCanvasIdentity[newIdentity] = (
        cache.cachedOutput, cache.cachedNodePositionsByID
      )
    }
    return PolicyCanvasRouteCacheIdentityTransition(cache: next, schedulesRecompute: false)
  }
  next.clear(pipelineIdentity: newIdentity)
  return PolicyCanvasRouteCacheIdentityTransition(cache: next, schedulesRecompute: true)
}

func policyCanvasViewportResolvedRouteCache(
  routeCache: PolicyCanvasViewportRouteCache,
  routeKey: PolicyCanvasRouteWorkerKey,
  pipelineIdentity: String?,
  routeSeed: PolicyCanvasViewportRouteSeed?
) -> PolicyCanvasViewportResolvedRouteCache {
  let cacheHasRoutedThisKey =
    routeCache.cachedCanvasIdentity == pipelineIdentity
    && routeCache.appliedRouteKey == routeKey
  // Once the live recompute has committed the routed output for this exact key,
  // the cache is authoritative - it tracks node drags, whereas the seed is a
  // first-paint snapshot at the loaded positions. Preferring the seed here would
  // pin a seeded canvas to its original layout and ignore every live recompute.
  if !cacheHasRoutedThisKey,
    let routeSeed,
    routeSeed.routeKey == routeKey,
    routeSeed.pipelineIdentity == pipelineIdentity
  {
    return PolicyCanvasViewportResolvedRouteCache(
      appliedRouteKey: routeSeed.routeKey,
      output: routeSeed.output,
      nodePositionsByID: routeSeed.nodePositionsByID
    )
  }

  guard routeCache.cachedCanvasIdentity == pipelineIdentity else {
    return PolicyCanvasViewportResolvedRouteCache(
      appliedRouteKey: nil,
      output: .empty,
      nodePositionsByID: [:]
    )
  }
  return PolicyCanvasViewportResolvedRouteCache(
    appliedRouteKey: routeCache.appliedRouteKey,
    output: routeCache.cachedOutput,
    nodePositionsByID: routeCache.cachedNodePositionsByID
  )
}
