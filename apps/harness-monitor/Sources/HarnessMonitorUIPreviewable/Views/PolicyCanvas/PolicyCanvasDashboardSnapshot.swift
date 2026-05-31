import HarnessMonitorKit

struct DashboardCanvasSnapshot: Equatable {
  let activeCanvasId: String?
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}

struct DashboardPolicyCanvasSelectionPreview: Equatable {
  let snapshot: DashboardCanvasSnapshot
  let showsLoadingPlaceholder: Bool

  init?(
    workspace: TaskBoardPolicyCanvasWorkspace?,
    selectedCanvasId: String?
  ) {
    guard let workspace,
      let selectedCanvasId,
      selectedCanvasId != workspace.activeCanvasId,
      let canvas = workspace.canvases.first(where: { $0.canvasId == selectedCanvasId })
    else {
      return nil
    }
    snapshot = DashboardCanvasSnapshot(
      activeCanvasId: canvas.canvasId,
      document: canvas.document,
      simulation: nil,
      audit: nil
    )
    showsLoadingPlaceholder = canvas.document == nil
  }
}
