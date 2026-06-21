// Companion to PolicyCanvasWorkspaceViews.swift.
// Single coalesced entry point that recomputes the real router output for the
// current graph geometry and commits it to the route cache. Driven by
// `PolicyCanvasLiveRouteCoalescer` from the viewport body so node drags show the
// router's true final routes (not a projected approximation) and dropping a node
// produces no visible change - the geometry was already routed mid-drag.
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewport {
  /// Request a coalesced live route recompute. Safe to call every drag tick:
  /// the coalescer keeps one recompute in flight and re-runs against the latest
  /// geometry, never queueing stale work. Mutating only the coalescer's private
  /// flags here keeps this off the body-derived task-id feedback path.
  @MainActor
  func scheduleLiveRouteRecompute(fontScale: CGFloat, routeSeed: PolicyCanvasViewportRouteSeed?) {
    bridgeLiveRouteCoalescer.schedule {
      await recomputeLiveRoutes(fontScale: fontScale, routeSeed: routeSeed)
    }
  }

  /// Recompute and commit routes for the current geometry, unless the cache is
  /// already current. The gate makes this a no-op when neither the route key nor
  /// the layout generation moved since the last commit, so a restored cache is
  /// reused rather than re-routed. A precomputed seed that matches the current
  /// key and positions is committed verbatim instead of recomputed, preserving
  /// the large-graph first-paint fast path.
  @MainActor
  func recomputeLiveRoutes(fontScale: CGFloat, routeSeed: PolicyCanvasViewportRouteSeed?) async {
    let routeKey = policyCanvasRouteWorkerKey(
      viewModel: viewModel,
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: fontScale
    )
    let pipelineIdentity = viewModel.pipelineIdentity
    if liveRouteCacheIsCurrent(routeKey: routeKey, pipelineIdentity: pipelineIdentity) {
      return
    }
    if let routeSeed,
      routeSeed.routeKey == routeKey,
      routeSeed.pipelineIdentity == pipelineIdentity,
      routeSeed.nodePositionsByID == policyCanvasNodePositionsByID(viewModel.nodes)
    {
      updateCachedRoutes(
        routeKey: routeSeed.routeKey,
        pipelineIdentity: routeSeed.pipelineIdentity,
        output: routeSeed.output,
        nodePositionsByID: routeSeed.nodePositionsByID
      )
      return
    }
    let generation = nextRouteGeneration()
    let result = await policyCanvasViewportRouteRebuildResult(
      worker: routeWorkerInstance(),
      viewModel: viewModel,
      fontScale: fontScale
    )
    guard !Task.isCancelled, routeGenerationMatches(generation) else {
      return
    }
    updateCachedRoutes(
      routeKey: routeKey,
      pipelineIdentity: pipelineIdentity,
      output: result.output,
      nodePositionsByID: result.nodePositionsByID
    )
  }

  /// True when the cache already holds the routed output for this exact route key
  /// and layout generation, so no recompute is needed.
  @MainActor
  func liveRouteCacheIsCurrent(
    routeKey: PolicyCanvasRouteWorkerKey,
    pipelineIdentity: String?
  ) -> Bool {
    bridgeRouteCache.cachedCanvasIdentity == pipelineIdentity
      && bridgeRouteCache.appliedRouteKey == routeKey
      && bridgeRouteCache.cachedLayoutGeneration == viewModel.layoutGeneration
  }
}
