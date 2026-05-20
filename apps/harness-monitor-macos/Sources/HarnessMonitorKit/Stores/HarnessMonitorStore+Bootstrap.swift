import Foundation

extension HarnessMonitorStore {
  func bootstrapBody() async {
    connectionState = .connecting
    #if HARNESS_FEATURE_OTEL
      startResourceMetricsSampling()
      recordActiveTaskGauge()
    #endif
    if Self.shouldStartSupervisorOnBootstrap() {
      await startSupervisor()
    }

    isBootstrapping = true
    defer {
      isBootstrapping = false
      replayQueuedReconnectAfterBootstrapIfNeeded()
    }

    switch daemonOwnership {
    case .external:
      await bootstrapExternalDaemon()
    case .managed:
      await bootstrapManagedDaemon()
    }
  }

  static func makeBookmarkStore() -> BookmarkStore? {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      if environment["XCTestConfigurationFilePath"] != nil
        || environment["HARNESS_MONITOR_UI_TESTS"] == "1"
      {
        return BookmarkStore(
          containerURL: debugBookmarkStoreContainerURL(),
          allowsUITestSeedRecords: true
        )
      }
    #endif
    if let groupContainer = SandboxPaths.appGroupContainerURL() {
      return BookmarkStore(containerURL: groupContainer)
    }
    #if DEBUG
      HarnessMonitorLogger.store.warning(
        "App group container unavailable; using temp dir for BookmarkStore — check entitlements"
      )
      return BookmarkStore(containerURL: SandboxPaths.debugBookmarkFallbackContainerURL())
    #else
      HarnessMonitorLogger.store.warning(
        "App group container unavailable; bookmark store disabled — check entitlements"
      )
      return nil
    #endif
  }

  #if DEBUG
    static func debugBookmarkStoreContainerURL() -> URL {
      SandboxPaths.debugBookmarkFallbackContainerURL()
        .appendingPathComponent("xctest-bookmark-store", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
  #endif

  nonisolated static func shouldStartSupervisorOnBootstrap(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    if environment["HARNESS_MONITOR_ENABLE_BOOTSTRAP_SUPERVISOR_IN_TESTS"] == "1" {
      return true
    }
    return environment["XCTestConfigurationFilePath"] == nil
  }

  public func bootstrapIfNeeded() async {
    guard !hasBootstrapped else {
      return
    }
    if let bootstrapTask {
      await bootstrapTask.value
      return
    }

    // SessionWindowView refreshes via `.task(id:)`, and the trigger includes
    // connection state. Bootstrap flips that state to `.connecting`, so the
    // originating SwiftUI task can be cancelled mid-warm-up. Keep the actual
    // bootstrap owned by the store so a restarted view task can await the same
    // in-flight work instead of permanently orphaning startup.
    let bootstrapTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer {
        self.bootstrapTask = nil
      }
      guard self.hasBootstrapped == false else {
        return
      }
      await self.refreshBookmarkedSessionIds()
      await self.refreshPersistedSessionMetadata()
      await self.bootstrap()
      self.hasBootstrapped = true
    }
    self.bootstrapTask = bootstrapTask
    await bootstrapTask.value
  }

  public func bootstrap() async {
    let startedAt = ContinuousClock.now
    #if HARNESS_FEATURE_OTEL
      let span = HarnessMonitorTelemetry.shared.startSpan(
        name: "app.lifecycle.bootstrap",
        kind: .internal,
        attributes: [
          "daemon.ownership": .string(daemonOwnership == .external ? "external" : "managed")
        ]
      )
      defer {
        let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
        HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
          event: "bootstrap",
          launchMode: "live",
          durationMs: durationMs
        )
        span.end()
      }
    #else
      _ = startedAt
    #endif

    #if HARNESS_FEATURE_OTEL
      await HarnessMonitorTelemetryTaskContext.$parentSpanContext.withValue(span.context) {
        await bootstrapBody()
      }
    #else
      await bootstrapBody()
    #endif
  }

  func bootstrapManagedDaemon() async {
    await refreshManagedLaunchAgentOnFirstLaunchIfNeeded()

    let registrationState: DaemonLaunchAgentRegistrationState
    do {
      registrationState = try await withBootstrapTelemetryPhase(.managedLaunchAgentReady) {
        try await ensureManagedLaunchAgentReady()
      }
    } catch {
      await applyLaunchAgentOfflineState(reason: error.localizedDescription)
      return
    }

    switch registrationState {
    case .notRegistered, .notFound:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent not installed. Install to start the daemon"
      )
      return
    case .requiresApproval:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent needs approval in System Settings > General > Login Items"
      )
      return
    case .enabled:
      break
    }

    do {
      let client = try await withBootstrapTelemetryPhase(.managedDaemonWarmUp) {
        try await awaitManagedDaemonWarmUpWithRecovery()
      }
      await withBootstrapTelemetryPhase(.managedInitialConnect) {
        await connect(using: client)
      }
    } catch {
      let recovered = await recoverManagedBootstrapFailure(from: error)
      guard !recovered else {
        return
      }
    }
  }

  func bootstrapExternalDaemon() async {
    let daemonCommand = HarnessMonitorPaths.shellCommand("harness daemon dev")
    let registrationState = await daemonController.launchAgentRegistrationState()
    if registrationState == .enabled {
      appendConnectionEvent(
        kind: .error,
        detail: "SMAppService launch agent is still registered. Remove it in "
          + "System Settings > General > Login Items to avoid conflicts with "
          + "`\(daemonCommand)`"
      )
    }
    do {
      // External daemon warm-up can lag behind app launch as well; surface the
      // last persisted snapshot immediately while we wait for the manifest.
      restorePersistedSessionStateWhileConnectingInBackground()
      let client = try await withBootstrapTelemetryPhase(.externalDaemonWarmUp) {
        try await daemonController.awaitManifestWarmUp(timeout: bootstrapWarmUpTimeout)
      }
      await withBootstrapTelemetryPhase(.externalInitialConnect) {
        await connect(using: client)
      }
    } catch {
      let recovery = externalDaemonRecoveryFeedback(
        for: error,
        daemonCommand: daemonCommand
      )
      markConnectionOffline(recovery.offlineMessage)
      toast.presentWarning(
        recovery.message,
        title: recovery.title,
        details: recovery.details,
        primaryAction: recovery.primaryAction,
        rollupDuplicates: true
      )
      await restorePersistedSessionState()
      startManifestWatcher()
    }
  }

}
