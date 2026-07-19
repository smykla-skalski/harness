import Foundation

// Wire maps for the orchestrator settings + status tree. The settings reuse the GitHubProjectConfig
// sub-tree map and the two inbox configs; the status reuses the sync/audit/dispatch/evaluation
// summary maps. enabledWorkflows/dispatchStatusFilter and the tick-phase/run-status enums ride bare
// (decoder-agnostic), so they carry across without a per-value map.

extension TaskBoardGitHubInboxConfig {
  init(wire: TaskBoardGitHubInboxConfigWire) {
    self.init(repositories: wire.repositories, labelFilter: wire.labelFilter)
  }
}

extension TaskBoardTodoistInboxConfig {
  init(wire: TaskBoardTodoistInboxConfigWire) {
    self.init(projectFilter: wire.projectFilter)
  }
}

extension TaskBoardOrchestratorSettings {
  init(wire: TaskBoardOrchestratorSettingsWire) {
    self.init(
      stepMode: wire.stepMode,
      enabledWorkflows: wire.enabledWorkflows,
      dryRunDefault: wire.dryRunDefault,
      dispatchStatusFilter: wire.dispatchStatusFilter,
      projectDir: wire.projectDir,
      githubProject: TaskBoardGitHubProjectConfig(wire: wire.githubProject),
      githubInbox: TaskBoardGitHubInboxConfig(wire: wire.githubInbox),
      todoistInbox: TaskBoardTodoistInboxConfig(wire: wire.todoistInbox),
      scheduling: wire.scheduling,
      retry: wire.retry,
      reviewers: wire.reviewers,
      policyVersion: wire.policyVersion
    )
  }
}

extension TaskBoardOrchestratorTickInfo {
  init(wire: TaskBoardOrchestratorTickInfoWire) {
    self.init(
      runId: wire.runId,
      phase: wire.phase,
      startedAt: wire.startedAt,
      completedAt: wire.completedAt,
      dryRun: wire.dryRun
    )
  }
}

extension TaskBoardOrchestratorRunSummary {
  init(wire: TaskBoardOrchestratorRunSummaryWire) {
    self.init(
      runId: wire.runId,
      startedAt: wire.startedAt,
      completedAt: wire.completedAt,
      status: wire.status,
      dryRun: wire.dryRun,
      sync: TaskBoardSyncSummary(wire: wire.sync),
      audit: TaskBoardAuditSummary(wire: wire.audit),
      dispatch: wire.dispatch.map(TaskBoardDispatchSummary.init(wire:)),
      evaluation: wire.evaluation.map(TaskBoardEvaluationSummary.init(wire:)),
      error: wire.error,
      policyTraceIds: wire.policyTraceIds
    )
  }
}

extension TaskBoardWorkflowExecutionCount {
  init(wire: TaskBoardWorkflowExecutionCountWire) {
    self.init(status: TaskBoardWorkflowStatus(wire: wire.status), count: Int(wire.count))
  }
}

extension TaskBoardOrchestratorStatus {
  init(wire: TaskBoardOrchestratorStatusWire) {
    self.init(
      enabled: wire.enabled,
      running: wire.running,
      stepMode: wire.stepMode,
      heldDispatches: wire.heldDispatches,
      currentTick: wire.currentTick.map(TaskBoardOrchestratorTickInfo.init(wire:)),
      lastRun: wire.lastRun.map(TaskBoardOrchestratorRunSummary.init(wire:)),
      workflowExecutionCounts: wire.workflowExecutionCounts
        .map(TaskBoardWorkflowExecutionCount.init(wire:)),
      automation: wire.automation,
      settings: TaskBoardOrchestratorSettings(wire: wire.settings)
    )
  }
}
