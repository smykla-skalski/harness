import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func taskBoardPolicyCanvasWorkspace() async throws -> TaskBoardPolicyCanvasWorkspace {
    recordReadCall(.taskBoardPolicyCanvasWorkspace)
    return lock.withLock {
      ensureTaskBoardPolicyWorkspaceStateLocked()
    }
  }

  func createTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      let canvasID = nextTaskBoardPolicyCanvasIDLocked()
      let resolvedTitle =
        title.flatMap { $0.isEmpty ? nil : $0 } ?? "Policy Canvas \(workspace.canvases.count + 1)"
      let document = sampleTaskBoardPolicyPipeline(
        canvasId: canvasID,
        title: resolvedTitle,
        revision: UInt64(workspace.canvases.count + 1)
      )
      let audit = sampleTaskBoardPolicyPipelineAudit(for: document)
      taskBoardPolicyPipelinesByCanvasID[canvasID] = document
      taskBoardPolicyAuditByCanvasID[canvasID] = audit
      workspace.activeCanvasId = canvasID
      workspace.canvases.append(
        taskBoardPolicyCanvasSummary(
          canvasId: canvasID,
          title: resolvedTitle,
          document: document,
          latestSimulation: audit.latestSimulation
        )
      )
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func duplicateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDuplicateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      let sourceCanvasID = request.canvasId
      let sourceDocument =
        taskBoardPolicyPipelinesByCanvasID[sourceCanvasID]
        ?? sampleTaskBoardPolicyPipeline(canvasId: sourceCanvasID, title: "Policy Canvas")
      let canvasID = nextTaskBoardPolicyCanvasIDLocked()
      let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "\(canvasID) Copy"
      let document = TaskBoardPolicyPipelineDocument(
        schemaVersion: sourceDocument.schemaVersion,
        revision: sourceDocument.revision,
        mode: sourceDocument.mode,
        nodes: sourceDocument.nodes,
        edges: sourceDocument.edges,
        groups: sourceDocument.groups,
        layout: sourceDocument.layout,
        policyTraceIds: ["trace-\(canvasID)"]
      )
      let audit = sampleTaskBoardPolicyPipelineAudit(for: document)
      taskBoardPolicyPipelinesByCanvasID[canvasID] = document
      taskBoardPolicyAuditByCanvasID[canvasID] = audit
      workspace.activeCanvasId = canvasID
      workspace.canvases.append(
        taskBoardPolicyCanvasSummary(
          canvasId: canvasID,
          title: resolvedTitle,
          document: document,
          latestSimulation: audit.latestSimulation
        )
      )
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func renameTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasRenameRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      if let index = workspace.canvases.firstIndex(where: { $0.canvasId == request.canvasId }) {
        workspace.canvases[index].title = title
      }
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func activateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasActivateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    return lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      workspace.activeCanvasId = request.canvasId
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func deleteTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    return lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      guard workspace.canvases.count > 1 else {
        return workspace
      }
      workspace.canvases.removeAll { $0.canvasId == request.canvasId }
      taskBoardPolicyPipelinesByCanvasID.removeValue(forKey: request.canvasId)
      taskBoardPolicyAuditByCanvasID.removeValue(forKey: request.canvasId)
      if workspace.activeCanvasId == request.canvasId,
        let nextActive = workspace.canvases.first
      {
        workspace.activeCanvasId = nextActive.canvasId
      }
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func toggleTaskBoardPolicyCanvasEnforcement(
    request _: TaskBoardPolicyCanvasToggleEnforcementRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    return lock.withLock {
      if let snapshot = taskBoardPolicyCanvasKillSwitchSnapshot {
        taskBoardPolicyCanvasKillSwitchSnapshot = nil
        var restored = snapshot
        restored.policyEnforcementKillSwitchActive = false
        taskBoardPolicyCanvasWorkspaceStorage = restored
        for canvas in restored.canvases {
          if let document = canvas.document {
            taskBoardPolicyPipelinesByCanvasID[canvas.canvasId] = document
          }
        }
        return restored
      }
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      guard workspace.canvases.contains(where: { $0.mode != .draft }) else {
        return workspace
      }
      taskBoardPolicyCanvasKillSwitchSnapshot = workspace
      for index in workspace.canvases.indices {
        guard var document = workspace.canvases[index].document, document.mode != .draft else {
          continue
        }
        document.mode = .draft
        document.revision += 1
        taskBoardPolicyPipelinesByCanvasID[workspace.canvases[index].canvasId] = document
        workspace.canvases[index].document = document
        workspace.canvases[index].mode = .draft
        workspace.canvases[index].revision = document.revision
      }
      workspace.policyEnforcementKillSwitchActive = true
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func taskBoardPolicyPipeline(
    canvasId: String? = nil
  ) async throws -> TaskBoardPolicyPipelineDocument {
    recordReadCall(.taskBoardPolicyPipeline)
    return lock.withLock {
      let workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      let resolvedCanvasID = canvasId ?? workspace.activeCanvasId
      return taskBoardPolicyPipelinesByCanvasID[resolvedCanvasID]
        ?? sampleTaskBoardPolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
    }
  }

  func saveTaskBoardPolicyPipelineDraft(
    request: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    lock.withLock {
      let workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      let canvasID = request.canvasId ?? workspace.activeCanvasId
      taskBoardPolicyPipelinesByCanvasID[canvasID] = request.document
      savedTaskBoardPolicyCanvasIDs.append(canvasID)
      updateTaskBoardPolicyCanvasSummaryLocked(
        canvasId: canvasID,
        title: nil,
        document: request.document,
        latestSimulation: taskBoardPolicyAuditByCanvasID[canvasID]?.latestSimulation
      )
    }
    calls.append(
      .saveTaskBoardPolicyPipelineDraft(
        revision: request.document.revision
      )
    )
    let validation =
      lock.withLock { taskBoardPolicyValidationOverride }
      ?? TaskBoardPolicyPipelineValidation(isValid: true)
    return TaskBoardPolicyPipelineSaveDraftResponse(
      document: request.document,
      validation: validation
    )
  }

  func simulateTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult {
    let resolvedCanvasID = lock.withLock {
      let workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      let canvasID = request.canvasId ?? workspace.activeCanvasId
      simulatedTaskBoardPolicyCanvasIDs.append(canvasID)
      return canvasID
    }
    calls.append(.simulateTaskBoardPolicyPipeline)
    let validation =
      lock.withLock { taskBoardPolicyValidationOverride }
      ?? TaskBoardPolicyPipelineValidation(isValid: true)
    let succeeded = lock.withLock { taskBoardPolicySimulationOverride } ?? true
    let document =
      lock.withLock {
        taskBoardPolicyPipelinesByCanvasID[resolvedCanvasID]
      }
      ?? request.document
      ?? sampleTaskBoardPolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
    let simulation = TaskBoardPolicyPipelineSimulationResult(
      revision: request.document?.revision ?? document.revision,
      traceId: "trace-policy-1",
      simulatedAt: "2026-05-14T11:00:05Z",
      succeeded: succeeded,
      validation: validation,
      decisions: [sampleTaskBoardPolicyDecision()]
    )
    lock.withLock {
      taskBoardPolicyAuditByCanvasID[resolvedCanvasID] = TaskBoardPolicyPipelineAuditSummary(
        activeRevision: document.revision,
        mode: document.mode,
        latestTraceId: simulation.traceId,
        latestSimulation: simulation,
        validation: validation
      )
      updateTaskBoardPolicyCanvasSummaryLocked(
        canvasId: resolvedCanvasID,
        title: nil,
        document: document,
        latestSimulation: simulation
      )
    }
    return simulation
  }

  func configureTaskBoardPolicyPipelineValidation(
    _ validation: TaskBoardPolicyPipelineValidation?
  ) {
    lock.withLock { taskBoardPolicyValidationOverride = validation }
  }

  func configureTaskBoardPolicyPipelineSimulationSucceeded(_ succeeded: Bool?) {
    lock.withLock { taskBoardPolicySimulationOverride = succeeded }
  }

  func promoteTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse {
    let resolvedCanvasID = lock.withLock {
      let workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      let canvasID = request.canvasId ?? workspace.activeCanvasId
      promotedTaskBoardPolicyCanvasIDs.append(canvasID)
      return canvasID
    }
    calls.append(
      .promoteTaskBoardPolicyPipeline(revision: request.revision)
    )
    let document =
      lock.withLock {
        var document =
          taskBoardPolicyPipelinesByCanvasID[resolvedCanvasID]
          ?? sampleTaskBoardPolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
        document.mode = .enforced
        document.revision = request.revision
        taskBoardPolicyPipelinesByCanvasID[resolvedCanvasID] = document
        updateTaskBoardPolicyCanvasSummaryLocked(
          canvasId: resolvedCanvasID,
          title: nil,
          document: document,
          latestSimulation: taskBoardPolicyAuditByCanvasID[resolvedCanvasID]?.latestSimulation
        )
        return document
      }
    return TaskBoardPolicyPipelinePromoteResponse(
      document: document,
      traceId: "trace-policy-2"
    )
  }

  func taskBoardPolicyPipelineAudit(
    canvasId: String? = nil
  ) async throws -> TaskBoardPolicyPipelineAuditSummary {
    recordReadCall(.taskBoardPolicyPipelineAudit)
    let state = lock.withLock {
      let workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      let resolvedCanvasID = canvasId ?? workspace.activeCanvasId
      let document =
        taskBoardPolicyPipelinesByCanvasID[resolvedCanvasID]
        ?? sampleTaskBoardPolicyPipeline(canvasId: resolvedCanvasID, title: resolvedCanvasID)
      return (resolvedCanvasID, document)
    }
    let simulation = try await simulateTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelineSimulateRequest(
        canvasId: state.0,
        document: state.1
      )
    )
    let validation =
      lock.withLock { taskBoardPolicyValidationOverride }
      ?? TaskBoardPolicyPipelineValidation(isValid: true)
    let audit = TaskBoardPolicyPipelineAuditSummary(
      activeRevision: state.1.revision,
      mode: state.1.mode,
      latestTraceId: simulation.traceId,
      latestSimulation: simulation,
      validation: validation
    )
    lock.withLock {
      taskBoardPolicyAuditByCanvasID[state.0] = audit
    }
    return audit
  }

  func configureTaskBoardPolicyCanvasWorkspace(
    workspace: TaskBoardPolicyCanvasWorkspace,
    documentsByCanvasID: [String: TaskBoardPolicyPipelineDocument],
    auditsByCanvasID: [String: TaskBoardPolicyPipelineAuditSummary] = [:]
  ) {
    lock.withLock {
      var hydratedWorkspace = workspace
      for index in hydratedWorkspace.canvases.indices {
        let canvasID = hydratedWorkspace.canvases[index].canvasId
        hydratedWorkspace.canvases[index].document = documentsByCanvasID[canvasID]
      }
      taskBoardPolicyCanvasWorkspaceStorage = hydratedWorkspace
      taskBoardPolicyPipelinesByCanvasID = documentsByCanvasID
      taskBoardPolicyAuditByCanvasID = auditsByCanvasID
      taskBoardPolicyCanvasIDCounter = workspace.canvases.count + 1
    }
  }

  func recordedSavedTaskBoardPolicyCanvasIDs() -> [String?] {
    lock.withLock { savedTaskBoardPolicyCanvasIDs }
  }

  func recordedSimulatedTaskBoardPolicyCanvasIDs() -> [String?] {
    lock.withLock { simulatedTaskBoardPolicyCanvasIDs }
  }

  func recordedPromotedTaskBoardPolicyCanvasIDs() -> [String?] {
    lock.withLock { promotedTaskBoardPolicyCanvasIDs }
  }
}
