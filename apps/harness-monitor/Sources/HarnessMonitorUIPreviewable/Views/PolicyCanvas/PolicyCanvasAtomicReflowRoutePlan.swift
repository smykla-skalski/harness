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
  // One route path for every policy size. A separate large-graph shortcut used to
  // skip the route worker's repair and marker passes for speed, but it drew port
  // markers from the crossing-minimal optimized anchor while the canvas positions
  // each dot at the declaration-order anchor - so on reordered gate nodes the dots
  // desynced and rendered outside the card. The single `compute` path keeps the
  // declaration-order marker layout that the canvas actually draws, so no size
  // threshold can reintroduce that divergence.
  let output = await routeWorker.compute(input: routeInput)
  return PolicyCanvasAtomicReflowRoutePlan(
    graph: routeGraph,
    appliesLayoutChange: plannedGraph != nil,
    output: output
  )
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
