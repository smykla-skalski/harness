import Foundation

extension HarnessMonitorStore {
  private var hasLiveConnectionActivity: Bool {
    client != nil
      || globalStreamTask != nil
      || connectionProbeTask != nil
      || isBootstrapping
      || isReconnecting
  }

  private func cancelPendingAppInactivitySuspend() {
    appInactivitySuspendTask?.cancel()
    appInactivitySuspendTask = nil
  }

  private func performAppInactivitySuspend() async {
    guard hasLiveConnectionActivity else {
      return
    }
    guard isAppLifecycleSuspended == false else {
      return
    }

    isAppLifecycleSuspended = true
    stopManifestWatcher()
    stopAllStreams()

    guard let client else {
      connectionState = .idle
      return
    }

    self.client = nil
    await client.shutdown()
    connectionState = .idle
  }

  func ensureManagedLaunchAgentReady() async throws -> DaemonLaunchAgentRegistrationState {
    var registrationState = await daemonController.launchAgentRegistrationState()
    if registrationState == .notRegistered || registrationState == .notFound {
      registrationState = try await daemonController.registerLaunchAgent()
    }
    return registrationState
  }

  func awaitManagedDaemonWarmUpWithRecovery() async throws
    -> any HarnessMonitorClientProtocol
  {
    // Warm-up can lag behind app launch during daemon restarts; surface the
    // last persisted snapshot immediately without blocking the live connect.
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.restorePersistedSessionStateWhileConnecting()
    }
    do {
      return try await daemonController.awaitManifestWarmUp(
        timeout: bootstrapWarmUpTimeout
      )
    } catch {
      guard shouldRefreshManagedLaunchAgent(after: error) else {
        throw error
      }
      guard shouldAttemptManagedLaunchAgentRefresh(now: ContinuousClock.now) else {
        appendConnectionEvent(
          kind: .reconnecting,
          detail:
            "Managed daemon recovery is waiting for the previous launch-agent refresh to settle"
        )
        throw error
      }
      stopManifestWatcher()
      lastManagedLaunchAgentRefreshAt = ContinuousClock.now
      appendConnectionEvent(
        kind: .reconnecting,
        detail: "Managed daemon did not become healthy; refreshing the bundled launch agent"
      )
      _ = try await daemonController.removeLaunchAgent()
      let registrationState = try await daemonController.registerLaunchAgent()
      switch registrationState {
      case .enabled:
        break
      case .requiresApproval:
        throw DaemonControlError.commandFailed(
          "Launch agent needs approval in System Settings > General > Login Items."
        )
      case .notRegistered, .notFound:
        throw DaemonControlError.commandFailed("Launch agent registration did not complete.")
      }
      return try await daemonController.awaitManifestWarmUp(
        timeout: bootstrapWarmUpTimeout
      )
    }
  }

  func shouldAttemptManagedLaunchAgentRefresh(now: ContinuousClock.Instant) -> Bool {
    guard let lastManagedLaunchAgentRefreshAt else {
      return true
    }
    let throttleUntil = lastManagedLaunchAgentRefreshAt.advanced(
      by: managedLaunchAgentRefreshMinimumInterval
    )
    return throttleUntil <= now
  }

  func shouldRefreshManagedLaunchAgent(after error: any Error) -> Bool {
    guard let daemonError = error as? DaemonControlError else {
      return false
    }
    switch daemonError {
    case .daemonDidNotStart, .daemonOffline, .manifestMissing, .manifestUnreadable:
      return true
    case .managedDaemonVersionMismatch:
      return true
    case .harnessBinaryNotFound, .externalDaemonOffline, .externalDaemonManifestStale,
      .invalidManifest, .commandFailed:
      return false
    }
  }

  @discardableResult
  func recoverManagedBootstrapFailure(from error: any Error) async -> Bool {
    startManifestWatcher()

    if let client = try? await daemonController.bootstrapClient() {
      await connect(using: client)
      return true
    }

    let message = error.localizedDescription
    markConnectionOffline(message)
    presentFailureFeedback(message)
    await restorePersistedSessionState()
    return false
  }

  func applyLaunchAgentOfflineState(reason: String) async {
    let launchAgent = await daemonController.launchAgentSnapshot()
    daemonStatus = DaemonStatusReport(
      manifest: nil,
      launchAgent: launchAgent,
      projectCount: 0,
      worktreeCount: 0,
      sessionCount: 0,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "",
        manifestPath: "",
        authTokenPath: "",
        authTokenPresent: false,
        eventsPath: "",
        databasePath: "",
        databaseSizeBytes: 0,
        lastEvent: nil
      )
    )
    markConnectionOffline(reason)
    await restorePersistedSessionState()
  }

  public func startDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    let registrationState: DaemonLaunchAgentRegistrationState
    do {
      registrationState = try await ensureManagedLaunchAgentReady()
    } catch {
      await applyLaunchAgentOfflineState(reason: error.localizedDescription)
      return
    }

    switch registrationState {
    case .requiresApproval:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent needs approval in System Settings > General > Login Items."
      )
      return
    case .notRegistered, .notFound:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent registration did not complete."
      )
      return
    case .enabled:
      break
    }

    do {
      let client = try await awaitManagedDaemonWarmUpWithRecovery()
      await connect(using: client)
    } catch {
      let recovered = await recoverManagedBootstrapFailure(from: error)
      guard !recovered else {
        return
      }
    }
  }

  public func stopDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.stopDaemon()
      stopAllStreams()
      stopManifestWatcher()
      client = nil
      markConnectionOffline("Daemon stopped")
      await refreshDaemonStatus()
      await restorePersistedSessionState()
      presentSuccessFeedback("Stop daemon")
    } catch {
      presentFailureFeedback(error.localizedDescription)
    }
  }

  public func installLaunchAgent() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.installLaunchAgent()
      await refreshDaemonStatus()
      presentSuccessFeedback("Install launch agent")
    } catch {
      presentFailureFeedback(error.localizedDescription)
    }
  }

  public func removeLaunchAgent() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.removeLaunchAgent()
      await refreshDaemonStatus()
      presentSuccessFeedback("Remove launch agent")
    } catch {
      presentFailureFeedback(error.localizedDescription)
    }
  }

  public func refreshDaemonStatus() async {
    do {
      daemonStatus = try await daemonController.daemonStatus()
    } catch {
      presentFailureFeedback(error.localizedDescription)
    }
  }

  func replayQueuedReconnectAfterBootstrapIfNeeded() {
    guard reconnectRequestedDuringReconnect, isReconnecting == false else {
      return
    }

    reconnectRequestedDuringReconnect = false
    appendConnectionEvent(
      kind: .reconnecting,
      detail: "Replaying daemon reconnect request queued during bootstrap"
    )
    Task { @MainActor [weak self] in
      await self?.reconnect()
    }
  }

  public func reconnect() async {
    // If a bootstrap is already running (e.g. the watcher fired mid-warm-up
    // in external mode), record the request so the current bootstrap/reconnect
    // pass can replay it after settling; avoids re-entering from the MainActor hop.
    if isBootstrapping || isReconnecting {
      reconnectRequestedDuringReconnect = true
      return
    }
    isReconnecting = true

    repeat {
      reconnectRequestedDuringReconnect = false
      stopManifestWatcher()
      stopAllStreams()
      let oldClient = client
      client = nil
      if let oldClient {
        await oldClient.shutdown()
      }
      hostBridgeCapabilityIssues = hostBridgeCapabilityIssues.filter {
        forcedHostBridgeCapabilities.contains($0.key)
      }
      hasBootstrapped = true
      await bootstrap()

      guard reconnectRequestedDuringReconnect else {
        break
      }
      // A manifest change was detected during bootstrap - the attempt above
      // may have used a stale endpoint or missed a later reconnect request.
      // Give the daemon a moment to accept connections on the new port before retrying.
      try? await Task.sleep(for: .milliseconds(500))
    } while true

    isReconnecting = false
  }

  public func suspendLiveConnectionForAppInactivity() async {
    guard hasLiveConnectionActivity else {
      return
    }
    guard isAppLifecycleSuspended == false else {
      return
    }
    guard appInactivitySuspendTask == nil else {
      return
    }

    guard appInactivitySuspendDelay > .zero else {
      await performAppInactivitySuspend()
      return
    }

    let delay = appInactivitySuspendDelay
    appInactivitySuspendTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled else {
        return
      }
      self.appInactivitySuspendTask = nil
      await self.performAppInactivitySuspend()
    }
  }

  public func resumeLiveConnectionAfterAppActivation() async {
    cancelPendingAppInactivitySuspend()
    guard isAppLifecycleSuspended else {
      return
    }

    isAppLifecycleSuspended = false
    guard isBootstrapping == false else {
      return
    }
    guard isReconnecting == false else {
      reconnectRequestedDuringReconnect = true
      return
    }

    await reconnect()
  }

  public func prepareForTermination() async {
    toast.dismissAll()
    cancelPendingAppInactivitySuspend()
    stopAllStreams()
    stopManifestWatcher()
    stopResourceMetricsSampling()
    isAppLifecycleSuspended = false

    guard let client else {
      return
    }

    self.client = nil
    await client.shutdown()
  }
}
