import Foundation

extension HarnessMonitorStore {
  private static let taskBoardRefreshCoalescingDelay: Duration = .milliseconds(50)

  func refreshTaskBoardDashboardSnapshot(
    using client: any HarnessMonitorClientProtocol,
    fallbackStatus: TaskBoardOrchestratorStatus? = nil
  ) async {
    cancelInitialTaskBoardConfirmationRefresh()
    let requestGeneration = scheduleTaskBoardDashboardSnapshotRefresh(
      using: client,
      fallbackStatus: fallbackStatus
    )
    await waitForTaskBoardDashboardSnapshotRefresh(requestGeneration)
  }

  func scheduleGitHubTaskBoardRefresh(
    using client: any HarnessMonitorClientProtocol,
    includeItems: Bool = true,
    includeOrchestratorStatus: Bool = true
  ) {
    _ = scheduleTaskBoardDashboardSnapshotRefresh(
      using: client,
      includeItems: includeItems,
      includeOrchestratorStatus: includeOrchestratorStatus
    )
  }

  func beginTaskBoardDashboardRefreshDeferral() {
    cacheWriteSync.taskBoardRefreshDeferralDepth += 1
  }

  func finishTaskBoardDashboardRefreshDeferral(
    using client: any HarnessMonitorClientProtocol
  ) async {
    guard cacheWriteSync.taskBoardRefreshDeferralDepth > 0 else { return }
    cacheWriteSync.taskBoardRefreshDeferralDepth -= 1
    guard cacheWriteSync.taskBoardRefreshDeferralDepth == 0 else { return }

    let requestGeneration = scheduleTaskBoardDashboardSnapshotRefresh(using: client)
    await waitForTaskBoardDashboardSnapshotRefresh(requestGeneration)
  }

  private func scheduleTaskBoardDashboardSnapshotRefresh(
    using client: any HarnessMonitorClientProtocol,
    includeItems: Bool = true,
    includeOrchestratorStatus: Bool = true,
    fallbackStatus: TaskBoardOrchestratorStatus? = nil
  ) -> UInt64 {
    cacheWriteSync.taskBoardRefreshRequestGeneration &+= 1
    let requestGeneration = cacheWriteSync.taskBoardRefreshRequestGeneration
    cacheWriteSync.pendingTaskBoardItemsRefresh =
      cacheWriteSync.pendingTaskBoardItemsRefresh || includeItems
    cacheWriteSync.pendingTaskBoardOrchestratorRefresh =
      cacheWriteSync.pendingTaskBoardOrchestratorRefresh || includeOrchestratorStatus
    if let fallbackStatus {
      cacheWriteSync.pendingTaskBoardFallbackStatus = fallbackStatus
    }
    startTaskBoardDashboardSnapshotRefreshIfNeeded(using: client)
    return requestGeneration
  }

  func waitForTaskBoardDashboardSnapshotRefresh(
    _ requestGeneration: UInt64
  ) async {
    while cacheWriteSync.taskBoardRefreshCompletedGeneration < requestGeneration {
      if let refreshTask = cacheWriteSync.taskBoardRefreshTask {
        await refreshTask.value
      } else {
        await withCheckedContinuation { continuation in
          if cacheWriteSync.taskBoardRefreshCompletedGeneration >= requestGeneration {
            continuation.resume()
          } else {
            cacheWriteSync.taskBoardRefreshCompletionWaiters[requestGeneration, default: []]
              .append(continuation)
          }
        }
      }
    }
  }

  func resumeCompletedTaskBoardDashboardSnapshotRefreshWaiters() {
    let completedGeneration = cacheWriteSync.taskBoardRefreshCompletedGeneration
    let generations = cacheWriteSync.taskBoardRefreshCompletionWaiters.keys
      .filter { $0 <= completedGeneration }
      .sorted()
    for generation in generations {
      let waiters = cacheWriteSync.taskBoardRefreshCompletionWaiters
        .removeValue(forKey: generation) ?? []
      for waiter in waiters {
        waiter.resume()
      }
    }
  }

  private func startTaskBoardDashboardSnapshotRefreshIfNeeded(
    using client: any HarnessMonitorClientProtocol
  ) {
    guard cacheWriteSync.taskBoardRefreshTask == nil,
      cacheWriteSync.taskBoardRefreshDeferralDepth == 0
    else { return }

    cacheWriteSync.taskBoardRefreshGeneration &+= 1
    let generation = cacheWriteSync.taskBoardRefreshGeneration
    cacheWriteSync.taskBoardRefreshTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.taskBoardRefreshCoalescingDelay)
      } catch {
        return
      }
      guard let self, self.cacheWriteSync.taskBoardRefreshGeneration == generation else {
        return
      }

      let includeItems = self.cacheWriteSync.pendingTaskBoardItemsRefresh
      let includeOrchestratorStatus =
        self.cacheWriteSync.pendingTaskBoardOrchestratorRefresh
      let fallbackStatus = self.cacheWriteSync.pendingTaskBoardFallbackStatus
      let completedRequestGeneration =
        self.cacheWriteSync.taskBoardRefreshRequestGeneration
      self.cacheWriteSync.pendingTaskBoardItemsRefresh = false
      self.cacheWriteSync.pendingTaskBoardOrchestratorRefresh = false
      self.cacheWriteSync.pendingTaskBoardFallbackStatus = nil

      let snapshot = await Self.loadTaskBoardRefreshSnapshot(
        using: client,
        includeItems: includeItems,
        includeOrchestratorStatus: includeOrchestratorStatus
      )
      guard self.cacheWriteSync.taskBoardRefreshGeneration == generation else { return }

      self.cancelInitialTaskBoardConfirmationRefresh()
      self.applyTaskBoardDashboardSnapshot(snapshot, fallbackStatus: fallbackStatus)
      self.cacheWriteSync.taskBoardRefreshCompletedGeneration =
        completedRequestGeneration
      self.resumeCompletedTaskBoardDashboardSnapshotRefreshWaiters()
      self.cacheWriteSync.taskBoardRefreshTask = nil

      if self.cacheWriteSync.pendingTaskBoardItemsRefresh
        || self.cacheWriteSync.pendingTaskBoardOrchestratorRefresh
      {
        self.startTaskBoardDashboardSnapshotRefreshIfNeeded(using: client)
      }
    }
  }
}
