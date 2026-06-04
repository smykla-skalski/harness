import Foundation

extension DaemonController {
  func warmUpManifestOutcome(
    manifest: DaemonManifest,
    state: inout WarmUpLoopState
  ) async throws -> WarmUpIterationOutcome {
    let currentManifestURL = externalManifestLocator.manifestURL.standardizedFileURL
    let staleSignature = Self.managedStaleManifestSignature(for: manifest)
    let isFreshObservation = state.lastLoggedManifestSignature != staleSignature
    if isFreshObservation {
      let manifestPath = currentManifestURL.path
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
      return try await handleManagedVersionMismatch(
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
          Managed daemon launch-agent assets changed, but current daemon is healthy; \
          deferring launch-agent refresh until app inactivity
          """
        )
      } else {
        await clearDeferredManagedLaunchAgentRefresh()
      }
      let client = try await bootstrap(connection: connection)
      externalManifestLocator.rememberActiveManifestIfNeeded()
      return WarmUpIterationOutcome(liveClient: client, stop: true, progressed: true)
    }
    if let alternateOutcome = try await bootstrapReachableAlternateExternalManifestIfNeeded(
      currentManifestURL: currentManifestURL
    ) {
      state.sawUnreachableManifest = false
      return alternateOutcome
    }
    return try await handleStaleManifest(
      manifest: manifest,
      endpoint: endpoint,
      isFreshObservation: isFreshObservation,
      state: &state
    )
  }

  func bootstrapReachableAlternateExternalManifestIfNeeded(
    currentManifestURL: URL
  ) async throws -> WarmUpIterationOutcome? {
    guard ownership == .external else {
      return nil
    }

    var candidateManifestURLs = externalManifestLocator.candidateManifestURLs()
      .map(\.standardizedFileURL)
    appendExternalManifestCandidateURL(
      HarnessMonitorPaths.manifestURL(using: environment).standardizedFileURL,
      to: &candidateManifestURLs
    )
    appendRuntimeLaneExternalManifestCandidateURLs(to: &candidateManifestURLs)

    for candidateManifestURL in candidateManifestURLs
    where candidateManifestURL != currentManifestURL {
      do {
        let candidateManifest = try loadManifest(at: candidateManifestURL, emitTrace: false)
        let candidateConnection = try daemonConnection(from: candidateManifest, emitTrace: false)
        if await endpointProbe(candidateConnection.endpoint) {
          HarnessMonitorLogger.lifecycle.notice(
            """
            Warm-up switched from stale external manifest \
            \(currentManifestURL.path, privacy: .public) to reachable manifest \
            \(candidateManifestURL.path, privacy: .public)
            """
          )
          let client = try await bootstrap(connection: candidateConnection)
          externalManifestLocator.rememberActiveManifestIfNeeded()
          return WarmUpIterationOutcome(liveClient: client, stop: true, progressed: true)
        }
      } catch {
        // Ignore unreadable or stale alternates and keep looking.
      }
      externalManifestLocator.activate(currentManifestURL)
    }

    externalManifestLocator.activate(currentManifestURL)
    return nil
  }

  func appendExternalManifestCandidateURL(_ manifestURL: URL, to manifestURLs: inout [URL]) {
    guard manifestURLs.contains(manifestURL) == false else {
      return
    }
    manifestURLs.append(manifestURL)
  }

  func appendRuntimeLaneExternalManifestCandidateURLs(to manifestURLs: inout [URL]) {
    let appGroupIdentifier =
      HarnessMonitorPaths.normalizedAppGroupIdentifier(using: environment)
      ?? HarnessMonitorAppGroup.identifier
    let containerRoot =
      HarnessMonitorPaths.nativeAppGroupContainerURL(
        identifier: appGroupIdentifier,
        using: environment
      )
      ?? HarnessMonitorPaths.appGroupContainerURL(
        identifier: appGroupIdentifier,
        using: environment
      )
    let lanesRoot = containerRoot.appendingPathComponent(
      HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName,
      isDirectory: true
    )
    let laneEntries =
      (try? FileManager.default.contentsOfDirectory(
        at: lanesRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    for laneEntry in laneEntries {
      let values = try? laneEntry.resourceValues(forKeys: [.isDirectoryKey])
      guard values?.isDirectory == true else {
        continue
      }

      let manifestURL =
        laneEntry
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("daemon", isDirectory: true)
        .appendingPathComponent(ownership.rawValue, isDirectory: true)
        .appendingPathComponent("manifest.json")
        .standardizedFileURL
      appendExternalManifestCandidateURL(manifestURL, to: &manifestURLs)
    }
  }

  func handleManagedStaleManifest(
    manifest: DaemonManifest,
    path: String,
    isFreshObservation: Bool,
    state: inout WarmUpLoopState
  ) async throws -> WarmUpIterationOutcome {
    state.lastError = DaemonControlError.daemonDidNotStart
    let staleSignature = Self.managedStaleManifestSignature(for: manifest)
    let gracePeriod = String(describing: managedStaleManifestGracePeriod)
    if Self.processIsAlive(pid: manifest.pid) == false {
      if try await refreshManagedLaunchAgentForPendingBundledHelperChangeIfNeeded(
        state: &state
      ) {
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
  ) async throws -> WarmUpIterationOutcome {
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
      switch try await refreshManagedLaunchAgent(currentStamp: currentStamp) {
      case .refreshed:
        state.refreshedManagedLaunchAgentDuringWarmUp = true
        state.ownerSnapshot = currentOwnerSnapshot()
      case .skippedSiblingOwnsLane, .skippedNotManagedDaemon, .skippedLockContended:
        // Leave the flag false so we re-evaluate next tick; the
        // sibling owner is the one expected to bring a matching
        // daemon up, or the lock will free.
        break
      }
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
    guard refuseCrossLaneSignalIfNeeded(manifest: manifest) == false else {
      state.signaledManagedRecoveryManifestSignature = signature
      return
    }
    state.signaledManagedRecoveryManifestSignature = signature
    Self.signalProcessToExit(pid: manifest.pid)
  }

  /// Defense-in-depth: refuse to SIGTERM a daemon whose on-disk root
  /// belongs to a different lane family than the current process.
  /// Returns `true` when the signal was refused. Mirrors the daemon-side
  /// `families_compatible` check in `crate::daemon::discovery`.
  func refuseCrossLaneSignalIfNeeded(manifest: DaemonManifest) -> Bool {
    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    let manifestRoot = manifestURL.deletingLastPathComponent()
    let ownFamily = HarnessMonitorPaths.ownLaneFamily(using: environment)
    let manifestFamily = HarnessMonitorPaths.laneFamily(forRoot: manifestRoot)
    guard
      HarnessMonitorLaneFamily.compatible(ownFamily, manifestFamily) == false
    else {
      return false
    }
    HarnessMonitorLogger.lifecycle.warning(
      """
      Refusing cross-lane SIGTERM to daemon \
      pid=\(manifest.pid, privacy: .public) \
      manifest_root=\(manifestRoot.path, privacy: .public)
      """
    )
    return true
  }
}
