import Foundation

extension DaemonController {
  public func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    let pendingBundleStampRefresh =
      try managedLaunchAgentRefreshNeededForBundledHelperChange()
    let timeoutDesc = String(describing: timeout)
    HarnessMonitorLogger.lifecycle.trace(
      "Waiting up to \(timeoutDesc, privacy: .public) for daemon manifest warm-up"
    )
    let deadline = ContinuousClock.now + timeout
    var state = WarmUpLoopState(
      pendingBundleStampRefresh: pendingBundleStampRefresh
    )
    while ContinuousClock.now < deadline {
      let shouldBreak = try await warmUpIteration(state: &state)
      if let client = shouldBreak.liveClient {
        return client
      }
      if shouldBreak.stop { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    if let immediateError = state.immediateError {
      throw immediateError
    }
    if state.skipFinalBootstrapProbe == false, let client = try? await bootstrapClient() {
      return client
    }
    if ownership == .external {
      let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
      if state.sawUnreachableManifest {
        // Manifest existed throughout the warm-up but nothing bound to its
        // endpoint. Classic crash-without-cleanup: SIGKILL'd dev daemon.
        throw DaemonControlError.externalDaemonManifestStale(manifestPath: manifestPath)
      }
      // No manifest ever appeared; the dev daemon was never started.
      throw DaemonControlError.externalDaemonOffline(manifestPath: manifestPath)
    }
    throw state.lastError ?? DaemonControlError.daemonDidNotStart
  }

  struct WarmUpLoopState {
    var lastError: (any Error)?
    var sawUnreachableManifest = false
    var immediateError: (any Error)?
    var skipFinalBootstrapProbe = false
    var managedStaleManifestTracker = ManagedStaleManifestTracker()
    var managedVersionMismatchTracker = ManagedStaleManifestTracker()
    var pendingBundleStampRefresh: ManagedLaunchAgentBundleStamp?
    var refreshedManagedLaunchAgentDuringWarmUp = false
    var signaledManagedRecoveryManifestSignature: String?
  }

  struct WarmUpIterationOutcome {
    var liveClient: (any HarnessMonitorClientProtocol)?
    var stop: Bool

    static let continueLoop = Self(liveClient: nil, stop: false)
    static let stopLoop = Self(liveClient: nil, stop: true)
  }

  func warmUpIteration(
    state: inout WarmUpLoopState
  ) async throws -> WarmUpIterationOutcome {
    do {
      let manifest = try loadManifest()
      if let mismatch = managedDaemonVersionMismatch(for: manifest) {
        return try handleManagedVersionMismatch(
          manifest: manifest,
          mismatch: mismatch,
          state: &state
        )
      }
      state.managedVersionMismatchTracker.reset()
      let deferredManagedLaunchAgentRefresh =
        try managedLaunchAgentDeferredRefreshCandidate(
          for: manifest,
          state: &state
        )
      let connection = try daemonConnection(from: manifest)
      let endpoint = connection.endpoint.absoluteString
      let manifestPid = manifest.pid
      HarnessMonitorLogger.lifecycle.trace(
        "\(Self.warmUpObservedManifestMessage(pid: manifestPid, endpoint: endpoint), privacy: .public)"
      )
      if await endpointProbe(connection.endpoint) {
        HarnessMonitorLogger.lifecycle.trace(
          "Warm-up confirmed live daemon endpoint \(endpoint, privacy: .public)"
        )
        if let deferredManagedLaunchAgentRefresh {
          await queueDeferredManagedLaunchAgentRefresh(deferredManagedLaunchAgentRefresh)
          state.pendingBundleStampRefresh = nil
          HarnessMonitorLogger.lifecycle.notice(
            """
            Managed daemon helper changed, but current daemon is healthy; \
            deferring launch-agent refresh until app inactivity
            """
          )
        } else {
          await clearDeferredManagedLaunchAgentRefresh()
        }
        let client = try await bootstrap(connection: connection)
        return WarmUpIterationOutcome(liveClient: client, stop: true)
      }
      return try handleStaleManifest(manifest: manifest, endpoint: endpoint, state: &state)
    } catch let error as DaemonControlError {
      if try refreshManagedLaunchAgentAfterManifestLoadFailureIfNeeded(
        error: error,
        state: &state
      ) {
        state.lastError = error
        return .continueLoop
      }
      state.managedStaleManifestTracker.reset()
      state.managedVersionMismatchTracker.reset()
      if case .invalidManifest = error, ownership == .external {
        state.immediateError = error
        return .stopLoop
      }
      state.lastError = error
      HarnessMonitorLogger.lifecycle.trace(
        "Warm-up retry after \(error.localizedDescription, privacy: .public)"
      )
    } catch {
      state.managedStaleManifestTracker.reset()
      state.managedVersionMismatchTracker.reset()
      state.lastError = error
      HarnessMonitorLogger.lifecycle.trace(
        "Warm-up retry after \(error.localizedDescription, privacy: .public)"
      )
    }
    return .continueLoop
  }

  func handleStaleManifest(
    manifest: DaemonManifest,
    endpoint: String,
    state: inout WarmUpLoopState
  ) throws -> WarmUpIterationOutcome {
    let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
    HarnessMonitorLogger.lifecycle.error(
      "\(Self.warmUpStaleManifestMessage(path: manifestPath, endpoint: endpoint), privacy: .public)"
    )
    state.sawUnreachableManifest = true
    if ownership == .external {
      state.immediateError = DaemonControlError.externalDaemonManifestStale(
        manifestPath: manifestPath
      )
      return .stopLoop
    }
    return try handleManagedStaleManifest(manifest: manifest, path: manifestPath, state: &state)
  }

  func handleManagedStaleManifest(
    manifest: DaemonManifest,
    path: String,
    state: inout WarmUpLoopState
  ) throws -> WarmUpIterationOutcome {
    state.lastError = DaemonControlError.daemonDidNotStart
    let staleSignature = Self.managedStaleManifestSignature(for: manifest)
    let gracePeriod = String(describing: managedStaleManifestGracePeriod)
    if Self.processIsAlive(pid: manifest.pid) == false {
      if try refreshManagedLaunchAgentForPendingBundledHelperChangeIfNeeded(state: &state) {
        return handleManagedReplacementManifestWait(
          signature: staleSignature,
          path: path,
          gracePeriod: gracePeriod,
          state: &state
        )
      }
      if state.refreshedManagedLaunchAgentDuringWarmUp {
        return handleManagedReplacementManifestWait(
          signature: staleSignature,
          path: path,
          gracePeriod: gracePeriod,
          state: &state
        )
      }
      state.skipFinalBootstrapProbe = true
      state.immediateError = DaemonControlError.daemonDidNotStart
      let pid = manifest.pid
      HarnessMonitorLogger.lifecycle.error(
        "\(Self.warmUpDeadManagedManifestMessage(pid: pid, path: path), privacy: .public)"
      )
      return .stopLoop
    }
    if state.managedStaleManifestTracker.expired(
      signature: staleSignature,
      now: ContinuousClock.now,
      gracePeriod: managedStaleManifestGracePeriod
    ) {
      let timeoutMessage = Self.warmUpManagedStaleManifestTimeoutMessage(
        path: path,
        gracePeriod: gracePeriod
      )
      HarnessMonitorLogger.lifecycle.error(
        "\(timeoutMessage, privacy: .public)"
      )
      return .stopLoop
    }
    HarnessMonitorLogger.lifecycle.trace(
      "Warm-up waiting for managed daemon to rewrite stale manifest at \(path, privacy: .public)"
    )
    return .continueLoop
  }

  func handleManagedReplacementManifestWait(
    signature: String,
    path: String,
    gracePeriod: String,
    state: inout WarmUpLoopState
  ) -> WarmUpIterationOutcome {
    if state.managedStaleManifestTracker.expired(
      signature: signature,
      now: ContinuousClock.now,
      gracePeriod: managedStaleManifestGracePeriod
    ) {
      state.skipFinalBootstrapProbe = true
      state.immediateError = DaemonControlError.daemonDidNotStart
      let timeoutMessage = Self.warmUpManagedReplacementManifestTimeoutMessage(
        path: path,
        gracePeriod: gracePeriod
      )
      HarnessMonitorLogger.lifecycle.error(
        "\(timeoutMessage, privacy: .public)"
      )
      return .stopLoop
    }

    HarnessMonitorLogger.lifecycle.trace(
      "\(Self.warmUpManagedReplacementManifestWaitMessage(path: path), privacy: .public)"
    )
    return .continueLoop
  }

  func handleManagedVersionMismatch(
    manifest: DaemonManifest,
    mismatch: DaemonControlError,
    state: inout WarmUpLoopState
  ) throws -> WarmUpIterationOutcome {
    state.lastError = mismatch
    guard
      ownership == .managed,
      launchAgentManager.registrationState() == .enabled,
      let currentStamp = try managedLaunchAgentCurrentBundleStamp()
    else {
      state.immediateError = mismatch
      return .stopLoop
    }
    guard case .managedDaemonVersionMismatch(let expected, let actual) = mismatch else {
      state.immediateError = mismatch
      return .stopLoop
    }

    if state.refreshedManagedLaunchAgentDuringWarmUp == false {
      HarnessMonitorLogger.lifecycle.notice(
        "Managed daemon version mismatch; refreshing launch agent and waiting for replacement daemon"
      )
      try refreshManagedLaunchAgent(currentStamp: currentStamp)
      state.refreshedManagedLaunchAgentDuringWarmUp = true
    }
    signalManagedRecoveryProcessIfNeeded(manifest: manifest, state: &state)

    let path = HarnessMonitorPaths.manifestURL(using: environment).path
    let signature = Self.managedVersionMismatchSignature(for: manifest)
    let gracePeriod = String(describing: managedStaleManifestGracePeriod)
    if state.managedVersionMismatchTracker.expired(
      signature: signature,
      now: ContinuousClock.now,
      gracePeriod: managedStaleManifestGracePeriod
    ) {
      HarnessMonitorLogger.lifecycle.error(
        """
        \(Self.warmUpManagedVersionMismatchTimeoutMessage(
          path: path,
          expected: expected,
          actual: actual,
          gracePeriod: gracePeriod
        ), privacy: .public)
        """
      )
      state.immediateError = mismatch
      return .stopLoop
    }

    HarnessMonitorLogger.lifecycle.trace(
      """
      \(Self.warmUpManagedVersionMismatchWaitMessage(
        path: path,
        expected: expected,
        actual: actual
      ), privacy: .public)
      """
    )
    return .continueLoop
  }

  func signalManagedRecoveryProcessIfNeeded(
    manifest: DaemonManifest,
    state: inout WarmUpLoopState
  ) {
    let signature = Self.managedStaleManifestSignature(for: manifest)
    guard state.signaledManagedRecoveryManifestSignature != signature else {
      return
    }
    state.signaledManagedRecoveryManifestSignature = signature
    Self.signalProcessToExit(pid: manifest.pid)
  }

  static func managedStaleManifestSignature(for manifest: DaemonManifest) -> String {
    "\(manifest.pid)|\(manifest.endpoint)|\(manifest.startedAt)"
  }

  static func managedVersionMismatchSignature(for manifest: DaemonManifest) -> String {
    "\(managedStaleManifestSignature(for: manifest))|version=\(manifest.version)"
  }

  static func warmUpObservedManifestMessage(pid: Int, endpoint: String) -> String {
    "Warm-up observed manifest pid=\(pid) endpoint=\(endpoint)"
  }

  static func warmUpStaleManifestMessage(path: String, endpoint: String) -> String {
    "Warm-up found stale daemon manifest at \(path) endpoint=\(endpoint)"
  }

  static func warmUpDeadManagedManifestMessage(pid: Int, path: String) -> String {
    "Warm-up detected dead managed daemon pid \(pid) stale-manifest=\(path)"
  }

  static func warmUpManagedStaleManifestTimeoutMessage(
    path: String,
    gracePeriod: String
  ) -> String {
    "Warm-up aborting managed stale manifest wait at \(path) grace-period=\(gracePeriod)"
  }

  static func warmUpManagedReplacementManifestWaitMessage(path: String) -> String {
    "Warm-up waiting for managed daemon replacement manifest at \(path) after launch-agent refresh"
  }

  static func warmUpManagedReplacementManifestTimeoutMessage(
    path: String,
    gracePeriod: String
  ) -> String {
    "Warm-up aborting managed daemon replacement wait at \(path) grace-period=\(gracePeriod)"
  }

  static func warmUpManagedVersionMismatchWaitMessage(
    path: String,
    expected: String,
    actual: String
  ) -> String {
    """
    Warm-up waiting for managed daemon version mismatch to clear at \(path) \
    expected=\(expected) actual=\(actual)
    """
  }

  static func warmUpManagedVersionMismatchTimeoutMessage(
    path: String,
    expected: String,
    actual: String,
    gracePeriod: String
  ) -> String {
    """
    Warm-up aborting managed daemon version mismatch wait at \(path) \
    expected=\(expected) actual=\(actual) grace-period=\(gracePeriod)
    """
  }

  static func processIsAlive(pid: Int) -> Bool? {
    guard pid > 0 else {
      return nil
    }

    if kill(pid_t(pid), 0) == 0 {
      return true
    }

    switch errno {
    case ESRCH:
      return false
    case EPERM:
      return true
    default:
      return nil
    }
  }

  static func signalProcessToExit(pid: Int) {
    guard pid > 0 else { return }
    if kill(pid_t(pid), SIGTERM) == 0 {
      HarnessMonitorLogger.lifecycle.trace(
        "Sent SIGTERM to stale daemon pid=\(pid, privacy: .public)"
      )
    }
  }

}
