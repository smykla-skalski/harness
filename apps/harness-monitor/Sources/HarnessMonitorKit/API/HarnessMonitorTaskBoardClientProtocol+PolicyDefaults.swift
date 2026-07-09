import Foundation

// Default policy implementations for clients without policy-canvas support. Conformers
// that do not speak the policy subtree (preview/null clients) inherit a uniform
// 501 throw; the HTTP and websocket transports override every method. Split out of
// `HarnessMonitorTaskBoardClientProtocol.swift` to keep both files under the cap.
extension HarnessMonitorTaskBoardClientProtocol {
  public func createPolicyScenario(
    request _: PolicyScenarioCreateRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func updatePolicyScenario(
    request _: PolicyScenarioUpdateRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func deletePolicyScenario(
    request _: PolicyScenarioDeleteRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func resetPolicyScenarios(
    request _: PolicyScenarioResetRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func policyPipeline() async throws -> PolicyPipelineDocument {
    try await policyPipeline(canvasId: nil)
  }

  public func policyPipeline(canvasId _: String?) async throws
    -> PolicyPipelineDocument
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func savePolicyPipelineDraft(
    request _: PolicyPipelineSaveDraftRequest
  ) async throws -> PolicyPipelineSaveDraftResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func simulatePolicyPipeline(
    request _: PolicyPipelineSimulateRequest
  ) async throws -> PolicyPipelineSimulationResult {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func promotePolicyPipeline(
    request _: PolicyPipelinePromoteRequest
  ) async throws -> PolicyPipelinePromoteResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func makeLivePolicyPipeline(
    request _: PolicyPipelineMakeLiveRequest
  ) async throws -> PolicyPipelineMakeLiveResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func goLiveDiffPolicyPipeline(
    request _: PolicyPipelineGoLiveDiffRequest
  ) async throws -> PolicyPipelineGoLiveDiff {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func replayPolicyPipeline(
    request _: PolicyPipelineReplayRequest
  ) async throws -> PolicyPipelineReplayResult {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func policyPipelineAudit() async throws -> PolicyPipelineAuditSummary {
    try await policyPipelineAudit(canvasId: nil)
  }

  public func policyPipelineAudit(canvasId _: String?) async throws
    -> PolicyPipelineAuditSummary
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func exportPolicyCanvas(
    request _: PolicyCanvasExportRequest
  ) async throws -> PolicyCanvasExportResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func importPolicyCanvas(
    request _: PolicyCanvasImportRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }
}
