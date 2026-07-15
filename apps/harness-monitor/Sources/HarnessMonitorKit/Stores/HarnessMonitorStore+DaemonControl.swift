extension HarnessMonitorStore {
  func restorePersistedSessionStateWhileConnectingInBackground() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.restorePersistedSessionStateWhileConnecting()
    }
  }

  func cancelPendingAppInactivitySuspend() {
    appInactivitySuspendTask?.cancel()
    appInactivitySuspendTask = nil
  }

  func performAppInactivitySuspend() async {
    guard hasLiveConnectionActivity else {
      return
    }
    guard isAppLifecycleSuspended == false else {
      return
    }

    isAppLifecycleSuspended = true
    stopRemoteDaemonReconnect()
    stopManifestWatcher()
    stopAllStreams()

    // The deferred managed-launch-agent refresh used to fire here, which
    // bounced the daemon every time the app lost focus during a dev
    // rebuild cycle and caused a WS reconnect storm in any sibling
    // observer. Refresh now defers to the explicit termination path.
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

  /// Once per app launch, tear down and re-register the bundled SMAppService
  /// launch agent so launchd spawns the helper against a fresh BTM record
  /// and Launch Constraint Record. Without this, an Xcode rebuild between
  /// app launches leaves the prior `cs_mtime` cached in BTM and the next
  /// `xpcproxy` call fails with `EX_CONFIG` in a tight crash loop.
  ///
  /// No-op in `.external` ownership and on subsequent bootstrap passes
  /// within the same process (manifest watcher reconnects, app activation
  /// reconnects, etc.).
  func refreshManagedLaunchAgentOnFirstLaunchIfNeeded() async {
    guard daemonOwnership == .managed,
      hasRefreshedManagedLaunchAgentOnLaunch == false
    else {
      return
    }
    hasRefreshedManagedLaunchAgentOnLaunch = true
    do {
      _ = try await daemonController.refreshManagedLaunchAgentForLaunch()
    } catch {
      HarnessMonitorLogger.lifecycle.error(
        "On-launch managed launch agent refresh failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func awaitManagedDaemonWarmUpWithRecovery() async throws
    -> any HarnessMonitorClientProtocol
  {
    // Warm-up can lag behind app launch during daemon restarts; surface the
    // last persisted snapshot immediately without blocking the live connect.
    restorePersistedSessionStateWhileConnectingInBackground()
    do {
      let client = try await daemonController.awaitManifestWarmUp(
        timeout: bootstrapWarmUpTimeout
      )
      resetManagedLaunchAgentRecoveryState()
      return client
    } catch {
      guard shouldRefreshManagedLaunchAgent(after: error) else {
        throw error
      }
      guard shouldAttemptManagedLaunchAgentRefresh(now: ContinuousClock.now) else {
        noteManagedLaunchAgentRefreshSkipped()
        throw error
      }
      stopManifestWatcher()
      lastManagedLaunchAgentRefreshAt = ContinuousClock.now
      managedLaunchAgentRefreshAttempts += 1
      appendConnectionEvent(
        kind: .reconnecting,
        detail: """
          Managed daemon did not become healthy; refreshing the bundled launch \
          agent (attempt \(managedLaunchAgentRefreshAttempts) of \
          \(managedLaunchAgentRefreshMaxAttempts))
          """
      )
      return try await withBootstrapTelemetryPhase(.managedLaunchAgentRefreshRecovery) {
        _ = try await daemonController.removeLaunchAgent()
        let registrationState = try await daemonController.registerLaunchAgent()
        switch registrationState {
        case .enabled:
          break
        case .requiresApproval:
          throw DaemonControlError.commandFailed(
            "Launch agent needs approval in System Settings > General > Login Items"
          )
        case .notRegistered, .notFound:
          throw DaemonControlError.commandFailed("Launch agent registration did not complete")
        }
        let client = try await daemonController.awaitManifestWarmUp(
          timeout: bootstrapWarmUpTimeout
        )
        resetManagedLaunchAgentRecoveryState()
        return client
      }
    }
  }

  func shouldAttemptManagedLaunchAgentRefresh(now: ContinuousClock.Instant) -> Bool {
    guard managedLaunchAgentRefreshAttempts < managedLaunchAgentRefreshMaxAttempts else {
      return false
    }
    guard let lastManagedLaunchAgentRefreshAt else {
      return true
    }
    let throttleUntil = lastManagedLaunchAgentRefreshAt.advanced(
      by: managedLaunchAgentRefreshMinimumInterval
    )
    return throttleUntil <= now
  }

  /// Clear managed-daemon recovery counters after a confirmed-healthy connect
  /// so an isolated transient failure never accumulates toward the refresh
  /// cap across a long-lived session.
  func resetManagedLaunchAgentRecoveryState() {
    managedLaunchAgentRefreshAttempts = 0
    lastManagedLaunchAgentRefreshAt = nil
    managedDaemonRecoveryExhausted = false
  }

  /// Record why a launch-agent refresh was skipped. Once the attempt cap is
  /// reached, re-registering cannot bring the managed daemon up - the usual
  /// cause is stale Launch Services / BTM state that only an out-of-process
  /// repair clears - so stop churning and surface a single actionable event
  /// instead of looping forever.
  func noteManagedLaunchAgentRefreshSkipped() {
    guard managedLaunchAgentRefreshAttempts >= managedLaunchAgentRefreshMaxAttempts else {
      appendConnectionEvent(
        kind: .reconnecting,
        detail:
          "Managed daemon recovery is waiting for the previous launch-agent refresh to settle"
      )
      return
    }
    guard managedDaemonRecoveryExhausted == false else {
      return
    }
    managedDaemonRecoveryExhausted = true
    appendConnectionEvent(
      kind: .reconnecting,
      detail: """
        Managed daemon did not start after \(managedLaunchAgentRefreshMaxAttempts) launch-agent \
        refreshes; pausing recovery. Quit and reopen Harness Monitor, then run \
        `mise run clean:launch-services` if it persists
        """
    )
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
    clearTransientHostBridgeIssues()
    markConnectionOffline(reason)
    await restorePersistedSessionState()
  }

  public func startDaemon() async {
    guard !usesRemoteDaemon else {
      presentFailureFeedback("Start Daemon is unavailable while a remote profile is active")
      return
    }
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
        reason: "Launch agent needs approval in System Settings > General > Login Items"
      )
      return
    case .notRegistered, .notFound:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent registration did not complete"
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
      await flushPendingCacheWrite()
      stopAllStreams()
      stopManifestWatcher()
      await shutdownMobileRelayBackgroundClient()
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
    guard !usesRemoteDaemon else {
      presentFailureFeedback("Install Launch Agent is unavailable while a remote profile is active")
      return
    }
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
    guard !usesRemoteDaemon else {
      presentFailureFeedback("Remove Launch Agent is unavailable while a remote profile is active")
      return
    }
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

  public func repairLaunchAgent() async {
    guard !usesRemoteDaemon else {
      presentFailureFeedback("Repair Launch Agent is unavailable while a remote profile is active")
      return
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let outcome = try await daemonController.repairLaunchAgentRegistration()
      resetManagedLaunchAgentRecoveryState()
      await refreshDaemonStatus()
      presentSuccessFeedback("Repair launch agent: \(outcome)")
    } catch {
      presentFailureFeedback(error.localizedDescription)
    }
  }

  public func refreshDaemonStatus() async {
    do {
      let status = try await daemonController.daemonStatus()
      daemonStatus = status
      if !usesRemoteDaemon {
        adoptManifestURL(from: status.diagnostics.manifestPath)
      }
      clearTransientHostBridgeIssues()
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
      await shutdownMobileRelayBackgroundClient()
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

}
