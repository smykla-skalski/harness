import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func sampleTaskBoardPolicyPipeline(
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
          kind: .trigger(workflow: "default-task"),
          position: TaskBoardPolicyCanvasPoint(x: 20, y: 40),
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-allow",
          title: "Allow spawn",
          kind: .actionGate(actions: [.spawnAgent]),
          position: TaskBoardPolicyCanvasPoint(x: 280, y: 40),
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-human",
          title: "Allow",
          kind: .humanGate(reasonCode: .humanRequired),
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

  func sampleTaskBoardPolicyDecision() -> TaskBoardPolicyPipelineSimulatedDecision {
    TaskBoardPolicyPipelineSimulatedDecision(
      action: .spawnAgent,
      decision: TaskBoardPolicyDecision(
        decision: "allow",
        reasonCode: "default_allow",
        policyVersion: "task-board-policy-v2:rev-7"
      )
    )
  }

  func sampleTaskBoardPolicyPipelineAudit(
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

  func taskBoardPolicyCanvasSummary(
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
      document: document,
      nodeCount: document.nodes.count,
      edgeCount: document.edges.count,
      groupCount: document.groups.count,
      latestSimulationTraceId: latestSimulation?.traceId,
      latestSimulationSucceeded: latestSimulation?.succeeded,
      latestSimulationAt: latestSimulation?.simulatedAt,
      updatedAt: "2026-05-14T11:00:05Z"
    )
  }

  func ensureTaskBoardPolicyWorkspaceStateLocked() -> TaskBoardPolicyCanvasWorkspace {
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

  func nextTaskBoardPolicyCanvasIDLocked() -> String {
    defer { taskBoardPolicyCanvasIDCounter += 1 }
    return "canvas-\(taskBoardPolicyCanvasIDCounter)"
  }

  func updateTaskBoardPolicyCanvasSummaryLocked(
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
