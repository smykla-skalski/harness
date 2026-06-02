import HarnessMonitorKit

public struct PolicyCanvasHostSnapshot: Equatable {
  public let activeCanvasId: String?
  public let document: TaskBoardPolicyPipelineDocument?
  public let simulation: TaskBoardPolicyPipelineSimulationResult?
  public let audit: TaskBoardPolicyPipelineAuditSummary?
  public let workspace: TaskBoardPolicyCanvasWorkspace?

  public init(
    activeCanvasId: String?,
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    workspace: TaskBoardPolicyCanvasWorkspace? = nil
  ) {
    self.activeCanvasId = activeCanvasId
    self.document = document
    self.simulation = simulation
    self.audit = audit
    self.workspace = workspace
  }
}

typealias DashboardCanvasSnapshot = PolicyCanvasHostSnapshot

public struct DashboardPolicyCanvasSelectionPreview: Equatable {
  public let snapshot: PolicyCanvasHostSnapshot
  public let showsLoadingPlaceholder: Bool

  public init?(
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
      audit: nil,
      workspace: workspace
    )
    showsLoadingPlaceholder = canvas.document == nil
  }
}
