import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func sampleTaskBoardHostMachine() -> TaskBoardHostMachine {
    TaskBoardHostMachine(
      id: "recording-host-local",
      label: "Recording Mac",
      projectTypes: [],
      agentModes: [],
      lastSeen: "2026-05-15T19:00:00Z"
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
    if let error = lock.withLock({ taskBoardOrchestratorSettingsError }) {
      throw error
    }
    return TaskBoardOrchestratorSettings(
      enabledWorkflows: request.enabledWorkflows ?? [.defaultTask],
      dryRunDefault: request.dryRunDefault ?? true,
      dispatchStatusFilter: request.dispatchStatusFilter,
      projectDir: request.projectDir,
      githubProject: request.githubProject ?? TaskBoardGitHubProjectConfig(),
      githubInbox: request.githubInbox ?? TaskBoardGitHubInboxConfig(),
      policyVersion: request.policyVersion ?? "task-board-policy-v1"
    )
  }

  func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig {
    recordReadCall(.taskBoardGitRuntimeConfig)
    return sampleTaskBoardGitRuntimeConfig()
  }

  func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    calls.append(.updateTaskBoardGitRuntimeConfig(overrideCount: request.repositoryOverrides.count))
    if let error = lock.withLock({ taskBoardRuntimeConfigError }) {
      throw error
    }
    return request
  }

  func syncTaskBoardGitHubTokens(
    request: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse {
    let error = lock.withLock {
      callsStorage.append(
        .syncTaskBoardGitHubTokens(
          globalTokenConfigured: request.globalToken != nil,
          repositoryTokenCount: request.repositoryTokens.count
        )
      )
      return taskBoardGitHubTokensSyncError
    }
    if let error {
      throw error
    }
    return TaskBoardGitHubTokensSyncResponse(
      globalTokenConfigured: request.globalToken != nil,
      repositoryTokenCount: request.repositoryTokens.count
    )
  }

  func syncTaskBoardTodoistToken(
    request: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    let error = lock.withLock {
      callsStorage.append(.syncTaskBoardTodoistToken(tokenConfigured: request.token != nil))
      return taskBoardTodoistTokenSyncError
    }
    if let error {
      throw error
    }
    return TaskBoardTodoistTokenSyncResponse(tokenConfigured: request.token != nil)
  }

  func syncTaskBoardOpenRouterToken(
    request: TaskBoardOpenRouterTokenSyncRequest
  ) async throws -> TaskBoardOpenRouterTokenSyncResponse {
    lock.withLock {
      callsStorage.append(.syncTaskBoardOpenRouterToken(tokenConfigured: request.token != nil))
    }
    return TaskBoardOpenRouterTokenSyncResponse(tokenConfigured: request.token != nil)
  }

  func taskBoardGitIdentityDefaults() async throws -> TaskBoardGitIdentityDefaults {
    calls.append(.taskBoardGitIdentityDefaults)
    return lock.withLock { taskBoardGitIdentityDefaultsValue }
  }

  func verifyTaskBoardGitSigning(
    request: TaskBoardGitSigningVerifyRequest
  ) async throws -> TaskBoardGitSigningVerifyResponse {
    calls.append(.verifyTaskBoardGitSigning(repository: request.repository))
    return lock.withLock { taskBoardGitSigningVerifyValue }
  }

  func drainTaskBoardGitRuntimeSecrets() async throws
    -> TaskBoardGitRuntimeDrainSecretsResponse
  {
    calls.append(.drainTaskBoardGitRuntimeSecrets)
    if let error = lock.withLock({ taskBoardGitRuntimeDrainSecretsError }) {
      throw error
    }
    return lock.withLock { taskBoardGitRuntimeDrainSecretsValue }
  }

  func sampleTaskBoardOrchestratorStatus(
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

  func sampleTaskBoardOrchestratorSettings() -> TaskBoardOrchestratorSettings {
    TaskBoardOrchestratorSettings(
      enabledWorkflows: [.defaultTask, .prFix],
      dryRunDefault: false,
      dispatchStatusFilter: .todo,
      projectDir: "/tmp/harness",
      githubProject: TaskBoardGitHubProjectConfig(
        owner: "example",
        repo: "harness",
        checkoutPath: "/tmp/harness",
        protectedPaths: [TaskBoardProtectedPathRule(pattern: "apps/harness-monitor")],
        enabledAutomations: TaskBoardGitHubAutomationToggles(enabled: [.syncTaskBoard, .autoMerge])
      ),
      githubInbox: TaskBoardGitHubInboxConfig(repositories: ["example/harness", "example/aff"]),
      policyVersion: "task-board-policy-v1"
    )
  }

  func sampleTaskBoardGitRuntimeConfig() -> TaskBoardGitRuntimeConfig {
    TaskBoardGitRuntimeConfig(
      global: TaskBoardGitRuntimeProfile(
        authorName: "Harness Bot",
        authorEmail: "bot@example.com",
        sshKeyPath: "/Users/test/.ssh/id_ed25519",
        signing: TaskBoardGitSigningConfig(
          mode: .ssh,
          sshKeyPath: "/Users/test/.ssh/id_signing"
        )
      ),
      repositoryOverrides: [
        TaskBoardGitRepositoryOverride(
          repository: "example/harness",
          profile: TaskBoardGitRuntimeProfile(
            authorName: "Repo Bot",
            authorEmail: "repo@example.com",
            sshKeyPath: "/Users/test/.ssh/id_repo",
            signing: TaskBoardGitSigningConfig(mode: .gpg, gpgKeyId: "ABC123")
          )
        )
      ]
    )
  }

  func filteredTaskBoardItems(
    status: TaskBoardStatus?,
    itemId: String?
  ) -> [TaskBoardItem] {
    taskBoardItemsStorage.filter { item in
      (status == nil || item.status == status) && (itemId == nil || item.id == itemId)
    }
  }

  func replaceTaskBoardItem(_ item: TaskBoardItem) {
    guard let index = taskBoardItemsStorage.firstIndex(where: { $0.id == item.id }) else {
      taskBoardItemsStorage.append(item)
      return
    }
    taskBoardItemsStorage[index] = item
  }

  func statusCounts(for items: [TaskBoardItem]) -> [TaskBoardStatusCount] {
    let totals = Dictionary(grouping: items, by: \.status)
    return TaskBoardStatus.allCases.compactMap { status in
      guard let itemsForStatus = totals[status], !itemsForStatus.isEmpty else {
        return nil
      }
      return TaskBoardStatusCount(status: status, count: itemsForStatus.count)
    }
  }

  func sampleDispatchPlan(for item: TaskBoardItem) -> TaskBoardDispatchPlan {
    TaskBoardDispatchPlan(
      boardItemId: item.id,
      readiness: TaskBoardDispatchReadiness(state: "ready", reason: nil),
      session: TaskBoardSessionIntent(
        kind: item.sessionId == nil ? "create" : "existing",
        sessionId: item.sessionId,
        title: item.title,
        context: item.body,
        projectId: item.projectId
      ),
      task: TaskBoardTaskCreationIntent(
        title: item.title,
        context: item.body,
        severity: .medium,
        suggestedFix: item.planning.summary,
        source: .manual,
        tags: item.tags,
        externalRefs: item.externalRefs
      ),
      worker: TaskBoardWorkerIntent(mode: item.agentMode),
      reviewer: TaskBoardReviewerIntent(
        phase: "review",
        suggestedPersona: "reviewer",
        requiredConsensus: 1
      ),
      evaluator: TaskBoardEvaluatorIntent(phase: "evaluate", mode: .evaluate),
      policy: TaskBoardPolicyDecision(
        decision: "allow",
        reasonCode: "test_allow",
        policyVersion: "test"
      )
    )
  }

  func updateTaskBoardPlanning(
    id: String,
    toStatus: TaskBoardStatus,
    planning: TaskBoardPlanningState?,
    approvedBy: String? = nil,
    approvedAt: String? = nil
  ) throws -> TaskBoardPlanningResponse {
    try lock.withLock {
      guard let index = taskBoardItemsStorage.firstIndex(where: { $0.id == id }) else {
        throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
      }
      let current = taskBoardItemsStorage[index]
      let nextPlanning =
        planning
        ?? TaskBoardPlanningState(
          summary: current.planning.summary,
          approvedBy: approvedBy,
          approvedAt: approvedAt
        )
      let updated = current.applyingPlanning(status: toStatus, planning: nextPlanning)
      taskBoardItemsStorage[index] = updated
      return TaskBoardPlanningResponse(
        transition: TaskBoardPlanningTransition(
          boardItemId: id,
          fromStatus: current.status,
          toStatus: toStatus,
          planning: nextPlanning
        ),
        item: updated
      )
    }
  }
}

extension TaskBoardItem {
  func applying(_ request: TaskBoardUpdateItemRequest) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: request.title ?? title,
      body: request.body ?? body,
      status: request.status ?? status,
      priority: request.priority ?? priority,
      tags: request.tags ?? tags,
      projectId: request.clearProjectId ? nil : request.projectId ?? projectId,
      targetProjectTypes: request.targetProjectTypes ?? targetProjectTypes,
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

  func applyingPlanning(
    status: TaskBoardStatus,
    planning: TaskBoardPlanningState
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: title,
      body: body,
      status: status,
      priority: priority,
      tags: tags,
      projectId: projectId,
      targetProjectTypes: targetProjectTypes,
      agentMode: agentMode,
      externalRefs: externalRefs,
      planning: planning,
      workflow: workflow,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: usage,
      createdAt: createdAt,
      updatedAt: "2026-05-14T10:06:00Z",
      deletedAt: deletedAt
    )
  }
}
