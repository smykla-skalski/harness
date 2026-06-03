import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  /// Build the first state for store-backed policy-canvas surfaces. Live
  /// windows must never boot from `.sample()`; they either render the current
  /// dashboard pipeline immediately or start empty until the first refresh
  /// arrives.
  @MainActor
  public static func liveStartupState(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    activeCanvasId: String? = nil,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .referenceRouting
  ) -> PolicyCanvasViewModel {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      algorithmSelection: algorithmSelection
    )
    viewModel.applyPersistedDocument(
      document: document,
      simulation: simulation,
      audit: audit,
      activeCanvasId: activeCanvasId
    )
    return viewModel
  }
}
