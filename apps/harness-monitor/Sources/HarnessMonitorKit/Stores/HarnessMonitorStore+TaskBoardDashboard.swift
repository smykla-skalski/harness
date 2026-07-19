import Foundation

extension HarnessMonitorStore {
  public func refreshTaskBoardDashboard() async {
    guard let client, !isTaskBoardBusy else {
      return
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    _ = await syncAndRefreshTaskBoardDashboard(
      using: client,
      request: Self.taskBoardDashboardSyncRequest,
      successMessage: "Task board refreshed",
      activityKey: Self.taskBoardDashboardRefreshActivityKey,
      activityTitle: "Refreshing Task Board",
      feedbackPosition: .bottomTrailing
    )
  }

  @discardableResult
  public func updateTaskBoardItemStatus(id: String, status: TaskBoardStatus) async -> Bool {
    await updateTaskBoardItemStatuses(
      [TaskBoardItemStatusUpdate(id: id, status: status)]
    )
  }

  @discardableResult
  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest,
    initialStatus: TaskBoardStatus = .todo
  ) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    let createdItem: TaskBoardItem
    do {
      let measuredItem = try await Self.measureOperation {
        try await client.createTaskBoardItem(request: request)
      }
      recordRequestSuccess()
      createdItem = measuredItem.value
      mergeTaskBoardItem(createdItem)
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }

    guard createdItem.status != initialStatus else {
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback("Created task board item")
      return true
    }

    do {
      let updatedItem = try await client.updateTaskBoardItem(
        id: createdItem.id,
        request: TaskBoardUpdateItemRequest(status: initialStatus)
      )
      mergeTaskBoardItem(updatedItem)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback("Created task board item")
      return true
    } catch {
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentFailureFeedback(
        """
        Created task board item but couldn't set status to \(initialStatus.rawValue): \
        \(error.localizedDescription)
        """
      )
      return false
    }
  }

  @discardableResult
  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest,
    successMessage: String = "Saved task board item"
  ) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredItem = try await Self.measureOperation {
        try await client.updateTaskBoardItem(id: id, request: request)
      }
      recordRequestSuccess()
      mergeTaskBoardItem(measuredItem.value)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback(successMessage)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func deleteTaskBoardItem(id: String) async -> Bool {
    await deleteTaskBoardItems(ids: [id])
  }

  @discardableResult
  public func beginTaskBoardPlan(id: String) async -> Bool {
    await mutateTaskBoardPlanning(actionName: "Began task board planning") { client in
      try await client.beginTaskBoardPlan(id: id)
    }
  }

  @discardableResult
  public func submitTaskBoardPlan(id: String, summary: String) async -> Bool {
    await mutateTaskBoardPlanning(actionName: "Submitted task board plan") { client in
      try await client.submitTaskBoardPlan(
        id: id,
        request: TaskBoardPlanSubmitRequest(summary: summary)
      )
    }
  }

  @discardableResult
  public func approveTaskBoardPlan(
    id: String,
    approvedBy: String,
    approvedAt: String? = nil
  ) async -> Bool {
    await mutateTaskBoardPlanning(actionName: "Approved task board plan") { client in
      try await client.approveTaskBoardPlan(
        id: id,
        request: TaskBoardPlanApproveRequest(approvedBy: approvedBy, approvedAt: approvedAt)
      )
    }
  }

  @discardableResult
  public func startTaskBoardOrchestrator() async -> Bool {
    await mutateTaskBoardOrchestrator(actionName: "Started task board") { client in
      try await client.startTaskBoardOrchestrator()
    }
  }

  @discardableResult
  public func stopTaskBoardOrchestrator() async -> Bool {
    await mutateTaskBoardOrchestrator(actionName: "Stopped task board") { client in
      try await client.stopTaskBoardOrchestrator()
    }
  }

  @discardableResult
  public func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest = TaskBoardOrchestratorRunOnceRequest()
  ) async -> Bool {
    await mutateTaskBoardOrchestrator(actionName: "Ran task board") { client in
      try await client.runTaskBoardOrchestratorOnce(request: request)
    }
  }

  @discardableResult
  public func evaluateTaskBoard(
    status: TaskBoardStatus? = nil,
    itemID: String? = nil,
    dryRun: Bool = false
  ) async -> Bool {
    await evaluateTaskBoard(
      request: TaskBoardEvaluateRequest(status: status, itemId: itemID, dryRun: dryRun)
    )
  }

  @discardableResult
  public func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.evaluateTaskBoard(request: request)
      }
      recordRequestSuccess()
      let preRefreshBaselineRunID = globalTaskBoardOrchestratorStatus?.lastRun?.runId
      globalTaskBoardEvaluationSummary = measuredSummary.value
      scheduleUISync([.contentDashboard])
      await refreshTaskBoardDashboardSnapshot(using: client)
      cacheWriteSync.taskBoardEvaluationBaselineRunID =
        preRefreshBaselineRunID ?? globalTaskBoardOrchestratorStatus?.lastRun?.runId
      scheduleUISync([.contentDashboard])
      presentSuccessFeedback("Evaluated task board")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func syncTaskBoard(request: TaskBoardSyncRequest) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    return await syncAndRefreshTaskBoardDashboard(
      using: client,
      request: request,
      successMessage: "Synced task board"
    )
  }

  @discardableResult
  public func dispatchTaskBoard(
    request: TaskBoardDispatchRequest,
    refreshDashboard: Bool = true
  ) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.dispatchTaskBoard(request: request)
      }
      recordRequestSuccess()
      globalTaskBoardDispatchSummary = measuredSummary.value
      if refreshDashboard {
        await refreshTaskBoardDashboardSnapshot(using: client)
      }
      presentSuccessFeedback(
        request.dryRun ? "Prepared task board dispatch" : "Dispatched task board"
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func auditTaskBoard(status: TaskBoardStatus? = nil) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.auditTaskBoard(status: status)
      }
      recordRequestSuccess()
      globalTaskBoardItemAuditSummary = measuredSummary.value
      presentSuccessFeedback("Loaded task board audit")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func refreshTaskBoardProjects(status: TaskBoardStatus? = nil) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredProjects = try await Self.measureOperation {
        try await client.taskBoardProjects(status: status)
      }
      recordRequestSuccess()
      globalTaskBoardProjects = measuredProjects.value
      presentSuccessFeedback("Loaded task board projects")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func refreshTaskBoardMachines(status: TaskBoardStatus? = nil) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredMachines = try await Self.measureOperation {
        try await client.taskBoardMachines(status: status)
      }
      recordRequestSuccess()
      globalTaskBoardMachines = measuredMachines.value
      presentSuccessFeedback("Loaded task board machines")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

}
