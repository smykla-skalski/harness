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
    record(
      .createTaskBoardItem(
        title: request.title,
        priority: request.priority,
        status: request.status
      )
    )
    return try lock.withLock {
      if let error = taskBoardCreateError {
        throw error
      }
      let item = TaskBoardItem(
        schemaVersion: 1,
        id: request.id ?? "board-\(taskBoardItemsStorage.count + 1)",
        title: request.title,
        body: request.body,
        status: request.status ?? .todo,
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
    try await sleepIfNeeded(configuredMutationDelay())
    record(.updateTaskBoardItem(id: id, status: request.status))
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
    record(.deleteTaskBoardItem(id: id))
    return try lock.withLock {
      guard let index = taskBoardItemsStorage.firstIndex(where: { $0.id == id }) else {
        throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
      }
      let deleted = taskBoardItemsStorage.remove(at: index)
      taskBoardTriageDecisionsStorage.removeValue(forKey: id)
      taskBoardTriageOverridesStorage.removeValue(forKey: id)
      return deleted
    }
  }

  func beginTaskBoardPlan(id: String) async throws -> TaskBoardPlanningResponse {
    record(.beginTaskBoardPlan(id: id))
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
    record(.submitTaskBoardPlan(id: id, summary: request.summary))
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
    record(
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

  func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest
  ) async throws -> TaskBoardPlanningResponse {
    record(.revokeTaskBoardPlan(id: id, actor: request.actor))
    return try updateTaskBoardPlanning(
      id: id,
      toStatus: .planning,
      planning: TaskBoardPlanningState()
    )
  }

  func syncTaskBoard(request: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    record(
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
    record(
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
      var failures: [TaskBoardDispatchFailure] = []
      let plans = matching.map { item -> TaskBoardDispatchPlan in
        if request.dryRun {
          return sampleDispatchPlan(for: item)
        }

        // A reserve failure lands the item in failures instead of applied - the
        // daemon reports one or the other, never both - so skip mutating it.
        if let message = taskBoardDispatchFailureMessages[item.id] {
          failures.append(TaskBoardDispatchFailure(boardItemId: item.id, message: message))
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
      // A targeted item that never matched (so is not on the board) still
      // reports its configured reserve failure.
      if !request.dryRun, let itemID = request.itemId,
        let message = taskBoardDispatchFailureMessages[itemID],
        !failures.contains(where: { $0.boardItemId == itemID })
      {
        failures.append(TaskBoardDispatchFailure(boardItemId: itemID, message: message))
      }
      return TaskBoardDispatchSummary(plans: plans, applied: applied, failures: failures)
    }
  }

  func deliverTaskBoardDispatch(
    request: TaskBoardDispatchDeliverRequest
  ) async throws -> TaskBoardDispatchDelivery {
    record(
      .deliverTaskBoardDispatch(itemID: request.itemId, dryRun: request.dryRun)
    )
    return try lock.withLock {
      if let error = queuedDeliverTaskBoardDispatchErrors.first {
        queuedDeliverTaskBoardDispatchErrors.removeFirst()
        throw error
      }
      guard let item = taskBoardItemsStorage.first(where: { $0.id == request.itemId }) else {
        throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
      }
      return TaskBoardDispatchDelivery(
        intentId: "intent-\(item.id)",
        applied: TaskBoardDispatchAppliedTask(
          boardItemId: item.id,
          sessionId: item.sessionId ?? "sess-\(item.id)",
          workItemId: item.workItemId ?? "task-\(item.id)",
          item: item
        ),
        renderedPrompt: "durable prompt"
      )
    }
  }

  func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    recordReadCall(.taskBoardOrchestratorStatus)
    let heldItemIDs = lock.withLock { heldTaskBoardDispatchItemIDs }
    return sampleTaskBoardOrchestratorStatus(
      heldDispatches: TaskBoardHeldDispatchSummary(
        count: UInt(heldItemIDs.count),
        items: heldItemIDs.map { itemID in
          TaskBoardHeldDispatchItem(
            intentId: "intent-\(itemID)",
            boardItemId: itemID,
            sessionId: "sess-\(itemID)",
            workItemId: "task-\(itemID)"
          )
        }
      )
    )
  }

  func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    record(.startTaskBoardOrchestrator)
    return sampleTaskBoardOrchestratorStatus(enabled: true, running: true)
  }

  func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    record(.stopTaskBoardOrchestrator)
    return sampleTaskBoardOrchestratorStatus(enabled: true, running: false)
  }

  func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest
  ) async throws -> TaskBoardOrchestratorRunOnceResponse {
    record(
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
    record(
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
}
