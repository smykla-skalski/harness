struct ConnectionAttemptFence: Sendable {
  let generation: UInt64
  let containment: LegacyContainmentFence
}

extension HarnessMonitorStore {
  var shouldAbandonConnectionAttempt: Bool {
    Task.isCancelled || !connection.legacyContainmentHealthy
      || isAppLifecycleSuspended || connection.isPreparingForTermination
  }

  var hasLiveConnectionActivity: Bool {
    client != nil
      || globalStreamTask != nil
      || connectionProbeTask != nil
      || isBootstrapping
      || isReconnecting
      || remoteDaemonReconnectTask != nil
      || connectionRecoveryTask != nil
  }

  var connectionRecoveryTask: Task<Void, Never>? {
    get { connection.connectionRecoveryTask }
    set { connection.connectionRecoveryTask = newValue }
  }

  var connectionRecoveryGeneration: UInt64 {
    get { connection.connectionRecoveryGeneration }
    set { connection.connectionRecoveryGeneration = newValue }
  }

  var connectionRecoveryRetryDelays: [Duration] {
    get { connection.recoveryRetryDelays }
    set { connection.recoveryRetryDelays = newValue }
  }

  func beginConnectionAttempt() throws -> ConnectionAttemptFence {
    let containment = try currentLegacyContainmentFence()
    invalidateConnectionAttempts()
    return ConnectionAttemptFence(
      generation: connection.connectionAttemptGeneration,
      containment: containment
    )
  }

  func invalidateConnectionAttempts() {
    connection.connectionAttemptGeneration &+= 1
    cancelSecretMigrationConsentIfPending()
    cancelTaskBoardDashboardSnapshotRefresh()
  }

  func currentConnectionAttemptFence() throws -> ConnectionAttemptFence {
    ConnectionAttemptFence(
      generation: connection.connectionAttemptGeneration,
      containment: try currentLegacyContainmentFence()
    )
  }

  func isCurrentConnectionAttemptFence(_ fence: ConnectionAttemptFence) -> Bool {
    fence.generation == connection.connectionAttemptGeneration
      && isCurrentLegacyContainmentFence(fence.containment)
  }

  func isCurrentConnectionAttemptFenceIfProvided(
    _ fence: ConnectionAttemptFence?
  ) -> Bool {
    guard let fence else { return !shouldAbandonConnectionAttempt }
    return isCurrentConnectionAttemptFence(fence)
  }

  func scheduleReconnectAfterConnectionFailure() {
    if connectionState == .online {
      markConnectionOffline("Daemon connection interrupted")
    }
    if usesRemoteDaemon {
      scheduleRemoteDaemonReconnect(immediately: true)
      return
    }
    guard
      connectionRecoveryTask == nil,
      !isReconnecting,
      !isAppLifecycleSuspended,
      !connection.isPreparingForTermination
    else {
      return
    }

    connectionRecoveryGeneration &+= 1
    let generation = connectionRecoveryGeneration
    connectionRecoveryTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.finishConnectionRecovery(generation: generation) }
      await self.runConnectionRecovery(generation: generation)
    }
  }

  func stopConnectionRecovery() {
    connectionRecoveryGeneration &+= 1
    connectionRecoveryTask?.cancel()
    connectionRecoveryTask = nil
  }

  func abandonConnectionAttempt(
    using client: any HarnessMonitorClientProtocol,
    wasAdopted: Bool
  ) async {
    if wasAdopted {
      await discardActiveConnection()
    } else {
      await client.shutdown()
      self.client = nil
      taskBoardDatabaseInstanceID = nil
    }
    if connection.legacyContainmentHealthy {
      connectionState = .idle
    }
  }

  func discardActiveConnection() async {
    guard let disconnectedClient = disconnectActiveConnection() else {
      return
    }
    await disconnectedClient.shutdown()
  }

  func settleAbandonedConnectionAttempt(
    using candidate: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) async {
    guard !isCurrentConnectionAttemptFence(connectionFence) else { return }
    if shouldAbandonConnectionAttempt {
      if self.client === candidate {
        await discardActiveConnection()
      }
      if connection.legacyContainmentHealthy {
        connectionState = .idle
      }
      return
    }
    guard self.client !== candidate else { return }
    await candidate.shutdown()
  }

  func discardFailedConnectionUnlessReplaced() async -> Bool {
    guard let disconnectedClient = disconnectActiveConnection() else {
      return false
    }
    guard let postDisconnectFence = try? currentConnectionAttemptFence() else {
      await disconnectedClient.shutdown()
      return false
    }
    await disconnectedClient.shutdown()
    return isCurrentConnectionAttemptFence(postDisconnectFence)
  }

  func applyConnectionFailure(_ error: any Error) async {
    let underlyingError = Self.underlyingRefreshSnapshotError(error)
    let wasUsingRemoteDaemon = usesRemoteDaemon
    if wasUsingRemoteDaemon {
      handleRemoteDaemonConnectionFailure(underlyingError)
    }
    markConnectionOffline(Self.describeRefreshSnapshotError(error))
    await restorePersistedSessionState()
    if wasUsingRemoteDaemon {
      scheduleRemoteDaemonReconnect(after: underlyingError)
    }
  }

  private func shouldContinueConnectionRecovery(generation: UInt64) -> Bool {
    !Task.isCancelled
      && generation == connectionRecoveryGeneration
      && connectionState != .online
      && !isAppLifecycleSuspended
      && !connection.isPreparingForTermination
  }

  private func runConnectionRecovery(generation: UInt64) async {
    guard !connectionRecoveryRetryDelays.isEmpty else { return }
    var attempt = 0
    while true {
      let delayIndex = min(attempt, connectionRecoveryRetryDelays.count - 1)
      do {
        try await Task.sleep(for: connectionRecoveryRetryDelays[delayIndex])
      } catch {
        return
      }
      guard shouldContinueConnectionRecovery(generation: generation) else {
        return
      }
      guard !isBootstrapping, !isReconnecting else { continue }
      await reconnect()
      guard connectionState != .online else {
        return
      }
      attempt += 1
    }
  }

  private func finishConnectionRecovery(generation: UInt64) {
    guard generation == connectionRecoveryGeneration else {
      return
    }
    connectionRecoveryTask = nil
  }
}
