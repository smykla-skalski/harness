import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

public struct PolicyCanvasHostSnapshot: Equatable {
  public let activeCanvasId: String?
  public let document: PolicyPipelineDocument?
  public let simulation: PolicyPipelineSimulationResult?
  public let audit: PolicyPipelineAuditSummary?
  public let workspace: PolicyCanvasWorkspace?

  public init(
    activeCanvasId: String?,
    document: PolicyPipelineDocument?,
    simulation: PolicyPipelineSimulationResult?,
    audit: PolicyPipelineAuditSummary?,
    workspace: PolicyCanvasWorkspace? = nil
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
    workspace: PolicyCanvasWorkspace?,
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
