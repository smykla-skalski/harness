import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    recordReadCall(.taskBoardItems(status))
    let items = lock.withLock { taskBoardItemsStorage }
    guard let status else {
      return items
    }
    return items.filter { $0.status == status }
  }

  func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    calls.append(.updateTaskBoardItem(id: id, status: request.status))
    return try lock.withLock {
      guard let index = taskBoardItemsStorage.firstIndex(where: { $0.id == id }) else {
        throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
      }
      let current = taskBoardItemsStorage[index]
      let updated = current.applying(request)
      taskBoardItemsStorage[index] = updated
      return updated
    }
  }

  func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    recordReadCall(.taskBoardOrchestratorStatus)
    return sampleTaskBoardOrchestratorStatus()
  }

  func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    calls.append(.startTaskBoardOrchestrator)
    return sampleTaskBoardOrchestratorStatus(enabled: true, running: true)
  }

  func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    calls.append(.stopTaskBoardOrchestrator)
    return sampleTaskBoardOrchestratorStatus(enabled: true, running: false)
  }

  func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest
  ) async throws -> TaskBoardOrchestratorRunOnceResponse {
    calls.append(
      .runTaskBoardOrchestratorOnce(
        dryRun: request.dryRun,
        status: request.status,
        projectDir: request.projectDir
      )
    )
    return sampleTaskBoardOrchestratorStatus()
  }

  func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  {
    calls.append(.evaluateTaskBoard(dryRun: request.dryRun, status: request.status))
    return TaskBoardEvaluationSummary(
      total: 1,
      evaluated: 1,
      updated: 1,
      completed: 1,
      records: [
        TaskBoardEvaluationRecord(
          boardItemId: "board-1",
          sessionId: "sess-1",
          workItemId: "task-1",
          outcome: .completed,
          taskStatus: .done,
          boardStatus: .done,
          workflowStatus: .completed,
          updated: true
        )
      ]
    )
  }

  func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    recordReadCall(.taskBoardOrchestratorSettings)
    return sampleTaskBoardOrchestratorSettings()
  }

  func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    calls.append(
      .updateTaskBoardOrchestratorSettings(
        policyVersion: request.policyVersion,
        clearProjectDir: request.clearProjectDir,
        clearDispatchStatusFilter: request.clearDispatchStatusFilter
      )
    )
    return TaskBoardOrchestratorSettings(
      enabledWorkflows: request.enabledWorkflows ?? [.defaultTask],
      dryRunDefault: request.dryRunDefault ?? true,
      dispatchStatusFilter: request.dispatchStatusFilter,
      projectDir: request.projectDir,
      githubProject: request.githubProject ?? TaskBoardGitHubProjectConfig(),
      policyVersion: request.policyVersion ?? "task-board-policy-v1"
    )
  }

  private func sampleTaskBoardOrchestratorStatus(
    enabled: Bool = true,
    running: Bool = false
  ) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: enabled,
      running: running,
      currentTick: TaskBoardOrchestratorTickInfo(
        runId: "run-active",
        phase: .evaluation,
        startedAt: "2026-05-14T10:02:00Z",
        dryRun: false
      ),
      lastRun: TaskBoardOrchestratorRunSummary(
        runId: "run-1",
        startedAt: "2026-05-14T10:00:00Z",
        completedAt: "2026-05-14T10:01:00Z",
        status: .completed,
        dryRun: false,
        sync: TaskBoardSyncSummary(total: 1, providers: []),
        audit: TaskBoardAuditSummary(total: 1, ready: 1, blocked: 0, deleted: 0, byStatus: []),
        dispatch: TaskBoardDispatchSummary(plans: [], applied: []),
        evaluation: TaskBoardEvaluationSummary(total: 1, evaluated: 1, updated: 1, completed: 1),
        policyTraceIds: ["trace-1"]
      ),
      workflowExecutionCounts: [
        TaskBoardWorkflowExecutionCount(status: .completed, count: 1)
      ],
      settings: sampleTaskBoardOrchestratorSettings()
    )
  }

  private func sampleTaskBoardOrchestratorSettings() -> TaskBoardOrchestratorSettings {
    TaskBoardOrchestratorSettings(
      enabledWorkflows: [.defaultTask, .prFix],
      dryRunDefault: false,
      dispatchStatusFilter: .todo,
      projectDir: "/tmp/harness",
      githubProject: TaskBoardGitHubProjectConfig(
        owner: "kong",
        repo: "harness",
        checkoutPath: "/tmp/harness",
        protectedPaths: [TaskBoardProtectedPathRule(pattern: "apps/harness-monitor-macos")],
        enabledAutomations: TaskBoardGitHubAutomationToggles(enabled: [.syncTaskBoard, .autoMerge])
      ),
      policyVersion: "task-board-policy-v1"
    )
  }
}

extension TaskBoardItem {
  fileprivate func applying(_ request: TaskBoardUpdateItemRequest) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: request.title ?? title,
      body: request.body ?? body,
      status: request.status ?? status,
      priority: request.priority ?? priority,
      tags: request.tags ?? tags,
      projectId: request.clearProjectId ? nil : request.projectId ?? projectId,
      agentMode: request.agentMode ?? agentMode,
      externalRefs: request.externalRefs ?? externalRefs,
      planning: request.planning ?? planning,
      workflow: request.workflow ?? workflow,
      sessionId: request.clearSessionId ? nil : request.sessionId ?? sessionId,
      workItemId: request.clearWorkItemId ? nil : request.workItemId ?? workItemId,
      usage: usage,
      createdAt: createdAt,
      updatedAt: "2026-05-14T10:05:00Z",
      deletedAt: deletedAt
    )
  }
}
