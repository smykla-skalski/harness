import Foundation

// Map the generated task-board item wire graph to the rich hand models. The *Wire
// types own the faithful daemon snake_case decode through the plain decoder; these
// extensions adapt them to the app's renamed shape. TaskBoardItem.workflow stays
// optional - the wire field is optional too (the daemon omits it when default,
// `skip_serializing_if = "TaskBoardWorkflowState::is_default"`), so the
// present-vs-absent distinction survives the mapping. Provider provenance and
// external-ref sync state also survive because app behavior relies on both.

extension TaskBoardExternalRefProvider {
  public init(wire: ExternalRefProviderWire) {
    self =
      switch wire {
      case .gitHub: .gitHub
      case .todoist: .todoist
      }
  }
}

extension TaskBoardExternalRefSyncState {
  public init(wire: ExternalRefSyncStateWire) {
    self.init(status: wire.status)
  }
}

extension TaskBoardExternalRef {
  public init(wire: ExternalRefWire) {
    self.init(
      provider: TaskBoardExternalRefProvider(wire: wire.provider),
      externalId: wire.externalId,
      url: wire.url,
      syncState: wire.syncState.map(TaskBoardExternalRefSyncState.init(wire:))
    )
  }
}

extension TaskBoardPlanningState {
  public init(wire: PlanningStateWire) {
    self.init(summary: wire.summary, approvedBy: wire.approvedBy, approvedAt: wire.approvedAt)
  }
}

extension TaskBoardWorkflowState {
  public init(wire: TaskBoardWorkflowStateWire) {
    let status: TaskBoardWorkflowStatus =
      switch wire.status {
      case .idle: .idle
      case .running: .running
      case .paused: .paused
      case .completed: .completed
      case .failed: .failed
      case .cancelled: .cancelled
      }
    self.init(
      executionId: wire.executionId,
      status: status,
      currentStepId: wire.currentStepId,
      attempts: wire.attempts,
      branch: wire.branch,
      worktree: wire.worktree,
      prNumber: wire.prNumber,
      prUrl: wire.prUrl,
      lastError: wire.lastError,
      policyTraceIds: wire.policyTraceIds
    )
  }
}

extension TaskBoardUsage {
  public init(wire: TaskUsageWire) {
    self.init(inputTokens: wire.inputTokens, outputTokens: wire.outputTokens, costUsd: wire.costUsd)
  }
}

extension TaskBoardItem {
  public init(wire: TaskBoardItemWire) {
    self.init(
      schemaVersion: wire.schemaVersion,
      id: wire.id,
      title: wire.title,
      body: wire.body,
      status: wire.status,
      priority: wire.priority,
      tags: wire.tags,
      projectId: wire.projectId,
      executionRepository: wire.executionRepository,
      targetProjectTypes: wire.targetProjectTypes,
      agentMode: wire.agentMode,
      kind: wire.kind,
      externalRefs: wire.externalRefs.map(TaskBoardExternalRef.init(wire:)),
      importedFromProvider: wire.importedFromProvider.map(TaskBoardExternalRefProvider.init(wire:)),
      planning: TaskBoardPlanningState(wire: wire.planning),
      workflow: wire.workflow.map(TaskBoardWorkflowState.init(wire:)),
      sessionId: wire.sessionId,
      workItemId: wire.workItemId,
      usage: TaskBoardUsage(wire: wire.usage),
      createdAt: wire.createdAt,
      updatedAt: wire.updatedAt,
      deletedAt: wire.deletedAt
    )
  }
}
