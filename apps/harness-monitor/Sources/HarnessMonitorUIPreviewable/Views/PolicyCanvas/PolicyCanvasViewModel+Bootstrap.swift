import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  /// Build the first state for store-backed policy-canvas surfaces. Live
  /// windows must never boot from `.sample()`; they either render the current
  /// dashboard pipeline immediately or start empty until the first refresh
  /// arrives.
  @MainActor
  public static func liveStartupState(
    document: PolicyPipelineDocument?,
    simulation: PolicyPipelineSimulationResult?,
    audit: PolicyPipelineAuditSummary?,
    activeCanvasId: String? = nil,
    workspace: PolicyCanvasWorkspace? = nil,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .referenceRouting,
    policyGroupTitle: String? = nil
  ) -> PolicyCanvasViewModel {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      algorithmSelection: algorithmSelection
    )
    viewModel.policyGroupTitle = policyGroupTitle
    viewModel.applyPersistedDocument(
      document: document,
      simulation: simulation,
      audit: audit,
      activeCanvasId: activeCanvasId,
      workspace: workspace
    )
    return viewModel
  }
}
