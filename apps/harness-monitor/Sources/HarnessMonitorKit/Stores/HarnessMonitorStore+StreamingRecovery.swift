extension HarnessMonitorStore {
  func processGlobalStreamEvent(
    _ event: DaemonPushEvent,
    using client: any HarnessMonitorClientProtocol,
    hasSeenReady: inout Bool
  ) async -> Bool {
    guard case .ready = event.kind else {
      await applyGlobalPushEventFromStream(event)
      return true
    }
    guard let containmentFence = try? currentLegacyContainmentFence() else {
      return false
    }
    if hasSeenReady {
      guard
        await syncStoredTaskBoardCredentialsForNewDaemon(
          using: client,
          containmentFence: containmentFence
        )
      else {
        if isCurrentLegacyContainmentFence(containmentFence) {
          markConnectionOffline("Connected daemon has no database-backed Task Board")
          scheduleReconnectAfterConnectionFailure()
        }
        return false
      }
    } else {
      hasSeenReady = true
    }
    guard isCurrentLegacyContainmentFence(containmentFence) else {
      return false
    }
    await recoverGlobalPushOnlyState(using: client)
    return isCurrentLegacyContainmentFence(containmentFence)
  }

  func recoverGlobalPushOnlyState(
    using client: any HarnessMonitorClientProtocol
  ) async {
    do {
      let measuredLogLevel = try await Self.measureOperation {
        try await client.logLevel()
      }
      recordRequestSuccess()
      daemonLogLevel = measuredLogLevel.value.level
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "websocket reconnect log-level refresh failed: \(err, privacy: .public)"
      )
    }
    await recoverGitHubDataPushState(using: client)
  }
}
