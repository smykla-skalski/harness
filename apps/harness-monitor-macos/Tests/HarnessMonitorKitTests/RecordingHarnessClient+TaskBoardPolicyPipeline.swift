import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func taskBoardPolicyPipeline() async throws -> TaskBoardPolicyPipelineDocument {
    recordReadCall(.taskBoardPolicyPipeline)
    return sampleTaskBoardPolicyPipeline(mode: .draft)
  }

  func saveTaskBoardPolicyPipelineDraft(
    request: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    calls.append(
      .saveTaskBoardPolicyPipelineDraft(
        revision: request.document.revision
      )
    )
    let validation = lock.withLock { taskBoardPolicyPipelineValidationOverride }
      ?? TaskBoardPolicyPipelineValidation(isValid: true)
    return TaskBoardPolicyPipelineSaveDraftResponse(
      document: request.document,
      validation: validation
    )
  }

  func simulateTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult {
    calls.append(.simulateTaskBoardPolicyPipeline)
    let validation = lock.withLock { taskBoardPolicyPipelineValidationOverride }
      ?? TaskBoardPolicyPipelineValidation(isValid: true)
    let succeeded = lock.withLock { taskBoardPolicyPipelineSimulationSucceededOverride } ?? true
    return TaskBoardPolicyPipelineSimulationResult(
      revision: request.document?.revision ?? 7,
      traceId: "trace-policy-1",
      simulatedAt: "2026-05-14T11:00:05Z",
      succeeded: succeeded,
      validation: validation,
      decisions: [sampleTaskBoardPolicyDecision()]
    )
  }

  func configureTaskBoardPolicyPipelineValidation(
    _ validation: TaskBoardPolicyPipelineValidation?
  ) {
    lock.withLock { taskBoardPolicyPipelineValidationOverride = validation }
  }

  func configureTaskBoardPolicyPipelineSimulationSucceeded(_ succeeded: Bool?) {
    lock.withLock { taskBoardPolicyPipelineSimulationSucceededOverride = succeeded }
  }

  func promoteTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse {
    calls.append(
      .promoteTaskBoardPolicyPipeline(revision: request.revision)
    )
    return TaskBoardPolicyPipelinePromoteResponse(
      document: sampleTaskBoardPolicyPipeline(mode: .enforced, revision: request.revision),
      traceId: "trace-policy-2"
    )
  }

  func taskBoardPolicyPipelineAudit() async throws -> TaskBoardPolicyPipelineAuditSummary {
    recordReadCall(.taskBoardPolicyPipelineAudit)
    return TaskBoardPolicyPipelineAuditSummary(
      activeRevision: 7,
      mode: .draft,
      latestTraceId: "trace-policy-1",
      latestSimulation: try await simulateTaskBoardPolicyPipeline(
        request: TaskBoardPolicyPipelineSimulateRequest()
      ),
      validation: TaskBoardPolicyPipelineValidation(isValid: true)
    )
  }

  private func sampleTaskBoardPolicyPipeline(
    mode: TaskBoardPolicyPipelineMode,
    revision: UInt64 = 7
  ) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: mode,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-intake",
          title: "Ready for dispatch",
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
      policyTraceIds: ["trace-policy-1"]
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
}
