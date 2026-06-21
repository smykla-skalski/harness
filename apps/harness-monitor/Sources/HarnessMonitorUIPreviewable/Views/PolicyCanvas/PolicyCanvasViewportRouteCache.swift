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
