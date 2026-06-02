import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

@MainActor
func policyCanvasPortVisibility(
  viewModel: PolicyCanvasViewModel,
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute]
) -> PolicyCanvasPortVisibilityMap {
  policyCanvasPortVisibility(
    edges: edges,
    routes: routes,
    anchorCandidates: { viewModel.portAnchorCandidates(for: $0) }
  )
}
