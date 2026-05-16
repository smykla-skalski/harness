import Foundation

extension DaemonController {
  public func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    var state = WarmUpLoopState(ownerSnapshot: currentOwnerSnapshot())
    state.pendingBundleStampRefresh =
      try managedLaunchAgentRefreshNeededForBundledHelperChange(state: &state)
    let timeoutDesc = String(describing: timeout)
    HarnessMonitorLogger.lifecycle.trace(
      "Waiting up to \(timeoutDesc, privacy: .public) for daemon manifest warm-up"
    )
    let deadline = ContinuousClock.now + timeout
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
    if ownership == .external {
      let manifestPath = externalManifestLocator.manifestURL.path
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
    var managedStaleManifestTracker = ManagedStaleManifestTracker()
    var managedVersionMismatchTracker = ManagedStaleManifestTracker()
    var pendingBundleStampRefresh: ManagedLaunchAgentBundleStamp?
    var refreshedManagedLaunchAgentDuringWarmUp = false
    var signaledManagedRecoveryManifestSignature: String?
    var lastLoggedManifestSignature: String?
    var lastLoggedRetryErrorDescription: String?
    /// Captured ownership for the warm-up entry; recaptured at every
    /// site that mutates ownership. See `OwnerSnapshot`.
    var ownerSnapshot: OwnerSnapshot
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
      return try await warmUpManifestOutcome(manifest: manifest, state: &state)
    } catch let error as DaemonControlError {
      if let outcome = await externalManifestLocationRefreshOutcome(
        after: error,
        state: &state
      ) {
        return outcome
      }
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

  func externalManifestLocationRefreshOutcome(
    after error: DaemonControlError,
    state: inout WarmUpLoopState
  ) async -> WarmUpIterationOutcome? {
    guard ownership == .external,
      let refreshedManifestURL = await refreshExternalManifestLocation()
    else {
      return nil
    }

    state.immediateError = nil
    state.lastError = error
    state.sawUnreachableManifest = false
    state.lastLoggedManifestSignature = nil
    state.lastLoggedRetryErrorDescription = nil
    HarnessMonitorLogger.lifecycle.notice(
      "External daemon discovery switched manifest to \(refreshedManifestURL.path, privacy: .public)"
    )
    return .progressedLoop
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
  ) async throws -> WarmUpIterationOutcome {
    let manifestPath = externalManifestLocator.manifestURL.path
    if isFreshObservation {
      HarnessMonitorLogger.lifecycle.error(
        "\(Self.warmUpStaleManifestMessage(path: manifestPath, endpoint: endpoint), privacy: .public)"
      )
    }
    state.sawUnreachableManifest = true
    if ownership == .external {
      if Self.processIsAlive(pid: manifest.pid) == true {
        if isFreshObservation {
          HarnessMonitorLogger.lifecycle.trace(
            """
            Warm-up waiting for external daemon pid \(manifest.pid, privacy: .public) \
            to answer at \(endpoint, privacy: .public)
            """
          )
        }
        return .continueLoop
      }
      if let outcome = await externalManifestLocationRefreshOutcome(
        after: .externalDaemonManifestStale(manifestPath: manifestPath),
        state: &state
      ) {
        return outcome
      }
      if isFreshObservation {
        let stalePID = manifest.pid
        HarnessMonitorLogger.lifecycle.trace(
          "Warm-up waiting for replacement external manifest after stale pid \(stalePID, privacy: .public)"
        )
      }
      return .continueLoop
    }
    return try handleManagedStaleManifest(
      manifest: manifest,
      path: manifestPath,
      isFreshObservation: isFreshObservation,
      state: &state
    )
  }

}
