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
        targetProjectTypes: request.targetProjectTypes,
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
      if let error = taskBoardUpdateError {
        throw error
      }
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

  func beginTaskBoardPlan(id: String) async throws -> TaskBoardPlanningResponse {
    calls.append(.beginTaskBoardPlan(id: id))
    return try updateTaskBoardPlanning(
      id: id,
      toStatus: .planning,
      planning: nil
    )
  }

  func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) async throws -> TaskBoardPlanningResponse {
    calls.append(.submitTaskBoardPlan(id: id, summary: request.summary))
    return try updateTaskBoardPlanning(
      id: id,
      toStatus: .planReview,
      planning: TaskBoardPlanningState(summary: request.summary)
    )
  }

  func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> TaskBoardPlanningResponse {
    calls.append(
      .approveTaskBoardPlan(
        id: id,
        approvedBy: request.approvedBy,
        approvedAt: request.approvedAt
      )
    )
    return try updateTaskBoardPlanning(
      id: id,
      toStatus: .todo,
      planning: nil,
      approvedBy: request.approvedBy,
      approvedAt: request.approvedAt ?? "2026-05-14T10:06:00Z"
    )
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

  func dispatchTaskBoard(
    request: TaskBoardDispatchRequest
  ) async throws -> TaskBoardDispatchSummary {
    calls.append(
      .dispatchTaskBoard(
        dryRun: request.dryRun,
        status: request.status,
        itemID: request.itemId,
        projectDir: request.projectDir,
        actor: request.actor
      )
    )
    return lock.withLock {
      let matching = filteredTaskBoardItems(status: request.status, itemId: request.itemId)
      var applied: [TaskBoardDispatchAppliedTask] = []
      let plans = matching.map { item in
        if request.dryRun {
          return sampleDispatchPlan(for: item)
        }

        let updated = item.applying(
          TaskBoardUpdateItemRequest(
            status: .inProgress,
            workflow: TaskBoardWorkflowState(
              executionId: "exec-\(item.id)",
              status: .running,
              currentStepId: "dispatch",
              attempts: (item.workflow?.attempts ?? 0) + 1,
              branch: item.workflow?.branch ?? "task-board/\(item.id)",
              worktree: item.workflow?.worktree,
              policyTraceIds: ["trace-\(item.id)"]
            ),
            sessionId: item.sessionId ?? "sess-\(item.id)",
            workItemId: item.workItemId ?? "task-\(item.id)"
          )
        )
        replaceTaskBoardItem(updated)
        applied.append(
          TaskBoardDispatchAppliedTask(
            boardItemId: updated.id,
            sessionId: updated.sessionId ?? "sess-\(updated.id)",
            workItemId: updated.workItemId ?? "task-\(updated.id)",
            item: updated
          )
        )
        return sampleDispatchPlan(for: updated)
      }
      return TaskBoardDispatchSummary(plans: plans, applied: applied)
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

  func auditTaskBoard(status: TaskBoardStatus?) async throws -> TaskBoardAuditSummary {
    calls.append(.auditTaskBoard(status: status))
    return lock.withLock {
      if let summary = taskBoardAuditSummaryStorage {
        return summary
      }
      let items = filteredTaskBoardItems(status: status, itemId: nil)
      return TaskBoardAuditSummary(
        total: items.count,
        ready: items.count { $0.status == .todo },
        blocked: items.count { $0.status == .blocked },
        deleted: 0,
        byStatus: statusCounts(for: items)
      )
    }
  }

  func taskBoardProjects(status: TaskBoardStatus?) async throws -> [TaskBoardProjectSummary] {
    calls.append(.taskBoardProjects(status: status))
    return lock.withLock {
      if let summaries = taskBoardProjectSummariesStorage {
        return summaries
      }
      let grouped = Dictionary(
        grouping: filteredTaskBoardItems(status: status, itemId: nil)
          .filter { $0.projectId != nil },
        by: \.projectId
      )
      return grouped.compactMap { key, items in
        guard let projectId = key else {
          return nil
        }
        return TaskBoardProjectSummary(
          projectId: projectId,
          itemCount: items.count,
          readyCount: items.count { $0.status == .todo }
        )
      }
      .sorted { lhs, rhs in
        if lhs.readyCount == rhs.readyCount {
          return lhs.projectId < rhs.projectId
        }
        return lhs.readyCount > rhs.readyCount
      }
    }
  }

  func taskBoardMachines(status: TaskBoardStatus?) async throws -> [TaskBoardMachineSummary] {
    calls.append(.taskBoardMachines(status: status))
    return lock.withLock {
      if let summaries = taskBoardMachineSummariesStorage {
        return summaries
      }
      let grouped = Dictionary(
        grouping: filteredTaskBoardItems(status: status, itemId: nil), by: \.agentMode)
      return grouped.map { mode, items in
        TaskBoardMachineSummary(
          mode: mode,
          itemCount: items.count,
          readyCount: items.count { $0.status == .todo }
        )
      }
      .sorted { lhs, rhs in
        if lhs.readyCount == rhs.readyCount {
          return lhs.mode.title < rhs.mode.title
        }
        return lhs.readyCount > rhs.readyCount
      }
    }
  }

  func taskBoardHostLocal() async throws -> TaskBoardHostMachine {
    calls.append(.taskBoardHostLocal)
    return sampleTaskBoardHostMachine()
  }

  func taskBoardHostList() async throws -> [TaskBoardHostMachine] {
    calls.append(.taskBoardHostList)
    return [sampleTaskBoardHostMachine()]
  }

  func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine {
    calls.append(.setTaskBoardHostProjectTypes(projectTypes: request.projectTypes))
    return TaskBoardHostMachine(
      id: "recording-host-local",
      label: "Recording Mac",
      projectTypes: request.projectTypes,
      agentModes: [],
      lastSeen: "2026-05-15T19:00:00Z"
    )
  }

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
    calls.append(
      .syncTaskBoardGitHubTokens(
        globalTokenConfigured: request.globalToken != nil,
        repositoryTokenCount: request.repositoryTokens.count
      )
    )
    if let error = lock.withLock({ taskBoardGitHubTokensSyncError }) {
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
    calls.append(.syncTaskBoardTodoistToken(tokenConfigured: request.token != nil))
    if let error = lock.withLock({ taskBoardTodoistTokenSyncError }) {
      throw error
    }
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
        owner: "example",
        repo: "harness",
        checkoutPath: "/tmp/harness",
        protectedPaths: [TaskBoardProtectedPathRule(pattern: "apps/harness-monitor-macos")],
        enabledAutomations: TaskBoardGitHubAutomationToggles(enabled: [.syncTaskBoard, .autoMerge])
      ),
      githubInbox: TaskBoardGitHubInboxConfig(repositories: ["example/harness", "example/aff"]),
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

  private func filteredTaskBoardItems(
    status: TaskBoardStatus?,
    itemId: String?
  ) -> [TaskBoardItem] {
    taskBoardItemsStorage.filter { item in
      (status == nil || item.status == status) && (itemId == nil || item.id == itemId)
    }
  }

  private func replaceTaskBoardItem(_ item: TaskBoardItem) {
    guard let index = taskBoardItemsStorage.firstIndex(where: { $0.id == item.id }) else {
      taskBoardItemsStorage.append(item)
      return
    }
    taskBoardItemsStorage[index] = item
  }

  private func statusCounts(for items: [TaskBoardItem]) -> [TaskBoardStatusCount] {
    let totals = Dictionary(grouping: items, by: \.status)
    return TaskBoardStatus.allCases.compactMap { status in
      guard let itemsForStatus = totals[status], !itemsForStatus.isEmpty else {
        return nil
      }
      return TaskBoardStatusCount(status: status, count: itemsForStatus.count)
    }
  }

  private func sampleDispatchPlan(for item: TaskBoardItem) -> TaskBoardDispatchPlan {
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
}

extension RecordingHarnessClient {
  fileprivate func updateTaskBoardPlanning(
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
  fileprivate func applyingPlanning(
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
