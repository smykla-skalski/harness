import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func taskBoardCapabilities() async throws -> TaskBoardCapabilities {
    lock.withLock { taskBoardCapabilitiesValue }
  }

  func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    recordReadCall(.taskBoardItems(status))
    if let error = dequeueTaskBoardItemsError() {
      throw error
    }
    let items =
      dequeueTaskBoardItemSnapshot()
      ?? lock.withLock { taskBoardItemsStorage }
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
        status: .todo,
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
      toStatus: .agenticReview,
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
    let result: (summary: TaskBoardSyncSummary, error: (any Error)?) = lock.withLock {
      let error = taskBoardSyncStub.error
      if error == nil, let importedItems = taskBoardSyncStub.importedItems {
        taskBoardItemsStorage = importedItems
      }
      return (taskBoardSyncStub.summary, error)
    }
    if let error = result.error {
      throw error
    }
    return result.summary
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
        blocked: items.count { $0.status == .failed },
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

}
