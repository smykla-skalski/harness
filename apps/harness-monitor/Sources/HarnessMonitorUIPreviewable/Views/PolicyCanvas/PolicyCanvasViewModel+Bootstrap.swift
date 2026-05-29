import HarnessMonitorKit

extension PolicyCanvasViewModel {
  /// Build the first state for store-backed policy-canvas surfaces. Live
  /// windows must never boot from `.sample()`; they either render the current
  /// dashboard pipeline immediately or start empty until the first refresh
  /// arrives.
  @MainActor
  static func liveStartupState(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    activeCanvasId: String? = nil
  ) -> PolicyCanvasViewModel {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.load(
      document: document,
      simulation: simulation,
      audit: audit,
      activeCanvasId: activeCanvasId
    )
    return viewModel
  }
}
