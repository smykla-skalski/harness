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
    var backoff = warmUpBackoff.makeIterator()
    while ContinuousClock.now < deadline {
      let outcome = try await warmUpIteration(state: &state)
      if let client = outcome.liveClient {
        return client
      }
      if outcome.stop { break }
      if outcome.progressed {
        backoff.reset()
      }
      try await backoff.wait()
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
    var lastLoggedManifestSignature: String?
    var lastLoggedRetryErrorDescription: String?
  }

  struct WarmUpIterationOutcome {
    var liveClient: (any HarnessMonitorClientProtocol)?
    var stop: Bool
    var progressed: Bool

    static let continueLoop = Self(liveClient: nil, stop: false, progressed: false)
    static let stopLoop = Self(liveClient: nil, stop: true, progressed: false)
    static let progressedLoop = Self(liveClient: nil, stop: false, progressed: true)
  }

  func warmUpIteration(
    state: inout WarmUpLoopState
  ) async throws -> WarmUpIterationOutcome {
    do {
      let manifest = try loadManifest(emitTrace: false)
      let staleSignature = Self.managedStaleManifestSignature(for: manifest)
      let isFreshObservation = state.lastLoggedManifestSignature != staleSignature
      if isFreshObservation {
        let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
        let pid = manifest.pid
        let tokenPath = manifest.tokenPath
        HarnessMonitorLogger.lifecycle.trace(
          "Loaded daemon manifest from \(manifestPath, privacy: .public) for pid \(pid, privacy: .public)"
        )
        HarnessMonitorLogger.lifecycle.trace(
          "Loaded daemon auth token from \(tokenPath, privacy: .public)"
        )
      }
      if let mismatch = managedDaemonVersionMismatch(for: manifest) {
        state.lastLoggedManifestSignature = staleSignature
        return try handleManagedVersionMismatch(
          manifest: manifest,
          mismatch: mismatch,
          isFreshObservation: isFreshObservation,
          state: &state
        )
      }
      state.managedVersionMismatchTracker.reset()
      let deferredManagedLaunchAgentRefresh =
        try managedLaunchAgentDeferredRefreshCandidate(
          for: manifest,
          state: &state
        )
      let connection = try daemonConnection(from: manifest, emitTrace: false)
      let endpoint = connection.endpoint.absoluteString
      let manifestPid = manifest.pid
      if isFreshObservation {
        HarnessMonitorLogger.lifecycle.trace(
          "\(Self.warmUpObservedManifestMessage(pid: manifestPid, endpoint: endpoint), privacy: .public)"
        )
      }
      state.lastLoggedManifestSignature = staleSignature
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
        return WarmUpIterationOutcome(liveClient: client, stop: true, progressed: true)
      }
      return try handleStaleManifest(
        manifest: manifest,
        endpoint: endpoint,
        isFreshObservation: isFreshObservation,
        state: &state
      )
    } catch let error as DaemonControlError {
      if try refreshManagedLaunchAgentAfterManifestLoadFailureIfNeeded(
        error: error,
        state: &state
      ) {
        state.lastError = error
        return .progressedLoop
      }
      state.managedStaleManifestTracker.reset()
      state.managedVersionMismatchTracker.reset()
      state.lastLoggedManifestSignature = nil
      if case .invalidManifest = error, ownership == .external {
        state.immediateError = error
        return .stopLoop
      }
      state.lastError = error
      emitWarmUpRetryTraceIfChanged(error: error, state: &state)
    } catch {
      state.managedStaleManifestTracker.reset()
      state.managedVersionMismatchTracker.reset()
      state.lastLoggedManifestSignature = nil
      state.lastError = error
      emitWarmUpRetryTraceIfChanged(error: error, state: &state)
    }
    return .continueLoop
  }

  func emitWarmUpRetryTraceIfChanged(
    error: any Error,
    state: inout WarmUpLoopState
  ) {
    let description = error.localizedDescription
    guard state.lastLoggedRetryErrorDescription != description else {
      return
    }
    state.lastLoggedRetryErrorDescription = description
    HarnessMonitorLogger.lifecycle.trace(
      "Warm-up retry after \(description, privacy: .public)"
    )
  }

  func handleStaleManifest(
    manifest: DaemonManifest,
    endpoint: String,
    isFreshObservation: Bool,
    state: inout WarmUpLoopState
  ) throws -> WarmUpIterationOutcome {
    let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
    if isFreshObservation {
      HarnessMonitorLogger.lifecycle.error(
        "\(Self.warmUpStaleManifestMessage(path: manifestPath, endpoint: endpoint), privacy: .public)"
      )
    }
    state.sawUnreachableManifest = true
    if ownership == .external {
      state.immediateError = DaemonControlError.externalDaemonManifestStale(
        manifestPath: manifestPath
      )
      return .stopLoop
    }
    return try handleManagedStaleManifest(
      manifest: manifest,
      path: manifestPath,
      isFreshObservation: isFreshObservation,
      state: &state
    )
  }

  func handleManagedStaleManifest(
    manifest: DaemonManifest,
    path: String,
    isFreshObservation: Bool,
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
          isFreshObservation: isFreshObservation,
          state: &state
        )
      }
      if state.refreshedManagedLaunchAgentDuringWarmUp {
        return handleManagedReplacementManifestWait(
          signature: staleSignature,
          path: path,
          gracePeriod: gracePeriod,
          isFreshObservation: isFreshObservation,
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
    let observation = state.managedStaleManifestTracker.observe(
      signature: staleSignature,
      now: ContinuousClock.now,
      gracePeriod: managedStaleManifestGracePeriod
    )
    switch observation {
    case .expired:
      let timeoutMessage = Self.warmUpManagedStaleManifestTimeoutMessage(
        path: path,
        gracePeriod: gracePeriod
      )
      HarnessMonitorLogger.lifecycle.error(
        "\(timeoutMessage, privacy: .public)"
      )
      return .stopLoop
    case .freshSignature, .withinGrace:
      if isFreshObservation {
        HarnessMonitorLogger.lifecycle.trace(
          "Warm-up waiting for managed daemon to rewrite stale manifest at \(path, privacy: .public)"
        )
      }
      return observation == .freshSignature ? .progressedLoop : .continueLoop
    }
  }

  func handleManagedReplacementManifestWait(
    signature: String,
    path: String,
    gracePeriod: String,
    isFreshObservation: Bool,
    state: inout WarmUpLoopState
  ) -> WarmUpIterationOutcome {
    let observation = state.managedStaleManifestTracker.observe(
      signature: signature,
      now: ContinuousClock.now,
      gracePeriod: managedStaleManifestGracePeriod
    )
    switch observation {
    case .expired:
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
    case .freshSignature, .withinGrace:
      if isFreshObservation {
        HarnessMonitorLogger.lifecycle.trace(
          "\(Self.warmUpManagedReplacementManifestWaitMessage(path: path), privacy: .public)"
        )
      }
      return observation == .freshSignature ? .progressedLoop : .continueLoop
    }
  }

  func handleManagedVersionMismatch(
    manifest: DaemonManifest,
    mismatch: DaemonControlError,
    isFreshObservation: Bool,
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
    let observation = state.managedVersionMismatchTracker.observe(
      signature: signature,
      now: ContinuousClock.now,
      gracePeriod: managedStaleManifestGracePeriod
    )
    switch observation {
    case .expired:
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
    case .freshSignature, .withinGrace:
      if isFreshObservation {
        HarnessMonitorLogger.lifecycle.trace(
          """
          \(Self.warmUpManagedVersionMismatchWaitMessage(
            path: path,
            expected: expected,
            actual: actual
          ), privacy: .public)
          """
        )
      }
      return observation == .freshSignature ? .progressedLoop : .continueLoop
    }
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

}
