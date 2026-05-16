import Foundation

extension HarnessMonitorStore {
  private static let taskBoardDashboardSyncRequest = TaskBoardSyncRequest(
    direction: .pull,
    dryRun: false
  )

  nonisolated static func loadTaskBoardItemsSnapshot(
    using client: any HarnessMonitorClientProtocol
  ) async -> MeasuredOperation<[TaskBoardItem]> {
    do {
      return try await measureOperation {
        try await client.taskBoardItems(status: nil)
      }
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board snapshot unavailable during refresh: \(description, privacy: .public)"
      )
      return MeasuredOperation(value: [], latencyMs: 0)
    }
  }

  nonisolated static func loadTaskBoardOrchestratorStatusSnapshot(
    using client: any HarnessMonitorClientProtocol
  ) async -> MeasuredOperation<TaskBoardOrchestratorStatus?> {
    do {
      let measuredStatus = try await measureOperation {
        try await client.taskBoardOrchestratorStatus()
      }
      return MeasuredOperation(value: measuredStatus.value, latencyMs: measuredStatus.latencyMs)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board orchestrator snapshot unavailable during refresh: \(description, privacy: .public)"
      )
      return MeasuredOperation(value: nil, latencyMs: 0)
    }
  }

  public func refreshTaskBoardDashboard() async {
    guard let client else {
      return
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }
    _ = await syncAndRefreshTaskBoardDashboard(
      using: client,
      request: Self.taskBoardDashboardSyncRequest
    )
  }

  @discardableResult
  public func updateTaskBoardItemStatus(id: String, status: TaskBoardStatus) async -> Bool {
    await updateTaskBoardItem(
      id: id,
      request: TaskBoardUpdateItemRequest(status: status),
      successMessage: "Moved task board item"
    )
  }

  @discardableResult
  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest,
    initialStatus: TaskBoardStatus = .new
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

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
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

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
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await Self.measureOperation {
        try await client.deleteTaskBoardItem(id: id)
      }
      recordRequestSuccess()
      globalTaskBoardItems.removeAll { $0.id == id }
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback("Deleted task board item")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
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
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.evaluateTaskBoard(request: request)
      }
      recordRequestSuccess()
      globalTaskBoardEvaluationSummary = measuredSummary.value
      await refreshTaskBoardDashboardSnapshot(using: client)
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
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }
    return await syncAndRefreshTaskBoardDashboard(
      using: client,
      request: request,
      successMessage: "Synced task board"
    )
  }

  @discardableResult
  public func dispatchTaskBoard(request: TaskBoardDispatchRequest) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.dispatchTaskBoard(request: request)
      }
      recordRequestSuccess()
      globalTaskBoardDispatchSummary = measuredSummary.value
      await refreshTaskBoardDashboardSnapshot(using: client)
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
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

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
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

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
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

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
