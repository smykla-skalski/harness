import SwiftUI

@MainActor
func policyCanvasRouteWorkerKey(
  viewModel: PolicyCanvasViewModel,
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  fontScale: CGFloat
) -> PolicyCanvasRouteWorkerKey {
  PolicyCanvasRouteWorkerKey(
    graphGeneration: viewModel.routeComputationGeneration,
    nodeCount: nodes.count,
    groupCount: groups.count,
    edgeCount: edges.count,
    fontScale: fontScale,
    routingHints: viewModel.routingHints,
    algorithmSelection: viewModel.algorithmSelection
  )
}

@MainActor
func policyCanvasValidationWorkerKey(
  viewModel: PolicyCanvasViewModel,
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge]
) -> PolicyCanvasValidationWorkerKey {
  PolicyCanvasValidationWorkerKey(
    graphGeneration: viewModel.routeComputationGeneration,
    nodeCount: nodes.count,
    edgeCount: edges.count,
    groupCount: groups.count,
    simulationRevision: viewModel.latestSimulation?.revision,
    simulationIssueCount: viewModel.latestSimulation?.validation.issues.count ?? 0,
    simulationValid: viewModel.latestSimulation?.validation.isValid ?? true
  )
}

struct PolicyCanvasViewportHostedSnapshotInput {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  let edges: [PolicyCanvasEdge]
  let routeOutput: PolicyCanvasRouteWorkerOutput
  let nodeValidationIssueMessagesByID: [String: String]
  let resolvedCanvasColorScheme: ColorScheme?
  let showSimulationOverlay: Bool
  let openEditor: @MainActor (PolicyCanvasEditSheet) -> Void
  let requestKeyboardFocus: @MainActor () -> Void
}

func policyCanvasViewportHostedSnapshot(
  input: PolicyCanvasViewportHostedSnapshotInput
) -> PolicyCanvasViewportHostedSnapshot {
  PolicyCanvasViewportHostedSnapshot(
    viewModel: input.viewModel,
    focusedComponent: input.focusedComponent,
    edges: input.edges,
    routes: input.routeOutput.routes,
    labelPositions: input.routeOutput.labelPositions,
    accessibilityLabelsByEdgeID: input.routeOutput.accessibilityEdgeLabelsByID,
    accessibilityNodeEntries: input.routeOutput.accessibilityNodeEntries,
    accessibilityEdgeEntries: input.routeOutput.accessibilityEdgeEntries,
    nodeAccessibilityValuesByID: input.routeOutput.nodeAccessibilityValuesByID,
    connectTargetsByNodeID: input.routeOutput.connectTargetsByNodeID,
    nodeValidationIssueMessagesByID: input.nodeValidationIssueMessagesByID,
    portVisibility: input.routeOutput.portVisibility,
    portMarkerLayout: input.routeOutput.portMarkerLayout,
    routeSignature: input.routeOutput.signature,
    contentSize: input.routeOutput.contentSize,
    resolvedCanvasColorScheme: input.resolvedCanvasColorScheme,
    showSimulationOverlay: input.showSimulationOverlay,
    openEditor: input.openEditor,
    requestKeyboardFocus: input.requestKeyboardFocus
  )
}
