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

  func createTaskBoardItem(request: TaskBoardCreateItemRequest) async throws -> TaskBoardItem {
    calls.append(.createTaskBoardItem(title: request.title, priority: request.priority))
    return lock.withLock {
      let item = TaskBoardItem(
        schemaVersion: 1,
        id: request.id ?? "board-\(taskBoardItemsStorage.count + 1)",
        title: request.title,
        body: request.body,
        status: .new,
        priority: request.priority,
        tags: request.tags,
        projectId: request.projectId,
        agentMode: request.agentMode,
        externalRefs: request.externalRefs,
        planning: request.planning,
        workflow: request.workflow,
        sessionId: request.sessionId,
        workItemId: request.workItemId,
        usage: TaskBoardUsage(),
        createdAt: "2026-05-14T10:04:00Z",
        updatedAt: "2026-05-14T10:04:00Z",
        deletedAt: nil
      )
      taskBoardItemsStorage.append(item)
      return item
    }
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

  func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem {
    calls.append(.deleteTaskBoardItem(id: id))
    return try lock.withLock {
      guard let index = taskBoardItemsStorage.firstIndex(where: { $0.id == id }) else {
        throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
      }
      return taskBoardItemsStorage.remove(at: index)
    }
  }

  func syncTaskBoard(request: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    calls.append(
      .syncTaskBoard(
        direction: request.direction,
        dryRun: request.dryRun,
        status: request.status,
        provider: request.provider
      )
    )
    return lock.withLock {
      if let importedItems = taskBoardItemsAfterSyncStorage {
        taskBoardItemsStorage = importedItems
      }
      return taskBoardSyncSummaryStorage
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
        itemID: request.itemId,
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
    calls.append(
      .evaluateTaskBoard(
        dryRun: request.dryRun,
        status: request.status,
        itemID: request.itemId
      )
    )
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

  func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig {
    recordReadCall(.taskBoardGitRuntimeConfig)
    return sampleTaskBoardGitRuntimeConfig()
  }

  func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    calls.append(.updateTaskBoardGitRuntimeConfig(overrideCount: request.repositoryOverrides.count))
    return request
  }

  func syncTaskBoardGitHubTokens(
    request: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse {
    calls.append(
      .syncTaskBoardGitHubTokens(
        globalTokenConfigured: request.globalToken != nil,
        repositoryTokenCount: request.repositoryTokens.count
      )
    )
    return TaskBoardGitHubTokensSyncResponse(
      globalTokenConfigured: request.globalToken != nil,
      repositoryTokenCount: request.repositoryTokens.count
    )
  }

  func syncTaskBoardTodoistToken(
    request: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    calls.append(.syncTaskBoardTodoistToken(tokenConfigured: request.token != nil))
    return TaskBoardTodoistTokenSyncResponse(tokenConfigured: request.token != nil)
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

  private func sampleTaskBoardGitRuntimeConfig() -> TaskBoardGitRuntimeConfig {
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
          repository: "kong/harness",
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
