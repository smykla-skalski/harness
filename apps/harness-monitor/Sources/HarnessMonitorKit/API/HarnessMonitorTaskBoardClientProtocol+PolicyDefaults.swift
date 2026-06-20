import Foundation

// Default policy implementations for the task-board client protocol. Conformers
// that do not speak the policy subtree (preview/null clients) inherit a uniform
// 501 throw; the HTTP and websocket transports override every method. Split out of
// `HarnessMonitorTaskBoardClientProtocol.swift` to keep both files under the cap.
extension HarnessMonitorTaskBoardClientProtocol {
  public func createTaskBoardPolicyScenario(
    request _: TaskBoardPolicyScenarioCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func updateTaskBoardPolicyScenario(
    request _: TaskBoardPolicyScenarioUpdateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func deleteTaskBoardPolicyScenario(
    request _: TaskBoardPolicyScenarioDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func resetTaskBoardPolicyScenarios(
    request _: TaskBoardPolicyScenarioResetRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func taskBoardPolicyPipeline() async throws -> TaskBoardPolicyPipelineDocument {
    try await taskBoardPolicyPipeline(canvasId: nil)
  }

  public func taskBoardPolicyPipeline(canvasId _: String?) async throws
    -> TaskBoardPolicyPipelineDocument
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func saveTaskBoardPolicyPipelineDraft(
    request _: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func simulateTaskBoardPolicyPipeline(
    request _: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func promoteTaskBoardPolicyPipeline(
    request _: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func makeLiveTaskBoardPolicyPipeline(
    request _: TaskBoardPolicyPipelineMakeLiveRequest
  ) async throws -> TaskBoardPolicyPipelineMakeLiveResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func goLiveDiffTaskBoardPolicyPipeline(
    request _: TaskBoardPolicyPipelineGoLiveDiffRequest
  ) async throws -> TaskBoardPolicyPipelineGoLiveDiff {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func replayTaskBoardPolicyPipeline(
    request _: TaskBoardPolicyPipelineReplayRequest
  ) async throws -> TaskBoardPolicyPipelineReplayResult {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func taskBoardPolicyPipelineAudit() async throws -> TaskBoardPolicyPipelineAuditSummary {
    try await taskBoardPolicyPipelineAudit(canvasId: nil)
  }

  public func taskBoardPolicyPipelineAudit(canvasId _: String?) async throws
    -> TaskBoardPolicyPipelineAuditSummary
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func exportTaskBoardPolicy(
    request _: TaskBoardPolicyExportRequest
  ) async throws -> TaskBoardPolicyExportResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func importTaskBoardPolicy(
    request _: TaskBoardPolicyImportRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }
}
