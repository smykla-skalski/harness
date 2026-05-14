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
    _ = await syncAndRefreshTaskBoardDashboard(using: client)
  }

  @discardableResult
  public func updateTaskBoardItemStatus(id: String, status: TaskBoardStatus) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredItem = try await Self.measureOperation {
        try await client.updateTaskBoardItem(
          id: id,
          request: TaskBoardUpdateItemRequest(status: status)
        )
      }
      recordRequestSuccess()
      mergeTaskBoardItem(measuredItem.value)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback("Moved task board item")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
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
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.evaluateTaskBoard(
          request: TaskBoardEvaluateRequest(status: status, itemId: itemID, dryRun: dryRun)
        )
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

  private func mutateTaskBoardOrchestrator(
    actionName: String,
    mutation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> TaskBoardOrchestratorStatus
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredStatus = try await Self.measureOperation {
        try await mutation(client)
      }
      recordRequestSuccess()
      globalTaskBoardOrchestratorStatus = measuredStatus.value
      await refreshTaskBoardDashboardSnapshot(using: client, fallbackStatus: measuredStatus.value)
      presentSuccessFeedback(actionName)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private func refreshTaskBoardDashboardSnapshot(
    using client: any HarnessMonitorClientProtocol,
    fallbackStatus: TaskBoardOrchestratorStatus? = nil
  ) async {
    async let items = Self.loadTaskBoardItemsSnapshot(using: client)
    async let status = Self.loadTaskBoardOrchestratorStatusSnapshot(using: client)
    let measuredItems = await items
    let measuredStatus = await status

    withUISyncBatch {
      globalTaskBoardItems = measuredItems.value
      globalTaskBoardOrchestratorStatus = measuredStatus.value ?? fallbackStatus
    }
  }

  @discardableResult
  func syncAndRefreshTaskBoardDashboard(
    using client: any HarnessMonitorClientProtocol,
    failureMessagePrefix: String? = nil
  ) async -> Bool {
    do {
      _ = try await Self.measureOperation {
        try await client.syncTaskBoard(request: Self.taskBoardDashboardSyncRequest)
      }
      recordRequestSuccess()
      await refreshTaskBoardDashboardSnapshot(using: client)
      return true
    } catch {
      await refreshTaskBoardDashboardSnapshot(using: client)
      let failureDescription = if let failureMessagePrefix {
        "\(failureMessagePrefix): \(error.localizedDescription)"
      } else {
        error.localizedDescription
      }
      presentFailureFeedback(failureDescription)
      return false
    }
  }

  private func mergeTaskBoardItem(_ item: TaskBoardItem) {
    guard let index = globalTaskBoardItems.firstIndex(where: { $0.id == item.id }) else {
      globalTaskBoardItems.append(item)
      return
    }
    globalTaskBoardItems[index] = item
  }

}
