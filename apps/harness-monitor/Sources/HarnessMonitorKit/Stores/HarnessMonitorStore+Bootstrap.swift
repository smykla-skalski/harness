import Foundation
import SwiftData

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

    scheduleRepositoryLabelUsageCachePrune()
    scheduleReviewFilesVacuumIfNeeded()

    if usesRemoteDaemon {
      await bootstrapRemoteDaemon()
      return
    }
    ensureLocalManifestURL()
    switch daemonOwnership {
    case .external:
      skipLegacyManagedLaunchAgentContainment()
      await bootstrapExternalDaemon()
    case .managed:
      guard await requireLegacyManagedLaunchAgentCleanup() else { return }
      await bootstrapManagedDaemon()
    }
  }

  private func scheduleRepositoryLabelUsageCachePrune() {
    guard let worker = cacheWriteSync.repositoryLabelUsagePersistenceWorker else { return }
    Task.detached(priority: .background) {
      await worker.pruneStale()
    }
  }

  /// Vacuum old dependency-files rows when the per-file cache exceeds the
  /// high-water mark. Runs on a detached background Task with its own
  /// ModelContext so launch is not blocked; only fires when the cached
  /// count crosses the trigger threshold.
  private func scheduleReviewFilesVacuumIfNeeded() {
    guard let modelContext else { return }
    let container = modelContext.container
    Task.detached(priority: .background) {
      Self.runReviewFilesVacuumIfNeeded(container: container)
    }
  }

  nonisolated private static func runReviewFilesVacuumIfNeeded(container: ModelContainer) {
    let context = ModelContext(container)
    let cache = ReviewFilesCache(context: context)
    let rowCount = cache.countCachedFiles()
    guard rowCount > reviewFilesVacuumTrigger else { return }
    let cutoff = Date.now.addingTimeInterval(-reviewFilesVacuumMaxAge)
    let pruned = cache.pruneStale(cutoff: cutoff)
    HarnessMonitorLogger.store.info(
      """
      Review-files cache vacuum complete; \
      pruned=\(pruned, privacy: .public) \
      cutoff=\(cutoff.timeIntervalSince1970, privacy: .public)
      """
    )
  }

  nonisolated static var reviewFilesVacuumTrigger: Int { 100_000 }
  nonisolated static var reviewFilesVacuumMaxAge: TimeInterval { 14 * 24 * 60 * 60 }

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

  // Shares the bookmark store's container so a repository's associated bookmark
  // id resolves against the same app-group bookmarks file.
  static func makeRepositoryDirectoryStore() -> RepositoryDirectoryStore? {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      if environment["XCTestConfigurationFilePath"] != nil
        || environment["HARNESS_MONITOR_UI_TESTS"] == "1"
      {
        return RepositoryDirectoryStore(containerURL: debugBookmarkStoreContainerURL())
      }
    #endif
    if let groupContainer = SandboxPaths.appGroupContainerURL() {
      return RepositoryDirectoryStore(containerURL: groupContainer)
    }
    #if DEBUG
      return RepositoryDirectoryStore(
        containerURL: SandboxPaths.debugBookmarkFallbackContainerURL()
      )
    #else
      return nil
    #endif
  }

  static func makeUserDataService(
    modelContainer: ModelContainer?
  ) -> UserDataPersistenceService? {
    modelContainer.map {
      UserDataPersistenceService(
        modelContainer: $0,
        maxRecentSearches: Self.maxRecentSearches
      )
    }
  }

  static func resolveCacheService(
    explicit cacheService: SessionCacheService?,
    modelContainer: ModelContainer?
  ) -> SessionCacheService? {
    if let cacheService {
      return cacheService
    }
    guard let modelContainer else {
      return nil
    }
    return SessionCacheService(
      modelContainer: modelContainer,
      databaseURL: HarnessMonitorPaths.cacheStoreURL()
    )
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
        try await ensureManagedLaunchAgentReady(legacyCleanupAlreadyRequired: true)
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
      try await withBootstrapTelemetryPhase(.managedInitialConnect) {
        try await connect(using: client)
      }
    } catch {
      let recovered = await recoverManagedBootstrapFailure(from: error)
      guard !recovered else {
        return
      }
    }
  }

  func bootstrapExternalDaemon() async {
    let daemonCommand = HarnessMonitorPaths.shellCommand("harness-daemon dev")
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
        try await withLegacyContainmentClient {
          try await daemonController.awaitManifestWarmUpAfterLegacyCleanup(
            timeout: bootstrapWarmUpTimeout
          )
        }
      }
      try await withBootstrapTelemetryPhase(.externalInitialConnect) {
        try await connect(using: client)
      }
    } catch {
      guard !shouldAbandonConnectionAttempt, !(error is CancellationError) else {
        connectionState = .idle
        return
      }
      do {
        try await retryLocalDaemonConnection()
        return
      } catch {
        guard !shouldAbandonConnectionAttempt, !(error is CancellationError) else {
          connectionState = .idle
          return
        }
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
      }
      await restorePersistedSessionState()
      startManifestWatcher()
      scheduleReconnectAfterConnectionFailure()
    }
  }

  func bootstrapRemoteDaemon() async {
    restorePersistedSessionStateWhileConnectingInBackground()
    do {
      try await requireLegacyManagedLaunchAgentCleanupOrThrow()
      let client = try await withBootstrapTelemetryPhase(.remoteDaemonConnect) {
        try await withLegacyContainmentClient {
          try await daemonController.bootstrapClient()
        }
      }
      try await withBootstrapTelemetryPhase(.remoteInitialConnect) {
        try await connect(using: client)
      }
    } catch {
      guard !shouldAbandonConnectionAttempt, !(error is CancellationError) else {
        connectionState = .idle
        return
      }
      let underlyingError = Self.underlyingRefreshSnapshotError(error)
      handleRemoteDaemonConnectionFailure(underlyingError)
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
      scheduleRemoteDaemonReconnect(after: underlyingError)
    }
  }

}
