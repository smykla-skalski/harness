import Foundation

extension PreviewHarnessClient {
  public func taskBoardPolicyPipeline(
    canvasId _: String? = nil
  ) async throws -> TaskBoardPolicyPipelineDocument {
    PreviewFixtures.policyCanvasPipelineDocument()
  }

  public func saveTaskBoardPolicyPipelineDraft(
    request: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    // Mirror the daemon: every draft save bumps the revision (see
    // `policy_graph/store.rs` - `current.max(sent).saturating_add(1)`). Echoing
    // the sent revision unchanged would let the save flow look correct in the
    // lab while the real round-trip re-trips the remote-change banner.
    var saved = request.document
    saved.revision += 1
    return TaskBoardPolicyPipelineSaveDraftResponse(
      document: saved,
      validation: TaskBoardPolicyPipelineValidation(isValid: true)
    )
  }

  public func simulateTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult {
    let document = request.document ?? PreviewFixtures.policyCanvasPipelineDocument()
    return PreviewFixtures.policyCanvasSimulation(for: document)
  }

  public func promoteTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse {
    TaskBoardPolicyPipelinePromoteResponse(
      document: PreviewFixtures.policyCanvasPipelineDocument(
        mode: .enforced,
        revision: request.revision
      ),
      traceId: "trace-preview-policy-promote-\(request.revision)"
    )
  }

  public func taskBoardPolicyPipelineAudit(
    canvasId _: String? = nil
  ) async throws -> TaskBoardPolicyPipelineAuditSummary {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    return PreviewFixtures.policyCanvasAudit(for: document)
  }

  public func exportTaskBoardPolicy(
    request _: TaskBoardPolicyExportRequest
  ) async throws -> TaskBoardPolicyExportResponse {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    return TaskBoardPolicyExportResponse(
      canvasId: "preview-canvas-default",
      title: "Default",
      document: document
    )
  }

  public func importTaskBoardPolicy(
    request _: TaskBoardPolicyImportRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let canvases = try await taskBoardPolicyCanvasWorkspace()
    return canvases
  }
}
