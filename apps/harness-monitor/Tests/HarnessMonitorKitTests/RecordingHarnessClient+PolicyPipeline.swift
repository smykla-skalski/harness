import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func policyCanvasWorkspace() async throws -> PolicyCanvasWorkspace {
    recordReadCall(.policyCanvasWorkspace)
    let workspaceError = lock.withLock { policyCanvasWorkspaceError }
    if let workspaceError {
      throw workspaceError
    }
    return lock.withLock {
      ensurePolicyWorkspaceStateLocked()
    }
  }

  func createPolicyCanvas(
    request: PolicyCanvasCreateRequest
  ) async throws -> PolicyCanvasWorkspace {
    let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      let canvasID = nextPolicyCanvasIDLocked()
      let resolvedTitle =
        title.flatMap { $0.isEmpty ? nil : $0 } ?? "Policy Canvas \(workspace.canvases.count + 1)"
      let document = samplePolicyPipeline(
        canvasId: canvasID,
        title: resolvedTitle,
        revision: UInt64(workspace.canvases.count + 1)
      )
      let audit = samplePolicyPipelineAudit(for: document)
      policyPipelinesByCanvasID[canvasID] = document
      policyAuditByCanvasID[canvasID] = audit
      workspace.activeCanvasId = canvasID
      workspace.canvases.append(
        policyCanvasSummary(
          canvasId: canvasID,
          title: resolvedTitle,
          document: document,
          latestSimulation: audit.latestSimulation
        )
      )
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func duplicatePolicyCanvas(
    request: PolicyCanvasDuplicateRequest
  ) async throws -> PolicyCanvasWorkspace {
    let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      let sourceCanvasID = request.canvasId
      let sourceDocument =
        policyPipelinesByCanvasID[sourceCanvasID]
        ?? samplePolicyPipeline(canvasId: sourceCanvasID, title: "Policy Canvas")
      let canvasID = nextPolicyCanvasIDLocked()
      let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "\(canvasID) Copy"
      let document = PolicyPipelineDocument(
        schemaVersion: sourceDocument.schemaVersion,
        revision: sourceDocument.revision,
        mode: sourceDocument.mode,
        nodes: sourceDocument.nodes,
        edges: sourceDocument.edges,
        groups: sourceDocument.groups,
        layout: sourceDocument.layout,
        policyTraceIds: ["trace-\(canvasID)"]
      )
      let audit = samplePolicyPipelineAudit(for: document)
      policyPipelinesByCanvasID[canvasID] = document
      policyAuditByCanvasID[canvasID] = audit
      workspace.activeCanvasId = canvasID
      workspace.canvases.append(
        policyCanvasSummary(
          canvasId: canvasID,
          title: resolvedTitle,
          document: document,
          latestSimulation: audit.latestSimulation
        )
      )
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func renamePolicyCanvas(
    request: PolicyCanvasRenameRequest
  ) async throws -> PolicyCanvasWorkspace {
    let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      if let index = workspace.canvases.firstIndex(where: { $0.canvasId == request.canvasId }) {
        workspace.canvases[index].title = title
      }
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func activatePolicyCanvas(
    request: PolicyCanvasActivateRequest
  ) async throws -> PolicyCanvasWorkspace {
    return lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      workspace.activeCanvasId = request.canvasId
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func deletePolicyCanvas(
    request: PolicyCanvasDeleteRequest
  ) async throws -> PolicyCanvasWorkspace {
    return lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      guard workspace.canvases.count > 1 else {
        return workspace
      }
      workspace.canvases.removeAll { $0.canvasId == request.canvasId }
      policyPipelinesByCanvasID.removeValue(forKey: request.canvasId)
      policyAuditByCanvasID.removeValue(forKey: request.canvasId)
      if workspace.activeCanvasId == request.canvasId,
        let nextActive = workspace.canvases.first
      {
        workspace.activeCanvasId = nextActive.canvasId
      }
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func setPolicyCanvasGlobalEnforcement(
    request: PolicyCanvasSetGlobalEnforcementRequest
  ) async throws -> PolicyCanvasWorkspace {
    return lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      workspace.globalPolicyEnforcementEnabled = request.enabled
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func policyPipeline(
    canvasId: String? = nil
  ) async throws -> PolicyPipelineDocument {
    recordReadCall(.policyPipeline)
    return lock.withLock {
      let workspace = ensurePolicyWorkspaceStateLocked()
      let resolvedCanvasID = canvasId ?? workspace.activeCanvasId
      return policyPipelinesByCanvasID[resolvedCanvasID]
        ?? samplePolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
    }
  }

  func savePolicyPipelineDraft(
    request: PolicyPipelineSaveDraftRequest
  ) async throws -> PolicyPipelineSaveDraftResponse {
    lock.withLock {
      _ = ensurePolicyWorkspaceStateLocked()
      let canvasID = request.canvasId
      policyPipelinesByCanvasID[canvasID] = request.document
      savedPolicyCanvasIDs.append(canvasID)
      updatePolicyCanvasSummaryLocked(
        canvasId: canvasID,
        title: nil,
        document: request.document,
        latestSimulation: policyAuditByCanvasID[canvasID]?.latestSimulation
      )
    }
    calls.append(
      .savePolicyPipelineDraft(
        revision: request.document.revision
      )
    )
    let validation =
      lock.withLock { policyValidationOverride }
      ?? PolicyPipelineValidation(isValid: true)
    return PolicyPipelineSaveDraftResponse(
      document: request.document,
      validation: validation
    )
  }

  func simulatePolicyPipeline(
    request: PolicyPipelineSimulateRequest
  ) async throws -> PolicyPipelineSimulationResult {
    let resolvedCanvasID = lock.withLock {
      let workspace = ensurePolicyWorkspaceStateLocked()
      let canvasID = request.canvasId ?? workspace.activeCanvasId
      simulatedPolicyCanvasIDs.append(canvasID)
      return canvasID
    }
    calls.append(.simulatePolicyPipeline)
    let validation =
      lock.withLock { policyValidationOverride }
      ?? PolicyPipelineValidation(isValid: true)
    let succeeded = lock.withLock { policySimulationOverride } ?? true
    let document =
      lock.withLock {
        policyPipelinesByCanvasID[resolvedCanvasID]
      }
      ?? request.document
      ?? samplePolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
    let simulation = PolicyPipelineSimulationResult(
      revision: request.document?.revision ?? document.revision,
      traceId: "trace-policy-1",
      simulatedAt: "2026-05-14T11:00:05Z",
      succeeded: succeeded,
      validation: validation,
      decisions: [samplePolicySimulationDecision()]
    )
    lock.withLock {
      policyAuditByCanvasID[resolvedCanvasID] = PolicyPipelineAuditSummary(
        activeRevision: document.revision,
        mode: document.mode,
        latestTraceId: simulation.traceId,
        latestSimulation: simulation,
        validation: validation
      )
      updatePolicyCanvasSummaryLocked(
        canvasId: resolvedCanvasID,
        title: nil,
        document: document,
        latestSimulation: simulation
      )
    }
    return simulation
  }

  func configurePolicyPipelineValidation(
    _ validation: PolicyPipelineValidation?
  ) {
    lock.withLock { policyValidationOverride = validation }
  }

  func configurePolicyPipelineSimulationSucceeded(_ succeeded: Bool?) {
    lock.withLock { policySimulationOverride = succeeded }
  }

  func promotePolicyPipeline(
    request: PolicyPipelinePromoteRequest
  ) async throws -> PolicyPipelinePromoteResponse {
    let resolvedCanvasID = lock.withLock {
      let workspace = ensurePolicyWorkspaceStateLocked()
      let canvasID = request.canvasId ?? workspace.activeCanvasId
      promotedPolicyCanvasIDs.append(canvasID)
      return canvasID
    }
    calls.append(
      .promotePolicyPipeline(revision: request.revision)
    )
    let document =
      lock.withLock {
        var document =
          policyPipelinesByCanvasID[resolvedCanvasID]
          ?? samplePolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
        document.mode = .enforced
        document.revision = request.revision
        policyPipelinesByCanvasID[resolvedCanvasID] = document
        updatePolicyCanvasSummaryLocked(
          canvasId: resolvedCanvasID,
          title: nil,
          document: document,
          latestSimulation: policyAuditByCanvasID[resolvedCanvasID]?.latestSimulation
        )
        return document
      }
    return PolicyPipelinePromoteResponse(
      document: document,
      traceId: "trace-policy-2"
    )
  }

  func makeLivePolicyPipeline(
    request: PolicyPipelineMakeLiveRequest
  ) async throws -> PolicyPipelineMakeLiveResponse {
    let resolvedCanvasID = lock.withLock {
      let workspace = ensurePolicyWorkspaceStateLocked()
      let canvasID = request.canvasId ?? workspace.activeCanvasId
      promotedPolicyCanvasIDs.append(canvasID)
      return canvasID
    }
    calls.append(
      .makeLivePolicyPipeline(revision: request.revision)
    )
    return lock.withLock {
      var document =
        policyPipelinesByCanvasID[resolvedCanvasID]
        ?? samplePolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
      document.mode = .enforced
      document.revision = request.revision
      policyPipelinesByCanvasID[resolvedCanvasID] = document
      updatePolicyCanvasSummaryLocked(
        canvasId: resolvedCanvasID,
        title: nil,
        document: document,
        latestSimulation: policyAuditByCanvasID[resolvedCanvasID]?.latestSimulation
      )
      var workspace = ensurePolicyWorkspaceStateLocked()
      workspace.globalPolicyEnforcementEnabled = true
      policyCanvasWorkspaceStorage = workspace
      return PolicyPipelineMakeLiveResponse(
        document: document,
        traceId: "trace-policy-make-live",
        globalPolicyEnforcementEnabled: true,
        workspace: workspace
      )
    }
  }

  func goLiveDiffPolicyPipeline(
    request: PolicyPipelineGoLiveDiffRequest
  ) async throws -> PolicyPipelineGoLiveDiff {
    PolicyPipelineGoLiveDiff(hasLivePolicy: false, changedCount: 0, diffs: [])
  }

  func replayPolicyPipeline(
    request: PolicyPipelineReplayRequest
  ) async throws -> PolicyPipelineReplayResult {
    PolicyPipelineReplayResult(sampleSize: 0, changedCount: 0, decisions: [])
  }

  func policyPipelineAudit(
    canvasId: String? = nil
  ) async throws -> PolicyPipelineAuditSummary {
    recordReadCall(.policyPipelineAudit)
    let state = lock.withLock {
      let workspace = ensurePolicyWorkspaceStateLocked()
      let resolvedCanvasID = canvasId ?? workspace.activeCanvasId
      let document =
        policyPipelinesByCanvasID[resolvedCanvasID]
        ?? samplePolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
      return (resolvedCanvasID, document)
    }
    let simulation = try await simulatePolicyPipeline(
      request: PolicyPipelineSimulateRequest(
        canvasId: state.0,
        document: state.1
      )
    )
    let validation =
      lock.withLock { policyValidationOverride }
      ?? PolicyPipelineValidation(isValid: true)
    let audit = PolicyPipelineAuditSummary(
      activeRevision: state.1.revision,
      mode: state.1.mode,
      latestTraceId: simulation.traceId,
      latestSimulation: simulation,
      validation: validation
    )
    lock.withLock {
      policyAuditByCanvasID[state.0] = audit
    }
    return audit
  }

  func configurePolicyCanvasWorkspace(
    workspace: PolicyCanvasWorkspace,
    documentsByCanvasID: [String: PolicyPipelineDocument],
    auditsByCanvasID: [String: PolicyPipelineAuditSummary] = [:]
  ) {
    lock.withLock {
      var hydratedWorkspace = workspace
      for index in hydratedWorkspace.canvases.indices {
        let canvasID = hydratedWorkspace.canvases[index].canvasId
        hydratedWorkspace.canvases[index].document = documentsByCanvasID[canvasID]
      }
      policyCanvasWorkspaceStorage = hydratedWorkspace
      policyPipelinesByCanvasID = documentsByCanvasID
      policyAuditByCanvasID = auditsByCanvasID
      policyCanvasIDCounter = workspace.canvases.count + 1
    }
  }

  func recordedSavedPolicyCanvasIDs() -> [String?] {
    lock.withLock { savedPolicyCanvasIDs }
  }

  func recordedSimulatedPolicyCanvasIDs() -> [String?] {
    lock.withLock { simulatedPolicyCanvasIDs }
  }

  func recordedPromotedPolicyCanvasIDs() -> [String?] {
    lock.withLock { promotedPolicyCanvasIDs }
  }
}
