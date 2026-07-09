import Foundation

extension PreviewHarnessClient {
  public func policyPipeline(
    canvasId _: String? = nil
  ) async throws -> PolicyPipelineDocument {
    PreviewFixtures.policyCanvasPipelineDocument()
  }

  public func savePolicyPipelineDraft(
    request: PolicyPipelineSaveDraftRequest
  ) async throws -> PolicyPipelineSaveDraftResponse {
    // Mirror the daemon: every draft save bumps the revision (see
    // `policy_graph/store.rs` - `current.max(sent).saturating_add(1)`). Echoing
    // the sent revision unchanged would let the save flow look correct in the
    // lab while the real round-trip re-trips the remote-change banner.
    var saved = request.document
    saved.revision += 1
    return PolicyPipelineSaveDraftResponse(
      document: saved,
      validation: PolicyPipelineValidation(isValid: true)
    )
  }

  public func simulatePolicyPipeline(
    request: PolicyPipelineSimulateRequest
  ) async throws -> PolicyPipelineSimulationResult {
    let document = request.document ?? PreviewFixtures.policyCanvasPipelineDocument()
    return PreviewFixtures.policyCanvasSimulation(for: document)
  }

  public func promotePolicyPipeline(
    request: PolicyPipelinePromoteRequest
  ) async throws -> PolicyPipelinePromoteResponse {
    PolicyPipelinePromoteResponse(
      document: PreviewFixtures.policyCanvasPipelineDocument(
        mode: .enforced,
        revision: request.revision
      ),
      traceId: "trace-preview-policy-promote-\(request.revision)"
    )
  }

  public func policyPipelineAudit(
    canvasId _: String? = nil
  ) async throws -> PolicyPipelineAuditSummary {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    return PreviewFixtures.policyCanvasAudit(for: document)
  }

  public func exportPolicyCanvas(
    request _: PolicyCanvasExportRequest
  ) async throws -> PolicyCanvasExportResponse {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    return PolicyCanvasExportResponse(
      canvasId: "preview-canvas-default",
      title: "Default",
      document: document
    )
  }

  public func importPolicyCanvas(
    request _: PolicyCanvasImportRequest
  ) async throws -> PolicyCanvasWorkspace {
    let canvases = try await policyCanvasWorkspace()
    return canvases
  }
}
