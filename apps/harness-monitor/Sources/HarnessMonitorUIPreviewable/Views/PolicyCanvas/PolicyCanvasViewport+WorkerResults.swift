import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasViewportRouteRebuildResult {
  let output: PolicyCanvasRouteWorkerOutput
  let nodePositionsByID: [String: CGPoint]
}

@MainActor
func policyCanvasViewportRouteRebuildResult(
  worker: PolicyCanvasRouteWorker,
  viewModel: PolicyCanvasViewModel,
  fontScale: CGFloat
) async -> PolicyCanvasViewportRouteRebuildResult {
  let input = PolicyCanvasRouteWorkerInput(
    graphGeneration: viewModel.routeComputationGeneration,
    nodes: viewModel.nodes,
    groups: viewModel.groups,
    edges: viewModel.edges,
    fontScale: fontScale,
    routingHints: viewModel.routingHints,
    precomputedRoutes: viewModel.precomputedRoutes,
    algorithmSelection: viewModel.algorithmSelection
  )
  let output = await worker.compute(input: input)
  return PolicyCanvasViewportRouteRebuildResult(
    output: output,
    nodePositionsByID: policyCanvasNodePositionsByID(input.nodes)
  )
}

@MainActor
func policyCanvasViewportValidationPresentation(
  worker: PolicyCanvasValidationWorker,
  viewModel: PolicyCanvasViewModel
) async -> PolicyCanvasValidationPresentation {
  await worker.compute(
    input: PolicyCanvasValidationWorkerInput(
      nodes: viewModel.nodes,
      edges: viewModel.edges,
      daemonIssues: viewModel.daemonValidationIssues
    )
  )
}
