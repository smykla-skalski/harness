import Foundation

extension HarnessMonitorStore {
  func mutateTaskBoardPlanning(
    actionName: String,
    mutation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> TaskBoardPlanningResponse
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredResponse = try await Self.measureOperation {
        try await mutation(client)
      }
      recordRequestSuccess()
      mergeTaskBoardItem(measuredResponse.value.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback(actionName)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  func mutateTaskBoardOrchestrator(
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

  func refreshTaskBoardDashboardSnapshot(
    using client: any HarnessMonitorClientProtocol,
    fallbackStatus: TaskBoardOrchestratorStatus? = nil
  ) async {
    cancelInitialTaskBoardConfirmationRefresh()
    let snapshot = await Self.loadTaskBoardRefreshSnapshot(using: client)
    applyTaskBoardDashboardSnapshot(snapshot, fallbackStatus: fallbackStatus)
  }

  func applyTaskBoardDashboardSnapshot(
    _ snapshot: TaskBoardRefreshSnapshot,
    fallbackStatus: TaskBoardOrchestratorStatus? = nil
  ) {
    let resolvedItems = snapshot.items.value ?? globalTaskBoardItems
    let resolvedStatus =
      if let measuredStatus = snapshot.orchestratorStatus.measured {
        measuredStatus.value ?? fallbackStatus
      } else {
        fallbackStatus ?? globalTaskBoardOrchestratorStatus
      }
    let didChangeTaskBoardSnapshot =
      globalTaskBoardItems != resolvedItems
      || globalTaskBoardOrchestratorStatus != resolvedStatus

    withUISyncBatch {
      // Explicit task-board refreshes may clear an authoritative empty result, but
      // unavailable endpoints must not erase the last visible board snapshot.
      globalTaskBoardItems = resolvedItems
      globalTaskBoardOrchestratorStatus = resolvedStatus
    }
    if didChangeTaskBoardSnapshot {
      scheduleTaskBoardSnapshotCacheWrite(
        items: resolvedItems,
        orchestratorStatus: resolvedStatus
      )
    }
  }

  @discardableResult
  func syncAndRefreshTaskBoardDashboard(
    using client: any HarnessMonitorClientProtocol,
    request: TaskBoardSyncRequest,
    successMessage: String? = nil,
    failureMessagePrefix: String? = nil
  ) async -> Bool {
    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.syncTaskBoard(request: request)
      }
      recordRequestSuccess()
      globalTaskBoardSyncSummary = measuredSummary.value
      await refreshTaskBoardDashboardSnapshot(using: client)
      if let successMessage {
        presentSuccessFeedback(successMessage)
      }
      return true
    } catch {
      await refreshTaskBoardDashboardSnapshot(using: client)
      let failureDescription =
        if let failureMessagePrefix {
          "\(failureMessagePrefix): \(error.localizedDescription)"
        } else {
          error.localizedDescription
        }
      presentFailureFeedback(failureDescription)
      return false
    }
  }

  func mergeTaskBoardItem(_ item: TaskBoardItem) {
    guard let index = globalTaskBoardItems.firstIndex(where: { $0.id == item.id }) else {
      globalTaskBoardItems.append(item)
      return
    }
    globalTaskBoardItems[index] = item
  }
}
