import Foundation

extension PreviewHarnessClientState {
  func currentTaskBoardItems(status: TaskBoardStatus?) -> [TaskBoardItem] {
    guard let status else {
      return taskBoardItems
    }
    return taskBoardItems.filter { $0.status == status }
  }

  func currentTaskBoardItem(id: String) throws -> TaskBoardItem {
    guard let item = taskBoardItems.first(where: { $0.id == id }) else {
      throw taskBoardItemUnavailable()
    }
    return item
  }

  func createTaskBoardItem(request: TaskBoardCreateItemRequest) -> TaskBoardItem {
    let item = TaskBoardItem(
      schemaVersion: 1,
      id: request.id ?? "preview-board-\(taskBoardItems.count + 1)",
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
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp,
      deletedAt: nil
    )
    taskBoardItems.append(item)
    return item
  }

  func updateTaskBoardItem(id: String, request: TaskBoardUpdateItemRequest) throws
    -> TaskBoardItem
  {
    guard let index = taskBoardItems.firstIndex(where: { $0.id == id }) else {
      throw taskBoardItemUnavailable()
    }
    let updated = taskBoardItems[index].applyingPreviewUpdate(request)
    taskBoardItems[index] = updated
    return updated
  }

  func deleteTaskBoardItem(id: String) throws -> TaskBoardItem {
    guard let index = taskBoardItems.firstIndex(where: { $0.id == id }) else {
      throw taskBoardItemUnavailable()
    }
    return taskBoardItems.remove(at: index)
  }

  func beginTaskBoardPlan(id: String) throws -> TaskBoardPlanningResponse {
    try updateTaskBoardPlanning(
      id: id,
      toStatus: .planning,
      planning: TaskBoardPlanningState()
    )
  }

  func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) throws -> TaskBoardPlanningResponse {
    try updateTaskBoardPlanning(
      id: id,
      toStatus: .planReview,
      planning: TaskBoardPlanningState(summary: request.summary)
    )
  }

  func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) throws -> TaskBoardPlanningResponse {
    let approvedPlanning = TaskBoardPlanningState(
      summary: try currentTaskBoardItem(id: id).planning.summary,
      approvedBy: request.approvedBy,
      approvedAt: request.approvedAt ?? Self.mutationTimestamp
    )
    return try updateTaskBoardPlanning(id: id, toStatus: .todo, planning: approvedPlanning)
  }

  func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest
  ) throws -> TaskBoardPlanningResponse {
    let currentPlanning = try currentTaskBoardItem(id: id).planning
    let revokedPlanning = TaskBoardPlanningState(
      summary: currentPlanning.summary,
      approvedBy: nil,
      approvedAt: nil
    )
    _ = request
    return try updateTaskBoardPlanning(
      id: id,
      toStatus: .planReview,
      planning: revokedPlanning
    )
  }

  func syncTaskBoard() -> TaskBoardSyncSummary {
    TaskBoardSyncSummary(
      total: taskBoardItems.count,
      providers: [],
      operations: taskBoardItems.map { item in
        TaskBoardExternalSyncOperation(
          provider: .gitHub,
          action: .push,
          boardItemId: item.id,
          externalId: item.externalRefs.first?.externalId,
          url: item.externalRefs.first?.url,
          dryRun: true,
          applied: false
        )
      }
    )
  }

  func dispatchTaskBoard(request: TaskBoardDispatchRequest) -> TaskBoardDispatchSummary {
    var applied: [TaskBoardDispatchAppliedTask] = []
    let plans = matchingTaskBoardItems(status: request.status, itemId: request.itemId).map { item in
      let updated = item.applyingPreviewDispatch()
      if !request.dryRun {
        replaceTaskBoardItem(updated)
        applied.append(
          TaskBoardDispatchAppliedTask(
            boardItemId: updated.id,
            sessionId: updated.sessionId ?? "preview-session-\(updated.id)",
            workItemId: updated.workItemId ?? "preview-task-\(updated.id)",
            item: updated
          )
        )
      }
      return TaskBoardDispatchPlan.previewPlan(for: item)
    }
    return TaskBoardDispatchSummary(plans: plans, applied: applied)
  }

  func auditTaskBoard(status: TaskBoardStatus?) -> TaskBoardAuditSummary {
    let items = currentTaskBoardItems(status: status)
    return TaskBoardAuditSummary(
      total: items.count,
      ready: items.count { $0.status == .todo },
      blocked: items.count { $0.status == .blocked },
      deleted: 0,
      byStatus: statusCounts(for: items)
    )
  }

  func taskBoardProjects(status: TaskBoardStatus?) -> [TaskBoardProjectSummary] {
    let grouped = Dictionary(
      grouping: currentTaskBoardItems(status: status).filter { $0.projectId != nil },
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

  func taskBoardMachines(status: TaskBoardStatus?) -> [TaskBoardMachineSummary] {
    let grouped = Dictionary(grouping: currentTaskBoardItems(status: status), by: \.agentMode)
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

  func taskBoardHostLocal() -> TaskBoardHostMachine {
    if let first = taskBoardHostRegistry.first {
      return first
    }
    let machine = TaskBoardHostMachine(
      id: "preview-host-local",
      label: "Preview Mac",
      projectTypes: [],
      agentModes: [],
      lastSeen: Self.mutationTimestamp
    )
    taskBoardHostRegistry.append(machine)
    return machine
  }

  func taskBoardHostList() -> [TaskBoardHostMachine] {
    taskBoardHostRegistry
  }

  func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) -> TaskBoardHostMachine {
    let current = taskBoardHostLocal()
    let updated = TaskBoardHostMachine(
      id: current.id,
      label: current.label,
      projectTypes: request.projectTypes,
      agentModes: current.agentModes,
      lastSeen: Self.mutationTimestamp
    )
    if let index = taskBoardHostRegistry.firstIndex(where: { $0.id == updated.id }) {
      taskBoardHostRegistry[index] = updated
    } else {
      taskBoardHostRegistry.append(updated)
    }
    return updated
  }

  func evaluateTaskBoard(request: TaskBoardEvaluateRequest) -> TaskBoardEvaluationSummary {
    var records: [TaskBoardEvaluationRecord] = []
    for item in matchingTaskBoardItems(status: request.status, itemId: request.itemId) {
      let record = evaluateTaskBoardItem(item, dryRun: request.dryRun)
      records.append(record)
    }
    return TaskBoardEvaluationSummary.previewSummary(records: records)
  }

  func currentTaskBoardOrchestratorStatus() -> TaskBoardOrchestratorStatus {
    taskBoardOrchestratorStatus
  }

  func setTaskBoardOrchestratorRunning(_ running: Bool) -> TaskBoardOrchestratorStatus {
    taskBoardOrchestratorStatus = taskBoardOrchestratorStatus.replacingPreviewRuntime(
      running: running
    )
    return taskBoardOrchestratorStatus
  }

  func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest
  ) -> TaskBoardOrchestratorStatus {
    let dryRun = request.dryRun ?? taskBoardOrchestratorSettings.dryRunDefault
    let dispatch = dispatchTaskBoard(
      request: TaskBoardDispatchRequest(
        status: request.status ?? taskBoardOrchestratorSettings.dispatchStatusFilter,
        itemId: request.itemId,
        dryRun: dryRun,
        projectDir: request.projectDir ?? taskBoardOrchestratorSettings.projectDir,
        actor: request.actor
      )
    )
    let evaluation = evaluateTaskBoard(
      request: TaskBoardEvaluateRequest(
        status: request.status,
        itemId: request.itemId,
        dryRun: dryRun
      )
    )
    taskBoardOrchestratorStatus = taskBoardOrchestratorStatus.replacingPreviewRun(
      run: TaskBoardOrchestratorRunSummary.previewRun(
        dryRun: dryRun,
        sync: syncTaskBoard(),
        dispatch: dispatch,
        evaluation: evaluation
      )
    )
    return taskBoardOrchestratorStatus
  }

  private func updateTaskBoardPlanning(
    id: String,
    toStatus: TaskBoardStatus,
    planning: TaskBoardPlanningState
  ) throws -> TaskBoardPlanningResponse {
    let current = try currentTaskBoardItem(id: id)
    let updated = current.applyingPreviewPlanning(status: toStatus, planning: planning)
    replaceTaskBoardItem(updated)
    return TaskBoardPlanningResponse(
      transition: TaskBoardPlanningTransition(
        boardItemId: id,
        fromStatus: current.status,
        toStatus: toStatus,
        planning: planning
      ),
      item: updated
    )
  }

  private func matchingTaskBoardItems(
    status: TaskBoardStatus?,
    itemId: String?
  ) -> [TaskBoardItem] {
    taskBoardItems.filter { item in
      (status == nil || item.status == status) && (itemId == nil || item.id == itemId)
    }
  }

  private func evaluateTaskBoardItem(
    _ item: TaskBoardItem,
    dryRun: Bool
  ) -> TaskBoardEvaluationRecord {
    guard item.sessionId != nil, item.workItemId != nil else {
      return item.previewEvaluationRecord(outcome: .skippedUnlinked, updated: false)
    }
    let boardStatus = item.status.previewEvaluationStatus
    let workflowStatus = item.status.previewEvaluationWorkflowStatus
    let updated = boardStatus != item.status || workflowStatus != item.workflow?.status
    let evaluated = item.applyingPreviewEvaluation(
      status: boardStatus,
      workflowStatus: workflowStatus
    )
    if updated && !dryRun {
      replaceTaskBoardItem(evaluated)
    }
    return evaluated.previewEvaluationRecord(
      outcome: boardStatus.previewEvaluationOutcome,
      updated: updated && !dryRun
    )
  }

  private func replaceTaskBoardItem(_ item: TaskBoardItem) {
    guard let index = taskBoardItems.firstIndex(where: { $0.id == item.id }) else {
      taskBoardItems.append(item)
      return
    }
    taskBoardItems[index] = item
  }

  private func taskBoardItemUnavailable() -> HarnessMonitorAPIError {
    HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable")
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
}
