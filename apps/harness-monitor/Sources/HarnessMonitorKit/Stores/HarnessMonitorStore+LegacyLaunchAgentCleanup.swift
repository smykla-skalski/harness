struct LegacyContainmentFence: Sendable {
  let generation: UInt64
}

extension HarnessMonitorStore {
  private var requiresLegacyManagedLaunchAgentContainment: Bool {
    daemonOwnership == .managed || usesRemoteDaemon
  }

  func requireLegacyManagedLaunchAgentCleanup() async -> Bool {
    guard requiresLegacyManagedLaunchAgentContainment else {
      skipLegacyManagedLaunchAgentContainment()
      return true
    }
    startLegacyManagedLaunchAgentContainment(failureActive: false)
    do {
      try await daemonController.requireLegacyManagedLaunchAgentCleanup()
      return true
    } catch is CancellationError {
      await activateLegacyManagedLaunchAgentContainmentFailure(
        recoveryAuthorized: false
      )
      return false
    } catch {
      await activateLegacyManagedLaunchAgentContainmentFailure()
      return false
    }
  }

  func requireLegacyManagedLaunchAgentCleanupOrThrow() async throws {
    guard requiresLegacyManagedLaunchAgentContainment else {
      skipLegacyManagedLaunchAgentContainment()
      return
    }
    startLegacyManagedLaunchAgentContainment(failureActive: false)
    do {
      try await daemonController.requireLegacyManagedLaunchAgentCleanup()
    } catch is CancellationError {
      await activateLegacyManagedLaunchAgentContainmentFailure(
        recoveryAuthorized: false
      )
      throw CancellationError()
    } catch {
      await activateLegacyManagedLaunchAgentContainmentFailure()
      throw error
    }
  }

  private func startLegacyManagedLaunchAgentContainment(
    failureActive: Bool,
    recoveryAuthorized: Bool = true
  ) {
    legacyManagedLaunchAgentContainment.start(
      controller: daemonController,
      failureActive: failureActive,
      recoveryAuthorized: recoveryAuthorized,
      onFailure: { [weak self] _, taskID in
        guard
          let self,
          self.legacyManagedLaunchAgentContainment.claimFailure(taskID: taskID)
        else {
          return
        }
        await self.applyLegacyManagedLaunchAgentContainmentFailure()
      },
      onRecovery: { [weak self] reconnectAuthorized, requestGeneration in
        await self?.recoverAfterLegacyManagedLaunchAgentContainment(
          reconnectAuthorized: reconnectAuthorized,
          requestGeneration: requestGeneration
        )
      }
    )
  }

  private func applyLegacyManagedLaunchAgentContainmentFailure() async {
    markLegacyManagedLaunchAgentContainmentFailed()
    resolveSecretMigrationConsent(nil)
    stopRemoteDaemonReconnect()
    stopManifestWatcher()
    stopAllStreams()
    let activeClient = client
    client = nil
    await activeClient?.shutdown()
    await shutdownMobileRelayBackgroundClient()
    await applyLaunchAgentOfflineState(reason: LegacyManagedLaunchAgentCleanup.failureMessage)
  }

  private func activateLegacyManagedLaunchAgentContainmentFailure(
    recoveryAuthorized: Bool = true
  ) async {
    await applyLegacyManagedLaunchAgentContainmentFailure()
    startLegacyManagedLaunchAgentContainment(
      failureActive: true,
      recoveryAuthorized: recoveryAuthorized
    )
  }

  private func recoverAfterLegacyManagedLaunchAgentContainment(
    reconnectAuthorized: Bool,
    requestGeneration: UInt64
  ) async {
    guard
      !connection.isPreparingForTermination,
      legacyManagedLaunchAgentContainment.claimRecovery(
        requestGeneration: requestGeneration
      )
    else {
      return
    }
    connection.legacyContainmentHealthy = true
    guard reconnectAuthorized else { return }
    let generation = connection.legacyContainmentGeneration
    let previousReconnect = connection.legacyContainmentReconnectTask
    let reconnectTask = Task { @MainActor [weak self] in
      await previousReconnect?.value
      guard
        let self,
        !Task.isCancelled,
        self.connection.legacyContainmentHealthy,
        self.connection.legacyContainmentGeneration == generation
      else {
        return
      }
      await self.reconnect()
    }
    connection.legacyContainmentReconnectTask = reconnectTask
    await reconnectTask.value
    if connection.legacyContainmentGeneration == generation {
      connection.legacyContainmentReconnectTask = nil
    }
  }

  private func markLegacyManagedLaunchAgentContainmentFailed() {
    connection.legacyContainmentGeneration &+= 1
    connection.legacyContainmentHealthy = false
    connection.legacyContainmentReconnectTask?.cancel()
  }

  func skipLegacyManagedLaunchAgentContainment() {
    legacyManagedLaunchAgentContainment.cancel()
    connection.legacyContainmentGeneration &+= 1
    connection.legacyContainmentHealthy = true
    connection.legacyContainmentReconnectTask?.cancel()
    connection.legacyContainmentReconnectTask = nil
  }

  func recordControllerLegacyCleanupFailureIfNeeded(_ error: any Error) async {
    guard
      let daemonError = error as? DaemonControlError,
      daemonError == .legacyManagedLaunchAgentCleanupFailed
    else {
      return
    }
    await activateLegacyManagedLaunchAgentContainmentFailure()
  }

  func withControllerLegacyCleanupFailureTracking<Result>(
    _ operation: () async throws -> Result
  ) async throws -> Result {
    do {
      return try await operation()
    } catch {
      await recordControllerLegacyCleanupFailureIfNeeded(error)
      throw error
    }
  }

  func withCurrentLegacyContainment<Result>(
    _ operation: () async throws -> Result
  ) async throws -> Result {
    let fence = try currentLegacyContainmentFence()
    let result = try await operation()
    try requireCurrentLegacyContainmentFence(fence)
    return result
  }

  func withLegacyContainmentClient(
    _ operation: () async throws -> any HarnessMonitorClientProtocol
  ) async throws -> any HarnessMonitorClientProtocol {
    let fence = try currentLegacyContainmentFence()
    let candidate: any HarnessMonitorClientProtocol
    do {
      candidate = try await operation()
    } catch {
      await recordControllerLegacyCleanupFailureIfNeeded(error)
      throw error
    }
    do {
      try requireCurrentLegacyContainmentFence(fence)
    } catch {
      await candidate.shutdown()
      throw error
    }
    return candidate
  }

  func withLegacyContainmentClient<Result>(
    _ operation: () async throws -> any HarnessMonitorClientProtocol,
    perform: (any HarnessMonitorClientProtocol) async throws -> Result
  ) async throws -> Result {
    let fence = try currentLegacyContainmentFence()
    let candidate: any HarnessMonitorClientProtocol
    do {
      candidate = try await operation()
    } catch {
      await recordControllerLegacyCleanupFailureIfNeeded(error)
      throw error
    }
    do {
      try requireCurrentLegacyContainmentFence(fence)
      let result = try await perform(candidate)
      try requireCurrentLegacyContainmentFence(fence)
      return result
    } catch {
      await candidate.shutdown()
      throw error
    }
  }

  func currentLegacyContainmentFence() throws -> LegacyContainmentFence {
    let fence = LegacyContainmentFence(
      generation: connection.legacyContainmentGeneration
    )
    try requireCurrentLegacyContainmentFence(fence)
    return fence
  }

  func isCurrentLegacyContainmentFence(_ fence: LegacyContainmentFence) -> Bool {
    return shouldAbandonConnectionAttempt == false
      && connection.legacyContainmentHealthy
      && connection.legacyContainmentGeneration == fence.generation
  }

  func requireCurrentLegacyContainmentFence(_ fence: LegacyContainmentFence) throws {
    guard
      isCurrentLegacyContainmentFence(fence)
    else {
      throw DaemonControlError.commandFailed(LegacyManagedLaunchAgentCleanup.failureMessage)
    }
  }
}
