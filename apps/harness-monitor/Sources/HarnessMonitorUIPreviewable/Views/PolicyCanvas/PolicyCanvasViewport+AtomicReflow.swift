import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewport {
  /// Reset the route cache to empty for the current canvas identity, used when a
  /// canvas switch has no cached routes to restore.
  @MainActor
  func clearCachedRouteOutput() {
    appliedRouteKey = nil
    cachedRouteOutput = .empty
    cachedRouteNodePositionsByID = [:]
    cachedRouteCanvasIdentity = viewModel.pipelineIdentity
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
    guard
      let graph = viewModel.plannedReflowGraph(
        preserveManualAnchors: request.preserveManualAnchors,
        force: request.force
      )
    else {
      // Empty or already-tidy layout: fall back so status and centering still fire.
      viewModel.reflowLayout(
        preserveManualAnchors: request.preserveManualAnchors,
        force: request.force
      )
      return
    }
    let routeInput = PolicyCanvasRouteWorkerInput(
      graphGeneration: viewModel.routeComputationGeneration,
      nodes: graph.nodes,
      groups: graph.groups,
      edges: graph.edges,
      fontScale: fontScale,
      routingHints: graph.routingHints,
      algorithmSelection: viewModel.algorithmSelection
    )
    routeGeneration &+= 1
    let generation = routeGeneration
    let output = await routeWorker.compute(input: routeInput)
    guard !Task.isCancelled, routeGeneration == generation else {
      return
    }
    commitAtomicReflow(request: request, output: output, fontScale: fontScale)
  }

  /// Publish the planned positions without an async route request, then hand the
  /// precomputed routes straight to the cache so the next render draws the new
  /// nodes and wires as one consistent frame.
  @MainActor
  private func commitAtomicReflow(
    request: PolicyCanvasAtomicReflowRequest,
    output: PolicyCanvasRouteWorkerOutput,
    fontScale: CGFloat
  ) {
    viewModel.reflowLayout(
      preserveManualAnchors: request.preserveManualAnchors,
      force: request.force,
      requestsRouteComputation: false
    )
    let pipelineIdentity = viewModel.pipelineIdentity
    cachedRouteCanvasIdentity = pipelineIdentity
    cachedRouteNodePositionsByID = policyCanvasNodePositionsByID(viewModel.nodes)
    cachedRouteOutput = output
    if let pipelineIdentity {
      cachedRouteOutputsByCanvasIdentity[pipelineIdentity] = (
        output,
        cachedRouteNodePositionsByID
      )
    }
    appliedRouteKey = policyCanvasRouteWorkerKey(
      viewModel: viewModel,
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: fontScale
    )
  }
}
