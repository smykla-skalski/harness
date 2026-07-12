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
    failureMessagePrefix: String? = nil,
    activityKey: String? = nil,
    activityTitle: String? = nil,
    feedbackPosition: ActionFeedback.Position = .topTrailing
  ) async -> Bool {
    updateTaskBoardRefreshActivity(
      key: activityKey,
      title: activityTitle,
      message: "Syncing task sources",
      position: feedbackPosition
    )
    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.syncTaskBoard(request: request)
      }
      recordRequestSuccess()
      globalTaskBoardSyncSummary = measuredSummary.value
      updateTaskBoardRefreshActivity(
        key: activityKey,
        title: activityTitle,
        message: "Loading refreshed tasks",
        position: feedbackPosition
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
      dismissTaskBoardRefreshActivity(key: activityKey)
      if let successMessage {
        presentSuccessFeedback(successMessage, position: feedbackPosition)
      }
      return true
    } catch {
      updateTaskBoardRefreshActivity(
        key: activityKey,
        title: activityTitle,
        message: "Reloading current tasks",
        position: feedbackPosition
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
      dismissTaskBoardRefreshActivity(key: activityKey)
      let failureDescription =
        if let failureMessagePrefix {
          "\(failureMessagePrefix): \(error.localizedDescription)"
        } else {
          error.localizedDescription
        }
      presentFailureFeedback(failureDescription, position: feedbackPosition)
      return false
    }
  }

  private func updateTaskBoardRefreshActivity(
    key: String?,
    title: String?,
    message: String,
    position: ActionFeedback.Position
  ) {
    guard let key else { return }
    toast.updateActivity(
      key: key,
      message: message,
      title: title,
      accessibilityIdentifier: "harness.toast.task-board-refresh",
      position: position
    )
  }

  private func dismissTaskBoardRefreshActivity(key: String?) {
    guard let key else { return }
    toast.dismissActivity(key: key)
  }

  func mergeTaskBoardItem(_ item: TaskBoardItem) {
    guard let index = globalTaskBoardItems.firstIndex(where: { $0.id == item.id }) else {
      globalTaskBoardItems.append(item)
      return
    }
    globalTaskBoardItems[index] = item
  }
}
