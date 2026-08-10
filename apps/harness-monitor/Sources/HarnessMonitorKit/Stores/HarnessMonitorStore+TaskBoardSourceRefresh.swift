import Foundation

private struct TaskBoardSourceRefreshError: LocalizedError {
  let errorDescription: String?

  init(_ message: String) {
    errorDescription = message
  }
}

private struct TaskBoardSourceRefreshPresentation {
  let successMessage: String?
  let failureMessagePrefix: String?
  let activityKey: String?
  let activityTitle: String?
  let feedbackPosition: ActionFeedback.Position
}

extension HarnessMonitorStore {
  @discardableResult
  public func syncTaskBoard(request: TaskBoardSyncRequest) async -> Bool {
    guard let access = availableTaskBoardClientAccess, taskBoardSyncPhase == .idle else {
      return false
    }
    setTaskBoardSyncPhase(.syncing)
    defer { setTaskBoardSyncPhase(.idle) }
    return await syncAndRefreshTaskBoardDashboard(
      access: access,
      request: request,
      successMessage: "Synced task board"
    )
  }

  @discardableResult
  public func cancelTaskBoardSync() async -> Bool {
    guard let access = availableTaskBoardClientAccess, taskBoardSyncPhase == .syncing else {
      return false
    }
    setTaskBoardSyncPhase(.stopping)
    do {
      _ = try await access.client.cancelTaskBoardSync()
      try requireCurrentTaskBoardClientAccess(access)
      cancelTaskBoardDashboardSnapshotRefresh()
      recordRequestSuccess()
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return false }
      setTaskBoardSyncPhase(.syncing)
      presentFailureFeedback("Could not stop task board sync: \(error.localizedDescription)")
      return false
    }
  }

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
    let presentation = TaskBoardSourceRefreshPresentation(
      successMessage: successMessage,
      failureMessagePrefix: failureMessagePrefix,
      activityKey: activityKey,
      activityTitle: activityTitle,
      feedbackPosition: feedbackPosition
    )
    updateTaskBoardRefreshActivity(
      key: activityKey,
      title: activityTitle,
      message: "Syncing task sources",
      position: feedbackPosition
    )
    defer { dismissTaskBoardRefreshActivity(key: activityKey) }
    do {
      return try await performTaskBoardSourceSync(
        access: access,
        request: request,
        presentation: presentation
      )
    } catch is CancellationError {
      return handleTaskBoardSourceSyncCancellation(
        access: access,
        feedbackPosition: feedbackPosition
      )
    } catch {
      return await handleTaskBoardSourceSyncFailure(
        error,
        access: access,
        presentation: presentation
      )
    }
  }

  private func performTaskBoardSourceSync(
    access: TaskBoardClientAccess,
    request: TaskBoardSyncRequest,
    presentation: TaskBoardSourceRefreshPresentation
  ) async throws -> Bool {
    let client = access.client
    let measuredSummary = try await Self.measureOperation {
      try await client.syncTaskBoard(request: request)
    }
    try requireCurrentTaskBoardClientAccess(access)
    recordRequestSuccess()
    globalTaskBoardSyncSummary = measuredSummary.value
    updateTaskBoardRefreshActivity(
      key: presentation.activityKey,
      title: presentation.activityTitle,
      message: "Board ready · refreshing task sources",
      position: presentation.feedbackPosition
    )
    guard await refreshTaskBoardDashboardSnapshot(using: client, access: access) else {
      return false
    }
    try requireCurrentTaskBoardClientAccess(access)
    let completion = try await waitForTaskBoardSourceRefresh(access: access)
    if taskBoardSyncPhase == .stopping || completion.cancelled {
      finishStoppedTaskBoardSync(using: client, position: presentation.feedbackPosition)
      return false
    }
    if let error = completion.error {
      throw TaskBoardSourceRefreshError(error)
    }
    if let summary = completion.summary {
      globalTaskBoardSyncSummary = summary
    }
    updateTaskBoardRefreshActivity(
      key: presentation.activityKey,
      title: presentation.activityTitle,
      message: "Loading refreshed tasks",
      position: presentation.feedbackPosition
    )
    guard await refreshTaskBoardDashboardSnapshot(using: client, access: access) else {
      return false
    }
    try requireCurrentTaskBoardClientAccess(access)
    if let successMessage = presentation.successMessage {
      presentSuccessFeedback(successMessage, position: presentation.feedbackPosition)
    }
    return true
  }

  private func handleTaskBoardSourceSyncCancellation(
    access: TaskBoardClientAccess,
    feedbackPosition: ActionFeedback.Position
  ) -> Bool {
    if taskBoardSyncPhase == .stopping,
      (try? requireCurrentTaskBoardClientAccess(access)) != nil
    {
      finishStoppedTaskBoardSync(using: access.client, position: feedbackPosition)
    }
    return false
  }

  private func handleTaskBoardSourceSyncFailure(
    _ error: any Error,
    access: TaskBoardClientAccess,
    presentation: TaskBoardSourceRefreshPresentation
  ) async -> Bool {
    guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else {
      return false
    }
    if taskBoardSyncPhase == .stopping {
      finishStoppedTaskBoardSync(
        using: access.client,
        position: presentation.feedbackPosition
      )
      return false
    }
    updateTaskBoardRefreshActivity(
      key: presentation.activityKey,
      title: presentation.activityTitle,
      message: "Reloading current tasks",
      position: presentation.feedbackPosition
    )
    guard
      await refreshTaskBoardDashboardSnapshot(
        using: access.client,
        access: access
      )
    else { return false }
    let failureDescription =
      if let failureMessagePrefix = presentation.failureMessagePrefix {
        "\(failureMessagePrefix): \(error.localizedDescription)"
      } else {
        error.localizedDescription
      }
    presentFailureFeedback(failureDescription, position: presentation.feedbackPosition)
    return false
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
