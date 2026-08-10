extension HarnessMonitorStore {
  func processGlobalStreamEvent(
    _ event: DaemonPushEvent,
    using client: any HarnessMonitorClientProtocol,
    hasSeenReady: inout Bool,
    connectionFence: ConnectionAttemptFence? = nil
  ) async -> Bool {
    guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else {
      return false
    }
    guard case .ready = event.kind else {
      await applyGlobalPushEventFromStream(event)
      return isCurrentConnectionAttemptFenceIfProvided(connectionFence)
    }
    guard
      let containmentFence = connectionFence?.containment
        ?? (try? currentLegacyContainmentFence())
    else {
      return false
    }
    guard
      let databaseAccessGeneration = await reserveTaskBoardDatabaseAccessForReady(
        using: client,
        hasSeenReady: hasSeenReady,
        connectionFence: connectionFence
      )
    else { return false }
    let accessFence = TaskBoardAccessFence(
      containment: containmentFence,
      connection: connectionFence,
      databaseAccessGeneration: databaseAccessGeneration
    )
    if hasSeenReady {
      guard
        await syncStoredTaskBoardCredentialsForNewDaemon(
          using: client,
          accessFence: accessFence
        )
      else {
        if isCurrentTaskBoardAccessFence(accessFence) {
          markConnectionOffline("Connected daemon Task Board could not be synchronized")
          scheduleReconnectAfterConnectionFailure()
        }
        return false
      }
    } else {
      hasSeenReady = true
    }
    guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else {
      return false
    }
    await recoverGlobalPushOnlyState(using: client, connectionFence: connectionFence)
    return isCurrentTaskBoardAccessFence(accessFence)
  }

  private func reserveTaskBoardDatabaseAccessForReady(
    using client: any HarnessMonitorClientProtocol,
    hasSeenReady: Bool,
    connectionFence: ConnectionAttemptFence?
  ) async -> UInt64? {
    guard hasSeenReady else {
      return taskBoardRuntimeState.connection.databaseAccessGeneration
    }
    do {
      return try await invalidateTaskBoardDatabaseAccess(using: client)
    } catch is CancellationError {
      return nil
    } catch {
      guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else { return nil }
      markConnectionOffline(error.localizedDescription)
      scheduleReconnectAfterConnectionFailure()
      return nil
    }
  }

  func recoverGlobalPushOnlyState(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence? = nil
  ) async {
    do {
      let measuredLogLevel = try await Self.measureOperation {
        try await client.logLevel()
      }
      guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else { return }
      recordRequestSuccess()
      daemonLogLevel = measuredLogLevel.value.level
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "websocket reconnect log-level refresh failed: \(err, privacy: .public)"
      )
    }
    guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else { return }
    await recoverGitHubDataPushState(using: client, connectionFence: connectionFence)
  }
}
