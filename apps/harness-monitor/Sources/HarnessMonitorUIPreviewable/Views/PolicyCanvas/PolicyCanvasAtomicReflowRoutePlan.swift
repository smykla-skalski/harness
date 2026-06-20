import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasAtomicReflowRoutePlan {
  let graph: PolicyCanvasReflowGraph
  let appliesLayoutChange: Bool
  let output: PolicyCanvasRouteWorkerOutput
}

@MainActor
func policyCanvasAtomicReflowRoutePlan(
  viewModel: PolicyCanvasViewModel,
  preserveManualAnchors: Bool,
  force: Bool,
  fontScale: CGFloat,
  routeWorker: PolicyCanvasRouteWorker,
  routesCurrentGraphWhenUnchanged: Bool = false
) async -> PolicyCanvasAtomicReflowRoutePlan? {
  guard !viewModel.isEmpty else {
    return nil
  }
  let plannedGraph = viewModel.plannedReflowGraph(
    preserveManualAnchors: preserveManualAnchors,
    force: force
  )
  guard let routeGraph = plannedGraph ?? currentPolicyCanvasReflowGraph(viewModel),
    plannedGraph != nil || routesCurrentGraphWhenUnchanged
  else {
    return nil
  }
  let routeInput = PolicyCanvasRouteWorkerInput(
    graphGeneration: viewModel.routeComputationGeneration,
    nodes: routeGraph.nodes,
    groups: routeGraph.groups,
    edges: routeGraph.edges,
    fontScale: fontScale,
    routingHints: routeGraph.routingHints,
    precomputedRoutes: routeGraph.precomputedRoutes,
    algorithmSelection: viewModel.algorithmSelection
  )
  let output: PolicyCanvasRouteWorkerOutput
  if policyCanvasCanUseFastAtomicReflowRoutes(routeInput),
    let fastOutput = policyCanvasFastPrecomputedRouteOutput(input: routeInput)
  {
    output = fastOutput
  } else {
    output = await routeWorker.compute(input: routeInput)
  }
  return PolicyCanvasAtomicReflowRoutePlan(
    graph: routeGraph,
    appliesLayoutChange: plannedGraph != nil,
    output: output
  )
}

private func policyCanvasCanUseFastAtomicReflowRoutes(
  _ input: PolicyCanvasRouteWorkerInput
) -> Bool {
  input.precomputedRoutes != nil
    && (input.nodes.count >= 300 || input.edges.count >= 500)
}

@MainActor
private func currentPolicyCanvasReflowGraph(
  _ viewModel: PolicyCanvasViewModel
) -> PolicyCanvasReflowGraph? {
  guard !viewModel.nodes.isEmpty else {
    return nil
  }
  return PolicyCanvasReflowGraph(
    nodes: viewModel.nodes,
    groups: viewModel.groups,
    edges: viewModel.edges,
    routingHints: viewModel.routingHints,
    precomputedRoutes: viewModel.precomputedRoutes
  )
}
