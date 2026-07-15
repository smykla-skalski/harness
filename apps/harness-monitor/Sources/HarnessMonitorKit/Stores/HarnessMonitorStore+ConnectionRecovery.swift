extension HarnessMonitorStore {
  var shouldAbandonConnectionAttempt: Bool {
    Task.isCancelled || isAppLifecycleSuspended || connection.isPreparingForTermination
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

  func scheduleReconnectAfterConnectionFailure() {
    guard
      connectionRecoveryTask == nil,
      !isBootstrapping,
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
      guard self.shouldRunConnectionRecovery(generation: generation) else {
        return
      }
      await self.reconnect()
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
    connectionState = .idle
  }

  func discardActiveConnection() async {
    guard let disconnectedClient = disconnectActiveConnection() else {
      return
    }
    await disconnectedClient.shutdown()
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

  private func shouldRunConnectionRecovery(generation: UInt64) -> Bool {
    !Task.isCancelled
      && generation == connectionRecoveryGeneration
      && !isBootstrapping
      && !isReconnecting
      && !isAppLifecycleSuspended
      && !connection.isPreparingForTermination
  }

  private func finishConnectionRecovery(generation: UInt64) {
    guard generation == connectionRecoveryGeneration else {
      return
    }
    connectionRecoveryTask = nil
  }
}
