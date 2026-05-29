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
    TaskBoardPolicyPipelineSaveDraftResponse(
      document: request.document,
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
}
