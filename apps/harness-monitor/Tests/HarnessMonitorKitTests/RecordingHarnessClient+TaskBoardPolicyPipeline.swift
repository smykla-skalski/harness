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
      let resolvedTitle = title?.isEmpty == false ? title! : "Policy Canvas \(workspace.canvases.count + 1)"
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
      let resolvedTitle = title?.isEmpty == false ? title! : "\(canvasID) Copy"
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
      taskBoardPolicyCanvasWorkspaceStorage = workspace
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

  private func sampleTaskBoardPolicyPipeline(
    canvasId: String = "canvas-1",
    title: String = "Policy Canvas 1",
    mode: TaskBoardPolicyPipelineMode = .draft,
    revision: UInt64 = 7
  ) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: mode,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-intake",
          title: title,
          kind: TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task"),
          position: TaskBoardPolicyCanvasPoint(x: 20, y: 40),
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-allow",
          title: "Allow spawn",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", action: .spawnAgent),
          position: TaskBoardPolicyCanvasPoint(x: 280, y: 40),
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-human",
          title: "Allow",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
          position: TaskBoardPolicyCanvasPoint(x: 520, y: 40),
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge-intake-allow",
          fromNodeId: "node-intake",
          fromPort: "out",
          toNodeId: "node-allow",
          toPort: "in",
          label: "ready"
        )
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "group-dispatch",
          title: "Dispatch",
          color: "#6aa8ff",
          frame: TaskBoardPolicyCanvasRect(x: 0, y: 0, width: 720, height: 180)
        )
      ],
      layout: TaskBoardPolicyPipelineLayout(
        zoom: 1,
        offset: .zero
      ),
      policyTraceIds: ["trace-\(canvasId)"]
    )
  }

  private func sampleTaskBoardPolicyDecision() -> TaskBoardPolicyPipelineSimulatedDecision {
    TaskBoardPolicyPipelineSimulatedDecision(
      action: .spawnAgent,
      decision: TaskBoardPolicyDecision(
        decision: "allow",
        reasonCode: "default_allow",
        policyVersion: "task-board-policy-v2:rev-7"
      )
    )
  }

  private func sampleTaskBoardPolicyPipelineAudit(
    for document: TaskBoardPolicyPipelineDocument
  ) -> TaskBoardPolicyPipelineAuditSummary {
    let validation =
    taskBoardPolicyValidationOverride
    ?? TaskBoardPolicyPipelineValidation(isValid: true)
    let succeeded = taskBoardPolicySimulationOverride ?? true
    let simulation = TaskBoardPolicyPipelineSimulationResult(
    revision: document.revision,
    traceId: "trace-policy-1",
    simulatedAt: "2026-05-14T11:00:05Z",
    succeeded: succeeded,
    validation: validation,
    decisions: [sampleTaskBoardPolicyDecision()]
    )
    return TaskBoardPolicyPipelineAuditSummary(
    activeRevision: document.revision,
    mode: document.mode,
    latestTraceId: simulation.traceId,
    latestSimulation: simulation,
    validation: validation
    )
  }

  private func taskBoardPolicyCanvasSummary(
    canvasId: String,
    title: String,
    document: TaskBoardPolicyPipelineDocument,
    latestSimulation: TaskBoardPolicyPipelineSimulationResult?
  ) -> TaskBoardPolicyCanvasSummary {
    TaskBoardPolicyCanvasSummary(
    canvasId: canvasId,
    title: title,
    revision: document.revision,
    mode: document.mode,
    nodeCount: document.nodes.count,
    edgeCount: document.edges.count,
    groupCount: document.groups.count,
    latestSimulationTraceId: latestSimulation?.traceId,
    latestSimulationSucceeded: latestSimulation?.succeeded,
    latestSimulationAt: latestSimulation?.simulatedAt,
    updatedAt: "2026-05-14T11:00:05Z"
    )
  }

  private func ensureTaskBoardPolicyWorkspaceStateLocked() -> TaskBoardPolicyCanvasWorkspace {
    if let workspace = taskBoardPolicyCanvasWorkspaceStorage {
    return workspace
    }
    let canvasID = "canvas-1"
    let title = "Policy Canvas 1"
    let document = sampleTaskBoardPolicyPipeline(
    canvasId: canvasID,
    title: title,
    mode: .draft
    )
    let audit = sampleTaskBoardPolicyPipelineAudit(for: document)
    let workspace = TaskBoardPolicyCanvasWorkspace(
    schemaVersion: 1,
    activeCanvasId: canvasID,
    canvases: [
      taskBoardPolicyCanvasSummary(
        canvasId: canvasID,
        title: title,
        document: document,
        latestSimulation: audit.latestSimulation
      )
    ]
    )
    taskBoardPolicyCanvasWorkspaceStorage = workspace
    taskBoardPolicyPipelinesByCanvasID[canvasID] = document
    taskBoardPolicyAuditByCanvasID[canvasID] = audit
    taskBoardPolicyCanvasIDCounter = 2
    return workspace
  }

  private func nextTaskBoardPolicyCanvasIDLocked() -> String {
    defer { taskBoardPolicyCanvasIDCounter += 1 }
    return "canvas-\(taskBoardPolicyCanvasIDCounter)"
  }

  private func updateTaskBoardPolicyCanvasSummaryLocked(
    canvasId: String,
    title: String?,
    document: TaskBoardPolicyPipelineDocument,
    latestSimulation: TaskBoardPolicyPipelineSimulationResult?
  ) {
    guard var workspace = taskBoardPolicyCanvasWorkspaceStorage,
    let index = workspace.canvases.firstIndex(where: { $0.canvasId == canvasId })
    else {
    return
    }
    let existingTitle = workspace.canvases[index].title
    workspace.canvases[index] = taskBoardPolicyCanvasSummary(
    canvasId: canvasId,
    title: title ?? existingTitle,
    document: document,
    latestSimulation: latestSimulation
    )
    taskBoardPolicyCanvasWorkspaceStorage = workspace
  }
}
