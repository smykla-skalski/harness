import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func samplePolicyPipeline(
    canvasId: String = "canvas-1",
    title: String = "Policy Canvas 1",
    mode: PolicyPipelineMode = .draft,
    revision: UInt64 = 7
  ) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: mode,
      nodes: [
        PolicyPipelineNode(
          id: "node-intake",
          title: title,
          kind: .trigger(workflow: "default-task"),
          position: PolicyCanvasPoint(x: 20, y: 40),
          outputs: [PolicyPipelinePort(id: "out", title: "out")]
        ),
        PolicyPipelineNode(
          id: "node-allow",
          title: "Allow spawn",
          kind: .actionGate(actions: [.spawnAgent]),
          position: PolicyCanvasPoint(x: 280, y: 40),
          inputs: [PolicyPipelinePort(id: "in", title: "in")],
          outputs: [PolicyPipelinePort(id: "out", title: "out")]
        ),
        PolicyPipelineNode(
          id: "node-human",
          title: "Allow",
          kind: .humanGate(reasonCode: .humanRequired),
          position: PolicyCanvasPoint(x: 520, y: 40),
          inputs: [PolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        PolicyPipelineEdge(
          id: "edge-intake-allow",
          fromNodeId: "node-intake",
          fromPort: "out",
          toNodeId: "node-allow",
          toPort: "in",
          label: "ready"
        )
      ],
      groups: [
        PolicyPipelineGroup(
          id: "group-dispatch",
          title: "Dispatch",
          color: "#6aa8ff",
          frame: PolicyCanvasRect(x: 0, y: 0, width: 720, height: 180)
        )
      ],
      layout: PolicyPipelineLayout(
        zoom: 1,
        offset: .zero
      ),
      policyTraceIds: ["trace-\(canvasId)"]
    )
  }

  func samplePolicySimulationDecision() -> PolicyPipelineSimulatedDecision {
    PolicyPipelineSimulatedDecision(
      action: .spawnAgent,
      decision: PolicySimulationDecision(
        decision: "allow",
        reasonCode: "default_allow",
        policyVersion: "task-board-policy-v2:rev-7"
      )
    )
  }

  func samplePolicyPipelineAudit(
    for document: PolicyPipelineDocument
  ) -> PolicyPipelineAuditSummary {
    let validation =
      policyValidationOverride
      ?? PolicyPipelineValidation(isValid: true)
    let succeeded = policySimulationOverride ?? true
    let simulation = PolicyPipelineSimulationResult(
      revision: document.revision,
      traceId: "trace-policy-1",
      simulatedAt: "2026-05-14T11:00:05Z",
      succeeded: succeeded,
      validation: validation,
      decisions: [samplePolicySimulationDecision()]
    )
    return PolicyPipelineAuditSummary(
      activeRevision: document.revision,
      mode: document.mode,
      latestTraceId: simulation.traceId,
      latestSimulation: simulation,
      validation: validation
    )
  }

  func policyCanvasSummary(
    canvasId: String,
    title: String,
    document: PolicyPipelineDocument,
    latestSimulation: PolicyPipelineSimulationResult?
  ) -> PolicyCanvasSummary {
    PolicyCanvasSummary(
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

  func ensurePolicyWorkspaceStateLocked() -> PolicyCanvasWorkspace {
    if let workspace = policyCanvasWorkspaceStorage {
      return workspace
    }
    let canvasID = "canvas-1"
    let title = "Policy Canvas 1"
    let document = samplePolicyPipeline(
      canvasId: canvasID,
      title: title,
      mode: .draft
    )
    let audit = samplePolicyPipelineAudit(for: document)
    let workspace = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: canvasID,
      canvases: [
        policyCanvasSummary(
          canvasId: canvasID,
          title: title,
          document: document,
          latestSimulation: audit.latestSimulation
        )
      ]
    )
    policyCanvasWorkspaceStorage = workspace
    policyPipelinesByCanvasID[canvasID] = document
    policyAuditByCanvasID[canvasID] = audit
    policyCanvasIDCounter = 2
    return workspace
  }

  func nextPolicyCanvasIDLocked() -> String {
    defer { policyCanvasIDCounter += 1 }
    return "canvas-\(policyCanvasIDCounter)"
  }

  func updatePolicyCanvasSummaryLocked(
    canvasId: String,
    title: String?,
    document: PolicyPipelineDocument,
    latestSimulation: PolicyPipelineSimulationResult?
  ) {
    guard var workspace = policyCanvasWorkspaceStorage,
      let index = workspace.canvases.firstIndex(where: { $0.canvasId == canvasId })
    else {
      return
    }
    let existingTitle = workspace.canvases[index].title
    workspace.canvases[index] = policyCanvasSummary(
      canvasId: canvasId,
      title: title ?? existingTitle,
      document: document,
      latestSimulation: latestSimulation
    )
    policyCanvasWorkspaceStorage = workspace
  }
}
