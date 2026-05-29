import HarnessMonitorKit

struct DashboardCanvasSnapshot: Equatable {
  let activeCanvasId: String?
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}
