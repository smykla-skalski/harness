import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewport {
  /// Reset the route cache to empty for the current canvas identity, used when a
  /// canvas switch has no cached routes to restore.
  @MainActor
  func clearCachedRouteOutput() {
    clearRouteCache(pipelineIdentity: viewModel.pipelineIdentity)
  }

  /// Service a `requestAtomicReflow(...)`: route the planned layout off-main,
  /// then commit node positions and publish the precomputed routes in the same
  /// MainActor tick. Until the routes are ready the model is untouched, so the
  /// canvas holds the prior layout and then reveals the reformatted nodes and
  /// wires together - never the stale, mangled projection a synchronous
  /// `reflowLayout()` flashes between the node move and the async route refresh.
  @MainActor
  func performAtomicReflow(fontScale: CGFloat) async {
    // Read the request as a monotonic signal; never clear it. Clearing would flip
    // the `atomicReflowRequest?.id` the body's `.onChange` watches and could
    // cancel this work mid-route before the commit lands.
    guard let request = viewModel.atomicReflowRequest else {
      return
    }
    let generation = nextRouteGeneration()
    guard
      let plan = await policyCanvasAtomicReflowRoutePlan(
        viewModel: viewModel,
        preserveManualAnchors: request.preserveManualAnchors,
        force: request.force,
        fontScale: fontScale,
        routeWorker: routeWorkerInstance()
      )
    else {
      // Empty or already-tidy layout: fall back so status and centering still fire.
      viewModel.reflowLayout(
        preserveManualAnchors: request.preserveManualAnchors,
        force: request.force
      )
      return
    }
    guard !Task.isCancelled, routeGenerationMatches(generation) else {
      return
    }
    commitAtomicReflow(request: request, plan: plan, fontScale: fontScale)
  }

  /// Publish the planned positions without an async route request, then hand the
  /// precomputed routes straight to the cache so the next render draws the new
  /// nodes and wires as one consistent frame.
  @MainActor
  private func commitAtomicReflow(
    request: PolicyCanvasAtomicReflowRequest,
    plan: PolicyCanvasAtomicReflowRoutePlan,
    fontScale: CGFloat
  ) {
    viewModel.commitPlannedReflowGraph(
      plan.graph,
      preserveManualAnchors: request.preserveManualAnchors,
      force: request.force,
      requestsRouteComputation: false
    )
    let pipelineIdentity = viewModel.pipelineIdentity
    updateCachedRoutes(
      routeKey: policyCanvasRouteWorkerKey(
        viewModel: viewModel,
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: fontScale
      ),
      pipelineIdentity: pipelineIdentity,
      output: plan.output,
      nodePositionsByID: policyCanvasNodePositionsByID(viewModel.nodes)
    )
  }
}
