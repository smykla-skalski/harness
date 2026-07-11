extension HarnessMonitorStore {
  func applyGlobalDataPushEventFromStream(_ event: DaemonPushEvent) async -> Bool {
    switch event.kind {
    case .auditEvent(let auditEvent):
      await applyApplicationAuditEventFromStream(auditEvent)
    case .githubDataChanged:
      applyGlobalPushEvent(event)
      if let client {
        scheduleGitHubTaskBoardRefresh(using: client)
      }
    default:
      return false
    }
    return true
  }

  func scheduleGitHubTaskBoardRefresh(using client: any HarnessMonitorClientProtocol) {
    cacheWriteSync.githubDataRefreshGeneration &+= 1
    let generation = cacheWriteSync.githubDataRefreshGeneration
    cacheWriteSync.githubDataTaskBoardRefreshTask?.cancel()
    cacheWriteSync.githubDataTaskBoardRefreshTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return
      }
      guard let self, self.cacheWriteSync.githubDataRefreshGeneration == generation else { return }
      let snapshot = await Self.loadTaskBoardRefreshSnapshot(using: client)
      guard self.cacheWriteSync.githubDataRefreshGeneration == generation else { return }
      self.cancelInitialTaskBoardConfirmationRefresh()
      self.applyTaskBoardDashboardSnapshot(snapshot)
      self.cacheWriteSync.githubDataTaskBoardRefreshTask = nil
    }
  }

  func recoverGitHubDataPushState(using client: any HarnessMonitorClientProtocol) async {
    do {
      let githubStatus = try await client.githubStatus()
      if let revision = githubStatus.dataRevision,
        contentUI.dashboard.githubDataRevision != revision
      {
        contentUI.dashboard.latestGitHubDataChange = nil
        contentUI.dashboard.githubDataRevision = revision
      }
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "websocket reconnect GitHub data refresh failed: \(err, privacy: .public)"
      )
    }
    scheduleGitHubTaskBoardRefresh(using: client)
  }
}
