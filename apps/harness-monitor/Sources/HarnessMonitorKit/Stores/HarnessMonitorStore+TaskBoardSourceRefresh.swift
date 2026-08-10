import Foundation

private struct TaskBoardSourceRefreshError: LocalizedError {
  let errorDescription: String?

  init(_ message: String) {
    errorDescription = message
  }
}

extension HarnessMonitorStore {
  @discardableResult
  func syncAndRefreshTaskBoardDashboard(
    access: TaskBoardClientAccess,
    request: TaskBoardSyncRequest,
    successMessage: String? = nil,
    failureMessagePrefix: String? = nil,
    activityKey: String? = nil,
    activityTitle: String? = nil,
    feedbackPosition: ActionFeedback.Position = .topTrailing
  ) async -> Bool {
    let client = access.client
    updateTaskBoardRefreshActivity(
      key: activityKey,
      title: activityTitle,
      message: "Syncing task sources",
      position: feedbackPosition
    )
    defer { dismissTaskBoardRefreshActivity(key: activityKey) }
    do {
      let measuredSummary = try await Self.measureOperation {
        try await client.syncTaskBoard(request: request)
      }
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      globalTaskBoardSyncSummary = measuredSummary.value
      updateTaskBoardRefreshActivity(
        key: activityKey,
        title: activityTitle,
        message: "Board ready · refreshing task sources",
        position: feedbackPosition
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
      try requireCurrentTaskBoardClientAccess(access)
      let completion = try await waitForTaskBoardSourceRefresh(access: access)
      if taskBoardSyncPhase == .stopping || completion.cancelled {
        finishStoppedTaskBoardSync(using: client, position: feedbackPosition)
        return false
      }
      if let error = completion.error {
        throw TaskBoardSourceRefreshError(error)
      }
      if let summary = completion.summary {
        globalTaskBoardSyncSummary = summary
      }
      updateTaskBoardRefreshActivity(
        key: activityKey,
        title: activityTitle,
        message: "Loading refreshed tasks",
        position: feedbackPosition
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
      try requireCurrentTaskBoardClientAccess(access)
      if let successMessage {
        presentSuccessFeedback(successMessage, position: feedbackPosition)
      }
      return true
    } catch is CancellationError {
      if taskBoardSyncPhase == .stopping,
        (try? requireCurrentTaskBoardClientAccess(access)) != nil
      {
        finishStoppedTaskBoardSync(using: client, position: feedbackPosition)
      }
      return false
    } catch {
      guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else {
        return false
      }
      if taskBoardSyncPhase == .stopping {
        finishStoppedTaskBoardSync(using: client, position: feedbackPosition)
        return false
      }
      updateTaskBoardRefreshActivity(
        key: activityKey,
        title: activityTitle,
        message: "Reloading current tasks",
        position: feedbackPosition
      )
      await refreshTaskBoardDashboardSnapshot(using: client)
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

  private func waitForTaskBoardSourceRefresh(
    access: TaskBoardClientAccess
  ) async throws -> TaskBoardSyncStatusResponse {
    let client = access.client
    let deadline = ContinuousClock.now.advanced(by: .seconds(300))
    while true {
      try requireCurrentTaskBoardClientAccess(access)
      let status = try await client.taskBoardSyncStatus()
      try requireCurrentTaskBoardClientAccess(access)
      guard status.active else { return status }
      if taskBoardSyncPhase == .stopping, !status.cancellationRequested {
        _ = try await client.cancelTaskBoardSync()
      }
      try Task.checkCancellation()
      if ContinuousClock.now > deadline {
        throw TaskBoardSourceRefreshError("task source refresh timed out after 5 min")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func finishStoppedTaskBoardSync(
    using client: any HarnessMonitorClientProtocol,
    position: ActionFeedback.Position
  ) {
    scheduleGitHubTaskBoardRefresh(using: client)
    presentSuccessFeedback("Task source refresh stopped", position: position)
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
      position: position
    )
  }

  private func dismissTaskBoardRefreshActivity(key: String?) {
    guard let key else { return }
    toast.dismissActivity(key: key)
  }
}
